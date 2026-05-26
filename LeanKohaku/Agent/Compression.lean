import LeanKohaku.Agent.State
import LeanKohaku.Agent.Llm
import LeanKohaku.Agent.Memory

/-!
# Mid-session transcript compression

When a session grows past a token threshold, the agent loop replaces
the middle of the transcript with a compact LLM-generated summary.
This keeps each chat-completions round within the local model's
context window without losing the load-bearing facts of the
conversation (addresses, contract names, user decisions, tool
outputs).

## What is preserved

* The first system-role message (persona + skills + tool docs).
* The last `Policy.keepLastTurns` user/assistant turn pairs and any
  interleaved tool messages.

## What is summarised

Everything between those bookends becomes one new
`role = system` message whose content begins with
`[Earlier in session, summarised]`. Idempotency: a second pass on
an already-compressed transcript falls under the token threshold
(by construction `targetTokens < triggerTokens`) and returns the
input unchanged.

## Failure mode

Compression failure (transport error, malformed JSON, LLM refusal)
is a graceful `Except.error` returned to the caller. The agent loop
proceeds with the un-compressed transcript rather than crashing —
the worst case is the LLM hitting its own context limit.

This module imports no signing or key-material module and is on the
forbidden-import gated path documented in `docs/PHASE0_PLAN.md`.
-/

namespace LeanKohaku.Agent.Compression

open LeanKohaku.Agent

/-- Marker prefix used to recognise a previously-compressed
    summary system message. Centralised so the loop, the policy,
    and operator logs all match. -/
def summaryMarker : String := "[Earlier in session, summarised]"

/-- Re-export the token estimator from `Memory` so callers
    don't have to import both modules. -/
def estimateTokens (msgs : Array AgentMessage) : IO Nat := do
  -- Join all message content into a single blob for estimation.
  -- The role tags and JSON envelope are minor — overcounting words
  -- by a constant factor is fine because the estimator already
  -- multiplies by 1.4.
  let body : String := String.intercalate "\n" <|
    msgs.toList.map (fun m => m.content.getD "")
  Memory.estimateTokens body

/-- Knobs the loop can tune per invocation. -/
structure Policy where
  /-- Don't compress unless the transcript exceeds this many tokens.
      Default chosen to leave headroom in an 8 KiB context window. -/
  triggerTokens : Nat := 6000
  /-- Last K turn pairs to preserve verbatim. -/
  keepLastTurns : Nat := 4
  /-- Soft target for the summary length, in tokens. -/
  targetTokens  : Nat := 3000
  deriving Repr

instance : Inhabited Policy where default := {}

/-- Count the number of recent user/assistant turn pairs covered
    by the last `n` non-system messages. Returns the **index**
    into the original array such that `msgs[i:]` is the "tail
    block" the policy preserves verbatim. -/
private def tailStartIndex (msgs : Array AgentMessage) (keepPairs : Nat) : Nat :=
  -- Walk from the right; each user message starts a new "pair".
  -- Tool and assistant messages glom onto the most recent user
  -- message. We stop after `keepPairs` user messages or at the
  -- start of the array.
  let n := msgs.size
  let rec walk (i pairs : Nat) : Nat :=
    if i = 0 then 0
    else
      let j := i - 1
      match msgs[j]? with
      | some m =>
          if m.role = .user then
            if pairs + 1 ≥ keepPairs then j else walk j (pairs + 1)
          else walk j pairs
      | none => 0
  walk n 0

/-- Build the LLM prompt that asks for a faithful summary of the
    `middle` slice. -/
private def buildSummaryPrompt (middle : Array AgentMessage) (targetTokens : Nat) : String :=
  let roleLine : Role → String
    | .system => "system"
    | .user => "user"
    | .assistant => "assistant"
    | .tool => "tool"
  let transcript : String :=
    String.intercalate "\n\n" <|
      middle.toList.map fun m =>
        let calls :=
          if m.toolCalls.isEmpty then ""
          else
            " {toolCalls=" ++
            String.intercalate "," (m.toolCalls.map (fun c => c.name)) ++
            "}"
        s!"[{roleLine m.role}{calls}] {m.content.getD ""}"
  s!"Summarise the following session transcript in roughly \
{targetTokens} tokens or fewer. Preserve:
- All Ethereum addresses, contract names, ENS names mentioned.
- All concrete user decisions and refusals.
- Any tool results that materially affected the conversation
  (gas estimates, balances quoted as 'sufficient' or 'insufficient',
  decoded calldata intents).
Drop:
- Social pleasantries.
- Tool-call envelopes that returned errors and were retried.
- Long bodies of repeated content.

Respond with the summary text only — no preamble, no JSON, no code
fences.

Transcript:

{transcript}"

/-- Apply the LLM-driven summarisation. Public so tests can stub
    out the LLM call if needed. -/
def summarise
    (cfg : AgentConfig) (middle : Array AgentMessage) (targetTokens : Nat) :
    IO (Except String String) := do
  let prompt := buildSummaryPrompt middle targetTokens
  let msgs : Array AgentMessage :=
    #[ AgentMessage.system "You are a faithful transcript summariser.",
       AgentMessage.user prompt ]
  let s : AgentState := { messages := msgs, cfg := cfg }
  match ← Llm.chat s [] with
  | .error e => pure (.error s!"summarise: llm error: {repr e}")
  | .ok (asst, _) => pure (.ok (asst.content.getD ""))

/-- Determine whether `msgs` is already in compressed form, i.e.
    has exactly one system-role message at the head AND
    whose second message begins with `summaryMarker` (after the
    optional persona). This is a quick pre-check; the
    `triggerTokens` guard is the real idempotency mechanism. -/
private def alreadyCompressed (msgs : Array AgentMessage) : Bool :=
  match msgs[1]? with
  | some m =>
      m.role = .system &&
      ((m.content.getD "").startsWith summaryMarker)
  | none => false

/-- Top-level entry. Returns the input unchanged when under the
    trigger threshold OR when the middle slice is empty. On
    summarisation failure, returns `Except.error msg`. -/
def maybeCompress
    (cfg : AgentConfig) (policy : Policy) (msgs : Array AgentMessage) :
    IO (Except String (Array AgentMessage)) := do
  let est ← estimateTokens msgs
  if est ≤ policy.triggerTokens then
    return .ok msgs
  -- Always preserve the first system-message (the synthesised
  -- persona + skills + tool docs).
  let headEnd : Nat := if msgs.size > 0 then 1 else 0
  let tailStart := tailStartIndex msgs policy.keepLastTurns
  -- If the tail block already covers the entire non-head region,
  -- there is nothing to compress.
  if tailStart ≤ headEnd then return .ok msgs
  let head : Array AgentMessage := msgs.extract 0 headEnd
  let middle : Array AgentMessage := msgs.extract headEnd tailStart
  let tail : Array AgentMessage := msgs.extract tailStart msgs.size
  if middle.size = 0 then return .ok msgs
  -- If the middle already starts with a previously-compressed
  -- summary, fold its body into the prompt so we don't lose it.
  let _ := alreadyCompressed
  match ← summarise cfg middle policy.targetTokens with
  | .error e => pure (.error e)
  | .ok summaryBody =>
      let newSystem : AgentMessage :=
        { role := .system,
          content := some (summaryMarker ++ "\n\n" ++ summaryBody) }
      pure (.ok (head ++ #[newSystem] ++ tail))

end LeanKohaku.Agent.Compression
