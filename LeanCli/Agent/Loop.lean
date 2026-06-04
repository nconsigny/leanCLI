import LeanCli.Agent.State
import LeanCli.Agent.Tools
import LeanCli.Agent.Llm
import LeanCli.Agent.Compression
import LeanCli.Agent.Trace

/-!
# Bounded agent loop

`runOneShot` repeatedly calls the chat completions endpoint and
dispatches the model's tool calls until either:

* the assistant turn carries no `tool_calls` — that's the final
  answer, return it; or
* the per-invocation `maxSteps` budget is exhausted — return an
  error.

This is the only partial def in the agent tree. The termination
proof obligation is tagged `PHASE_N: prove termination` per the
Phase 0 contract: the loop is bounded by `cfg.maxSteps`, but the
current shape of the body doesn't expose that to Lean's decreasing-
metric analyzer. A follow-up phase replaces this with a `Nat.rec`
descent on `maxSteps - steps`.
-/

namespace LeanCli.Agent.Loop

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Agent.Llm
open LeanCli.Agent.Trace
open LeanCli.Encoding.Json

/-- Convenience: render a `ToolResult` as a `tool` AgentMessage. -/
private def toolMessage (call : ToolCall) (r : ToolResult) : AgentMessage :=
  { role := .tool,
    content := some (resultToContent r),
    toolCallId := some call.id }

/-- Replace the system-role message at index 0 with `newContent`. The
    persistent agent daemon uses this to inject freshly-rendered
    skill bodies before each LLM call — see
    `docs/PHASE1B_PLAN.md`. A no-op when the head message is not a
    system message (defensive — should never happen in practice). -/
private def replaceSystemHead (msgs : Array AgentMessage) (newContent : String) :
    Array AgentMessage :=
  match msgs[0]? with
  | some m =>
      if m.role = Role.system then
        msgs.set! 0 { m with content := some newContent }
      else msgs
  | none => msgs

-- PHASE_N: prove termination — the loop is bounded by
-- `s.cfg.maxSteps` (see the explicit guard at the loop head), but the
-- termination measure has not yet been lifted into the type. This is
-- the only partial def in the agent tree; every other path is total.
partial def runOneShot
    (s₀ : AgentState) (registry : ToolRegistry) :
    IO (Except String AgentMessage) := do
  match ← runOneShotWithRebuildTraced s₀ registry none with
  | .error e => pure (.error e)
  | .ok (msg, _trace) => pure (.ok msg)
where
  /-- Variant accepting an optional `rebuildSystem` callback. When
      present, the callback is invoked before every `Llm.chat` round
      and its result replaces the system-role head message. The
      callback also returns a `Trace.SkillReport` describing which
      always-on / triggered skills + memory + trusted-registry blocks
      were rendered; the loop pushes that as a `TraceItem.skills`
      entry before each LLM call.

      Returns the final assistant message and a `Trace` of everything
      that happened during this turn — pre-call skills snapshot,
      assistant messages (with optional `reasoning`), per-call
      `usage` + wall-clock cost, every tool call the model made, and
      every tool reply. The trace is display-only (see
      `Agent.Trace`) and is what the TUI's foldable per-turn trace
      block consumes via `chat.draft`'s `agentTrace` field. -/
  runOneShotWithRebuildTraced
      (s₀ : AgentState) (registry : ToolRegistry)
      (rebuildSystem :
        Option (AgentState → IO (String × Trace.SkillReport))) :
      IO (Except String (AgentMessage × Trace)) := do
    let mut s := s₀
    let mut trace : Trace := #[]
    let mut callIdx : Nat := 0
    let compressionPolicy : Compression.Policy := {}
    while s.steps < s.cfg.maxSteps do
      let tools := filterByAllowlist registry s.cfg.toolAllowlist
      -- Token-budget compression. Graceful no-op on failure so a
      -- compression error never crashes the agent — at worst the
      -- model hits its own context window. Only the rebuild-callback
      -- mode (`leancli-agentd`) uses compression; one-shot
      -- (`leancli-agent`) skips it because its loops are bounded
      -- short by `maxSteps`.
      if rebuildSystem.isSome then
        match ← Compression.maybeCompress s.cfg compressionPolicy s.messages with
        | .error e => IO.eprintln s!"[compression] skipped: {e}"
        | .ok msgs' =>
            if msgs'.size ≠ s.messages.size then
              match ← IO.getEnv "LEANCLI_LOG_PROMPT" with
              | some v =>
                  if v ≠ "" && v ≠ "0" then
                    IO.eprintln s!"[compression] compressed transcript: \
{s.messages.size} → {msgs'.size} messages"
              | none => pure ()
              s := { s with messages := msgs' }
      match rebuildSystem with
      | none => pure ()
      | some f =>
          let (fresh, report) ← f s
          s := { s with messages := replaceSystemHead s.messages fresh }
          trace := trace.push <| TraceItem.skills
            report.alwaysOn report.triggered
            report.memoryActive report.trustedRegistryActive
      let tStart ← IO.monoMsNow
      match ← Llm.chat s tools with
      | .error e => return .error s!"llm error: {repr e}"
      | .ok (resp, stats) =>
          let tEnd ← IO.monoMsNow
          let durationMs := tEnd - tStart
          -- Record the assistant turn (its content + optional
          -- reasoning) before any tool dispatch so the trace order
          -- mirrors wire order. The matching `.llmCall` entry follows
          -- the `.assistant` entry by position so consumers can pair
          -- them without a join key.
          trace := trace.push <|
            TraceItem.assistant (resp.content.getD "") resp.reasoning
          trace := trace.push <|
            TraceItem.llmCall stats.promptTokens stats.completionTokens
              stats.totalTokens durationMs
          if resp.toolCalls.isEmpty then
            return .ok (resp, trace)
          let mut s' : AgentState :=
            { s with messages := s.messages.push resp,
                     steps := s.steps + 1 }
          for tc in resp.toolCalls do
            trace := trace.push <| TraceItem.toolCall tc.name tc.argsJson callIdx
            let result ← Tools.dispatch registry s.cfg.toolAllowlist s.cfg tc
            let summary :=
              truncateForTrace (Tools.resultToContent result)
            trace := trace.push <| TraceItem.toolResult callIdx result.ok summary
            callIdx := callIdx + 1
            s' := { s' with messages := s'.messages.push (toolMessage tc result) }
          s := s'
    return .error s!"agent budget exceeded ({s₀.cfg.maxSteps} steps)"

/-- Top-level entry exposing the rebuild callback. Convenience
    wrapper so callers don't have to peer into `runOneShot.where`. The
    callback returns the rendered system-prompt body plus a
    `Trace.SkillReport` describing what it included. -/
def runOneShotWithRebuild
    (s₀ : AgentState) (registry : ToolRegistry)
    (rebuildSystem :
      Option (AgentState → IO (String × Trace.SkillReport))) :
    IO (Except String (AgentMessage × Trace)) :=
  runOneShot.runOneShotWithRebuildTraced s₀ registry rebuildSystem

end LeanCli.Agent.Loop
