import LeanKohaku.Encoding.Json

/-!
# Agent loop trace — current-turn observability

A `Trace` is an append-only log of what happened during a single agent
turn: every assistant message the model emitted (with optional
`reasoning_content`), every tool call the model requested, and every
tool result we fed back. It exists solely so the TUI / CLI can render
"how did the agent get here?" — a folded-by-default block under the
assistant's final answer.

## Trust contract (load-bearing)

The trace is **display-only**. Signing decisions still go through
`tx.decodeIntent → tx.simulate → ConfirmGate → eoa.send / r1.send*`;
the trace adds no authority to any path. Tool-result `summary` strings
in the trace are truncated for screen budget — the loop's own internal
`ToolResult.data` is never altered, so the model continues to see full
results.

This module is pure: no IO, no signing imports.
-/

namespace LeanKohaku.Agent.Trace

open LeanKohaku.Encoding.Json

/-- Display-only cap on `toolResult.summary` payloads. The model still
    sees the full result; this is purely a wire / UI budget so a
    multi-KiB hex blob doesn't blow up the trace JSON. -/
def summaryCapBytes : Nat := 200

/-- One entry in a single-turn trace. Tagged inductive so the wire
    format is structurally stable across loop refactors. -/
inductive TraceItem where
  /-- An assistant turn (model output). `reasoning` is whatever the
      backend put in `message.reasoning_content` — Qwen and some R1
      variants emit it; others leave it `none`. -/
  | assistant  (content : String) (reasoning : Option String)
  /-- A tool call the model requested. `idx` is the 0-based call
      index within this turn, used to pair calls with their results
      in the TUI. -/
  | toolCall   (name : String) (argsJson : String) (idx : Nat)
  /-- The reply we fed back for `idx`. `summary` is truncated to
      `summaryCapBytes`; the loop's internal result is unaffected. -/
  | toolResult (idx : Nat) (ok : Bool) (summary : String)
  /-- One `/v1/chat/completions` round-trip. `durationMs` is wall-clock
      measured by `Loop` around the `Llm.chat` call; the token counts
      come from the response's `usage` block when the backend emits one
      (OpenAI, llama.cpp, and vLLM all do; some forks omit it, hence
      `Option`). Emitted by `Loop` immediately after the matching
      `.assistant` item so consumers can pair them by position. -/
  | llmCall    (promptTokens completionTokens totalTokens : Option Nat)
               (durationMs : Nat)
  /-- The set of skills + memory/trusted-registry blocks active for the
      next LLM call. Emitted by `Loop` before every `Llm.chat` round so
      a harness can attribute outcomes to skill activation without log
      scraping. Pure observability — never gates a signing decision. -/
  | skills     (alwaysOn triggered : Array String)
               (memoryActive trustedRegistryActive : Bool)
  deriving Repr, Inhabited

/-- Append-only log built inline as the loop runs. -/
abbrev Trace := Array TraceItem

/-- Structured report returned by the rebuild-system callback alongside
    the rendered system prompt. Carries the names of the skills the
    callback chose to include and whether the optional memory + trusted-
    registry blocks were non-empty. Plain data — no IO. -/
structure SkillReport where
  alwaysOn              : Array String := #[]
  triggered             : Array String := #[]
  memoryActive          : Bool := false
  trustedRegistryActive : Bool := false
  deriving Repr, Inhabited

namespace SkillReport

/-- Empty report — the rebuild callback returns this when no skills,
    memory, or registry block were rendered. -/
def empty : SkillReport := {}

end SkillReport

/-- Truncate `s` to at most `summaryCapBytes` characters and append a
    `…[N bytes]` marker so the user can see the original size at a
    glance. Operates on String.length (Char count) which is good
    enough for a display cap; UTF-8 byte count is reported separately.

    Pure function — no IO. Used for trace summaries only; never for
    data the loop or model relies on for correctness. -/
def truncateForTrace (s : String) : String :=
  let n := s.length
  if n ≤ summaryCapBytes then s
  else
    let head := String.ofList (s.toList.take summaryCapBytes)
    let bytes := s.utf8ByteSize
    head ++ s!"…[{bytes} bytes]"

/-- Encode a single `TraceItem` as JSON. Field names mirror the
    inductive: `kind` is the tag, payload fields are flat under the
    same object. -/
def itemToJson : TraceItem → Json
  | .assistant content reasoning =>
      let reasoningField : Array (String × Json) :=
        match reasoning with
        | some r => #[("reasoning", .str r)]
        | none   => #[]
      .obj <| #[
        ("kind",    .str "assistant"),
        ("content", .str content)
      ] ++ reasoningField
  | .toolCall name argsJson idx =>
      .obj #[
        ("kind",     .str "tool_call"),
        ("idx",      .num (Int.ofNat idx)),
        ("name",     .str name),
        ("argsJson", .str argsJson)
      ]
  | .toolResult idx ok summary =>
      .obj #[
        ("kind",    .str "tool_result"),
        ("idx",     .num (Int.ofNat idx)),
        ("ok",      .bool ok),
        ("summary", .str summary)
      ]
  | .llmCall promptTokens completionTokens totalTokens durationMs =>
      let optNat (k : String) : Option Nat → Array (String × Json)
        | some n => #[(k, .num (Int.ofNat n))]
        | none   => #[]
      .obj <| #[
        ("kind",       .str "llm_call"),
        ("durationMs", .num (Int.ofNat durationMs))
      ] ++ optNat "promptTokens" promptTokens
        ++ optNat "completionTokens" completionTokens
        ++ optNat "totalTokens" totalTokens
  | .skills alwaysOn triggered memoryActive trustedRegistryActive =>
      let strArr (xs : Array String) : Json :=
        .arr (xs.map (fun s => Json.str s))
      .obj #[
        ("kind",                  .str "skills"),
        ("alwaysOn",              strArr alwaysOn),
        ("triggered",             strArr triggered),
        ("memoryActive",          .bool memoryActive),
        ("trustedRegistryActive", .bool trustedRegistryActive)
      ]

/-- Encode an entire `Trace` as a JSON array. -/
def toJson (t : Trace) : Json :=
  .arr (t.map itemToJson)

end LeanKohaku.Agent.Trace
