import LeanKohaku.Agent.State
import LeanKohaku.Agent.Persona

/-!
# System-prompt assembly for the Lean-native agent

`buildSystemPrompt` returns the full system message for a given
`AgentConfig`. It is `persona ++ operational rules ++ tool docs` —
each block intentionally explicit so a diff against the persona
shows exactly which behavioural rule changed.

`Tools.lean` supplies the tool-docs block via a small `ToolDoc`
record passed in here. That avoids an import cycle (Tools depends on
State; this depends on State + Persona).
-/

namespace LeanKohaku.Agent.Prompt

open LeanKohaku.Agent
open LeanKohaku.Agent.Persona

/-- Operator-supplied tool descriptor for prompt rendering. Kept
    distinct from `Tools.ToolDecl` to break the import cycle. -/
structure ToolDoc where
  name        : String
  description : String

/-- Render a single tool as one bullet for the system prompt. -/
def renderTool (t : ToolDoc) : String :=
  s!"  - `{t.name}` — {t.description}"

/-- Static operational rules — chain whitelist + tool discipline. The
    chain numerals are interpolated rather than hardcoded so a future
    config change is one place to edit. -/
def operationalRules (cfg : AgentConfig) : String :=
  let chains := cfg.chainWhitelist.map toString
  let chainList := String.intercalate ", " chains
  s!"OPERATING RULES (hard):
- Allowed chain ids: \{{chainList}}. Refuse any task that targets a
  different chain.
- Use tools to verify facts before proposing a send. Do NOT guess
  contract addresses, decimals, or balances from your prior
  knowledge — call the read tools.
- Stop calling tools and emit your final answer once you have what
  you need. The step budget is {cfg.maxSteps} rounds.
- Single tool call per turn unless the calls are independent. Avoid
  fan-out unless each call's result is needed regardless of the
  others.
- Surface tool errors verbatim instead of paraphrasing them.
- Final answer for any send is a single `propose_send` tool call
  whose payload is `\{to, value, data, chainId}`. Never inline a
  signature.
"

/-- Build the full system prompt: persona + operational rules + a
    bullet list of available tools and their descriptions. -/
def buildSystemPrompt (cfg : AgentConfig) (tools : List ToolDoc) : String :=
  let toolHeader := "TOOLS AVAILABLE (call by name; do not invent tool names):"
  let toolBlock :=
    if tools.isEmpty then
      "  (no tools enabled for this invocation; you are answer-only)"
    else
      String.intercalate "\n" (tools.map renderTool)
  String.intercalate "\n\n"
    [ kohakuPersona
    , operationalRules cfg
    , toolHeader ++ "\n" ++ toolBlock ]

end LeanKohaku.Agent.Prompt
