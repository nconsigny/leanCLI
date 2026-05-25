import LeanKohaku.Agent.State
import LeanKohaku.Agent.Prompt
import LeanKohaku.Agent.DaemonClient
import LeanKohaku.Encoding.Json

/-!
# Agent tool surface

A tool is the agent's only way to reach the chain. Every tool either
hits the daemon (`chain_read`, `decode_calldata`, …) or assembles a
local payload (`propose_send`); none sign, none broadcast.

Three pieces:
* `ToolDecl` — declarative descriptor of one tool.
* `ToolRegistry` — collection used at dispatch time.
* `dispatch` — allowlist check + invocation + result envelope.

The allowlist is enforced **in code** before any tool runs. The model
cannot widen its own surface by emitting an unlisted name.
-/

namespace LeanKohaku.Agent.Tools

open LeanKohaku.Agent
open LeanKohaku.Agent.DaemonClient
open LeanKohaku.Encoding.Json

/-- Classify the side effect a tool can have. A `propose` tool emits
    a draft send; `read` tools strictly read chain state. There is no
    `sign` classification by design. -/
inductive ToolClass where
  | read
  | propose
  deriving Repr, DecidableEq

/-- Outcome of one tool invocation, ready to be embedded into a
    `role = tool` message. -/
structure ToolResult where
  ok    : Bool
  /-- Free-form JSON payload returned to the model. -/
  data  : Json
  /-- Optional one-line summary for the model. -/
  summary : Option String := none

/-- Declarative descriptor of a single tool. `paramSchema` is a JSON
    Schema fragment the chat completions API will see; `invoke` is the
    Lean implementation. -/
structure ToolDecl where
  name        : String
  description : String
  paramSchema : Json
  classify    : ToolClass
  invoke      : AgentConfig → Json → IO ToolResult

/-- Map a list of declarations to `ToolDoc`s consumed by `Prompt`. -/
def toToolDocs (tools : List ToolDecl) : List Prompt.ToolDoc :=
  tools.map fun t => { name := t.name, description := t.description }

/-- A registry is just a list — order is preserved so the prompt
    renders tools in declaration order. -/
abbrev ToolRegistry := List ToolDecl

/-- Look up a tool by name. O(n) in the registry size; fine for the
    sub-ten-tool surface we expect. -/
def findTool (reg : ToolRegistry) (name : String) : Option ToolDecl :=
  reg.find? (fun t => t.name = name)

/-- Filter a registry down to the operator's allowlist, preserving
    order. Names in the allowlist but missing from the registry are
    silently dropped — the allowlist is "names the operator
    *permits*", not "names that *must* exist". -/
def filterByAllowlist (reg : ToolRegistry) (allow : List String) : ToolRegistry :=
  reg.filter (fun t => allow.contains t.name)

/-- Build a `ToolResult` from a `DaemonClient.Error`. -/
private def daemonErrorResult (method : String) (e : DaemonClient.Error) : ToolResult :=
  let payload : Json := match e with
    | .transport m =>
        .obj #[("error", .str s!"daemon transport ({method}): {m}")]
    | .protocol m =>
        .obj #[("error", .str s!"daemon protocol ({method}): {m}")]
    | .appError code msg _ =>
        .obj #[
          ("error", .str s!"daemon {method} error {code}: {msg}"),
          ("code", .num code)
        ]
  { ok := false, data := payload }

/-- Convenience used by every chain-reading tool: dispatch one daemon
    method, wrap the response as a `ToolResult`. -/
def daemonCall
    (cfg : AgentConfig) (method : String) (params : Json) : IO ToolResult := do
  match ← DaemonClient.call cfg.daemonSocket method params with
  | .error e => pure (daemonErrorResult method e)
  | .ok j    => pure { ok := true, data := j }

/-- Allowlist-checking dispatch. Returns a tool-result envelope even on
    rejection so the model sees structured feedback rather than the
    loop terminating on it.

    Chain pin: when the parsed args carry a `chainId` field AND
    `cfg.chainWhitelist` is non-empty AND the call's chainId is not on
    the whitelist, return a structured `{ok:false, kind:"chain_denied"}`
    envelope without running the tool. The model sees the rejection in
    the trace and self-corrects on the next turn (we deliberately do
    NOT auto-rewrite the call — trusting the loop over the model's
    first guess is the whole point of this gate). -/
def dispatch
    (reg : ToolRegistry) (allow : List String)
    (cfg : AgentConfig) (call : ToolCall) : IO ToolResult := do
  if !allow.contains call.name then
    return {
      ok := false,
      data := .obj #[
        ("error", .str s!"tool not in allowlist: {call.name}"),
        ("allowlist", .arr (allow.toArray.map (fun s => .str s)))
      ]
    }
  match findTool reg call.name with
  | none =>
      return {
        ok := false,
        data := .obj #[("error", .str s!"unknown tool: {call.name}")]
      }
  | some decl =>
      match parse call.argsJson with
      | .error e =>
          return {
            ok := false,
            data := .obj #[("error", .str s!"tool {call.name} args not JSON: {e}")]
          }
      | .ok args =>
          -- Active-chain gate. We only enforce when the tool args
          -- actually carry a `chainId` field (read tools without one,
          -- e.g. `slot_lookup`, are unaffected). A non-numeric value is
          -- left to the tool's own arg validator.
          match getField "chainId" args >>= asNat with
          | some cid =>
              if !cfg.chainWhitelist.isEmpty ∧ !cfg.chainWhitelist.contains cid then
                let allowedJson : Array Json :=
                  cfg.chainWhitelist.toArray.map (fun n => .num (Int.ofNat n))
                return {
                  ok := false,
                  data := .obj #[
                    ("kind",    .str "chain_denied"),
                    ("error",
                      .str s!"chainId {cid} not in active whitelist {cfg.chainWhitelist}"),
                    ("allowed", .arr allowedJson)
                  ]
                }
              else
                try
                  decl.invoke cfg args
                catch e =>
                  return {
                    ok := false,
                    data := .obj #[("error", .str s!"tool {call.name} raised: {toString e}")]
                  }
          | none =>
              try
                decl.invoke cfg args
              catch e =>
                return {
                  ok := false,
                  data := .obj #[("error", .str s!"tool {call.name} raised: {toString e}")]
                }

/-- Render a `ToolResult` as the `content` string of a `role = tool`
    message. Compact JSON keeps prompt overhead small. -/
def resultToContent (r : ToolResult) : String :=
  let summaryField : Array (String × Json) := match r.summary with
    | some s => #[("summary", .str s)]
    | none   => #[]
  compact <| .obj <| #[
    ("ok", .bool r.ok),
    ("data", r.data)
  ] ++ summaryField

end LeanKohaku.Agent.Tools
