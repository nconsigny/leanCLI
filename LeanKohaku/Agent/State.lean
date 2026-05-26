/-!
# Lean-native agent state types

Plain data — no IO, no signing imports. The agent runs as the
`kohaku-agent` executable; this module defines what a single
one-shot agent invocation looks like in memory.

Trust contract: nothing in `LeanKohaku/Agent/**` imports any of the
signing or key-material modules. The full forbidden-import list lives
in `docs/PHASE0_PLAN.md`; the acceptance gate greps for those names so
the canonical reference stays in one place. The agent proposes; the
daemon signs.
-/

namespace LeanKohaku.Agent

/-- Chat role tags as they appear on the wire to an
    OpenAI-compatible /v1/chat/completions endpoint. -/
inductive Role where
  | system
  | user
  | assistant
  | tool
  deriving Repr, DecidableEq, Inhabited

/-- Wire shape: a model-emitted tool call. `argsJson` is the raw JSON
    string the model produced — keeping it as text lets us reject
    malformed arguments without rebuilding the call structure. -/
structure ToolCall where
  id       : String
  name     : String
  argsJson : String
  deriving Repr, Inhabited

/-- One transcript message. `content` is optional because a turn that
    carries `tool_calls` may legally omit user-visible content. -/
structure AgentMessage where
  role       : Role
  content    : Option String := none
  toolCalls  : List ToolCall := []
  /-- Only set on `role = tool` messages; references the call this
      result responds to. -/
  toolCallId : Option String := none
  /-- OpenAI-compat `message.reasoning_content`, when the backend
      emits one (Qwen3.5 and some R1 variants do; gpt-4o-class
      models do not). Captured for the per-turn trace surface
      (`Agent.Trace`) and never sent back to the model — it is
      display-only and has no influence on signing or tool dispatch. -/
  reasoning  : Option String := none
  deriving Repr, Inhabited

/-- Static configuration for a single agent invocation. Most fields are
    bounded so a runaway model cannot hold the loop open indefinitely. -/
structure AgentConfig where
  /-- Loopback URL of the OpenAI-compatible chat endpoint — must
      satisfy `LeanKohaku.Agent.Http.isLoopbackUrl`. -/
  llmUrl         : String
  /-- Model id (passed through to the server's `model` field). -/
  model          : String
  /-- Hard cap on tool-call rounds. 16 is the empirical floor for the
      common multi-tool flows we hit in production (swap = token_lookup
      ×2 + slot_lookup + chain_read + nonce + simulate + propose_send,
      with at least one chain_denied / unknown_token self-correction
      round on a 4B-param local model). Each step can fan out multiple
      tool calls per turn, so 16 round-trips is conservative; the cost
      is more LLM calls per user turn when the model loops on a hard
      question, bounded by the per-call timeout. Tune downward only
      after watching real sessions. -/
  maxSteps       : Nat   := 16
  /-- Per-call output ceiling sent to the LLM as `max_tokens`. 2048
      bounds a single turn to ~37s at 55 t/s (typical local-MoE
      generation rate) — still snappy for multi-tool flows while
      leaving the model enough room to emit a full `propose_send`
      tool-call payload (132-hex calldata for `approve` alone runs
      ~280 chars of tool-call JSON; the 1024 ceiling was hitting
      mid-string on llama-server, which then returned HTTP 500 with
      `Failed to parse tool call arguments as JSON` instead of a
      usable partial response). The Brief Mode bullet in
      `Prompt.operationalRules` still nudges the model to be
      structured rather than discursive. -/
  maxTokens      : Nat   := 2048
  temperature    : Float := 0.2
  timeoutMs      : Nat   := 30000
  /-- Allowed chain ids for any tool that takes one. Phase 0 ships
      mainnet (1) + Sepolia (11155111) only — no L2 strings anywhere. -/
  chainWhitelist : List Nat := [1, 11155111]
  /-- Path to the daemon UDS socket the agent uses for tool dispatch. -/
  daemonSocket   : String
  /-- Tool names the operator allowed for this invocation. Anything
      outside this list is rejected before the daemon is contacted. -/
  toolAllowlist  : List String
  /-- Qwen3 / Qwen3.5 "thinking" toggle. When false (the default), the
      chat-completions request body carries
      `chat_template_kwargs.enable_thinking = false` so the model emits
      tool calls / final answers without the pre-output `<think>...</think>`
      block. Thinking is wall-clock expensive (10-30s per turn) and the
      wallet's safety doesn't depend on the model's reasoning — every
      tool call is validated by `Tools.dispatch` (chain pin, allowlist),
      every Intent is hard-rejected by `IntentParser`, and every
      signing decision terminates at `ConfirmGate`. Flip to true only
      for diagnosis of a model that's pattern-matching badly.

      Lean-side default chosen per a 2026-05-26 product decision; vLLM
      ignores unknown `chat_template_kwargs` entries so emitting this
      against a non-Qwen backend is a no-op rather than an error. -/
  enableThinking : Bool  := false

/-- Mutable per-loop state. The loop body in `Agent.Loop` consumes and
    returns this with `steps` advanced. -/
structure AgentState where
  messages : Array AgentMessage
  steps    : Nat := 0
  cfg      : AgentConfig

namespace AgentMessage

/-- Build a system-prompt message. -/
def system (content : String) : AgentMessage :=
  { role := .system, content := some content }

/-- Build a user-prompt message. -/
def user (content : String) : AgentMessage :=
  { role := .user, content := some content }

end AgentMessage

end LeanKohaku.Agent
