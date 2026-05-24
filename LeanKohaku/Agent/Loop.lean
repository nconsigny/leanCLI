import LeanKohaku.Agent.State
import LeanKohaku.Agent.Tools
import LeanKohaku.Agent.Llm

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

namespace LeanKohaku.Agent.Loop

open LeanKohaku.Agent
open LeanKohaku.Agent.Tools
open LeanKohaku.Agent.Llm
open LeanKohaku.Encoding.Json

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
    IO (Except String AgentMessage) :=
  runOneShotWithRebuild s₀ registry none
where
  /-- Variant accepting an optional `rebuildSystem` callback. When
      present, the callback is invoked before every `Llm.chat` round
      and its result replaces the system-role head message. This is
      how Phase-1b skill activation is wired in `kohaku-agentd`
      without coupling the Phase-0 one-shot binary to the skills
      registry. -/
  runOneShotWithRebuild
      (s₀ : AgentState) (registry : ToolRegistry)
      (rebuildSystem : Option (AgentState → IO String)) :
      IO (Except String AgentMessage) := do
    let mut s := s₀
    while s.steps < s.cfg.maxSteps do
      let tools := filterByAllowlist registry s.cfg.toolAllowlist
      match rebuildSystem with
      | none => pure ()
      | some f =>
          let fresh ← f s
          s := { s with messages := replaceSystemHead s.messages fresh }
      match ← Llm.chat s tools with
      | .error e => return .error s!"llm error: {repr e}"
      | .ok resp =>
          if resp.toolCalls.isEmpty then
            return .ok resp
          let mut s' : AgentState :=
            { s with messages := s.messages.push resp,
                     steps := s.steps + 1 }
          for tc in resp.toolCalls do
            let result ← Tools.dispatch registry s.cfg.toolAllowlist s.cfg tc
            s' := { s' with messages := s'.messages.push (toolMessage tc result) }
          s := s'
    return .error s!"agent budget exceeded ({s₀.cfg.maxSteps} steps)"

/-- Top-level entry exposing the rebuild callback. Convenience
    wrapper so callers don't have to peer into `runOneShot.where`. -/
def runOneShotWithRebuild
    (s₀ : AgentState) (registry : ToolRegistry)
    (rebuildSystem : Option (AgentState → IO String)) :
    IO (Except String AgentMessage) :=
  runOneShot.runOneShotWithRebuild s₀ registry rebuildSystem

end LeanKohaku.Agent.Loop
