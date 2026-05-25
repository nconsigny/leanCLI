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
- Token addresses and decimals are NOT in your training data. Before
  producing calldata that references a token, call
  `token_lookup(\{chainId, query})` with the user's chosen symbol or
  address. If the response is `kind:\"unknown_token\"`, ASK the user
  for the canonical address on that chain — do not guess. NEVER
  compute base-unit conversions in your head; call
  `to_base_units(\{amount, decimals})` with the decimals returned by
  `token_lookup`.
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

/-- One-line addition to the operational rules used in the seed-locked
    case. The trusted registry would otherwise tell the LLM "these
    addresses are yours"; when locked the LLM must explicitly refuse to
    assume any address is the user's own without explicit confirmation.
    See `docs/PHASE1D_THREAT_MODEL.md` §3 and §5. -/
def lockedSeedAddendum : String :=
  "- User's seed is locked: do NOT claim any address is the user's \
   own without explicit user confirmation. There is no Trusted \
   Registry to draw on this session."

/-- Build the full system prompt: persona + operational rules + a
    bullet list of available tools and their descriptions. -/
def buildSystemPrompt (cfg : AgentConfig) (tools : List ToolDoc) : String :=
  buildSystemPromptWithSkills cfg tools [] []
where
  /-- Build the system prompt with explicit always-on and
      trigger-matched skill bodies. The order is
      `persona → always-on skills → trigger skills → operational
      rules → tool docs`, mirroring the spec in `docs/PHASE1B_PLAN.md`.
      Empty lists collapse to no extra blocks. -/
  buildSystemPromptWithSkills
      (cfg : AgentConfig) (tools : List ToolDoc)
      (alwaysOnSkills triggerSkills : List String) : String :=
    buildSystemPromptFull cfg tools "" "" alwaysOnSkills triggerSkills
  /-- Build the system prompt with an optional rendered memory
      block AND an optional trusted-registry block. The order
      (Phase 1d) is:
      `persona → memory → trusted registry → always-on skills →
       trigger skills → operational rules → tool docs`.
      The `memoryRendered` and `trustedRegistryRendered` strings are
      included verbatim when non-empty and omitted entirely (no
      header, no marker) when empty.

      When `trustedRegistryRendered` is empty the operational rules
      get a one-line addendum (`lockedSeedAddendum`) so the LLM does
      not silently invent ownership claims. See
      `docs/PHASE1D_THREAT_MODEL.md` §3, §5. -/
  buildSystemPromptFull
      (cfg : AgentConfig) (tools : List ToolDoc)
      (memoryRendered trustedRegistryRendered : String)
      (alwaysOnSkills triggerSkills : List String) : String :=
    let toolHeader := "TOOLS AVAILABLE (call by name; do not invent tool names):"
    let toolBlock :=
      if tools.isEmpty then
        "  (no tools enabled for this invocation; you are answer-only)"
      else
        String.intercalate "\n" (tools.map renderTool)
    let memoryBlock :=
      if memoryRendered.trimAscii.toString.isEmpty then [] else [memoryRendered]
    let registryBlock :=
      if trustedRegistryRendered.trimAscii.toString.isEmpty then []
      else [trustedRegistryRendered]
    let alwaysOnBlock :=
      if alwaysOnSkills.isEmpty then []
      else [String.intercalate "\n\n" alwaysOnSkills]
    let triggerBlock :=
      if triggerSkills.isEmpty then []
      else [String.intercalate "\n\n" triggerSkills]
    let ops :=
      if trustedRegistryRendered.trimAscii.toString.isEmpty then
        operationalRules cfg ++ "\n" ++ lockedSeedAddendum
      else
        operationalRules cfg
    String.intercalate "\n\n"
      ([ kohakuPersona ]
       ++ memoryBlock
       ++ registryBlock
       ++ alwaysOnBlock
       ++ triggerBlock
       ++ [ ops
          , toolHeader ++ "\n" ++ toolBlock ])

/-- Convenience exporter so callers can use the inner builder without
    going through the no-skills entrypoint. -/
def buildSystemPromptWithSkills
    (cfg : AgentConfig) (tools : List ToolDoc)
    (alwaysOnSkills triggerSkills : List String) : String :=
  buildSystemPrompt.buildSystemPromptWithSkills
    cfg tools alwaysOnSkills triggerSkills

/-- Convenience exporter for the full variant including memory and
    the Phase-1d trusted-registry block. Pre-Phase-1d callers can
    pass `""` for `trustedRegistryRendered` to opt out (which is
    equivalent to the seed-locked case — the locked-seed addendum
    is still appended to operational rules). -/
def buildSystemPromptFull
    (cfg : AgentConfig) (tools : List ToolDoc)
    (memoryRendered trustedRegistryRendered : String)
    (alwaysOnSkills triggerSkills : List String) : String :=
  buildSystemPrompt.buildSystemPromptFull
    cfg tools memoryRendered trustedRegistryRendered alwaysOnSkills triggerSkills

end LeanKohaku.Agent.Prompt
