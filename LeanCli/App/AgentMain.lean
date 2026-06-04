import LeanCli.Agent.State
import LeanCli.Agent.Prompt
import LeanCli.Agent.Tools
import LeanCli.Agent.Registry
import LeanCli.Agent.Loop
import LeanCli.Encoding.Json

/-!
# `leancli-agent` executable

Drop-in replacement for the legacy `bridge/llm/bridge.mjs` Node
sidecar. Accepts a JSON-RPC 2.0 request on `--rpc '<json>'`, runs the
one-shot agent loop for `llm.parseIntent`, emits exactly one
JSON-RPC envelope line on stdout.

Trust contract (Phase 0):
* This module imports no signing or key-material module. See
  `docs/PHASE0_PLAN.md` for the exact forbidden-import list — the
  acceptance gate greps for those names and the list is maintained
  in one place to avoid false positives in prose here.
* The only path to the network is through `Agent.Http`
  (loopback-only) and `Agent.DaemonClient` (existing UDS surface).
* The only path to a signature is the upstream consumer's
  `ConfirmGate`; this binary cannot sign.
-/

namespace LeanCli.App.AgentMain

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Encoding.Json

private def protocolVersion : String := "0.0.1"

private def defaultLlmUrl : String := "http://127.0.0.1:8080/v1/chat/completions"

/-- Resolve the daemon socket path. Preference order:
    1. `LEANCLI_DAEMON_SOCKET` (agent-specific override).
    2. `LEANCLI_SOCKET` (existing CLI/TUI convention).
    3. `<XDG_RUNTIME_DIR>/leancli/leancli.sock`
       (fallback to `/tmp` when the env var is unset). -/
private def resolveDaemonSocket : IO String := do
  match ← IO.getEnv "LEANCLI_DAEMON_SOCKET" with
  | some s => pure s
  | none =>
      match ← IO.getEnv "LEANCLI_SOCKET" with
      | some s => pure s
      | none =>
          let runtime ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
            | some d => pure d
            | none =>
                match ← IO.getEnv "TMPDIR" with
                | some d => pure d
                | none => pure "/tmp"
          pure s!"{runtime}/leancli/leancli.sock"

private def resolveLlmUrl : IO String := do
  match ← IO.getEnv "LEANCLI_AGENT_LLM_URL" with
  | some s => pure s
  | none =>
      -- Back-compat with the legacy sidecar's variable name.
      match ← IO.getEnv "LOCAL_LLM_BASE_URL" with
      | some base => pure (base ++ "/chat/completions")
      | none => pure defaultLlmUrl

private def resolveModel : IO String := do
  match ← IO.getEnv "LEANCLI_AGENT_MODEL" with
  | some s => pure s
  | none =>
      match ← IO.getEnv "LOCAL_LLM_MODEL" with
      | some s => pure s
      | none => pure "local-default"

private def jsonEnvelopeOk (id : Json) (result : Json) : String :=
  compact (.obj #[
    ("jsonrpc", .str "2.0"),
    ("id", id),
    ("result", result)
  ])

private def jsonEnvelopeErr
    (id : Json) (code : Int) (message : String) : String :=
  compact (.obj #[
    ("jsonrpc", .str "2.0"),
    ("id", id),
    ("error", .obj #[
      ("code", .num code),
      ("message", .str message)
    ])
  ])

private def idOf (req : Json) : Json :=
  (getField "id" req).getD .null

/-- Build an AgentConfig that the operator can narrow via the
    request params. The toolAllowlist defaults to the full default
    registry surface so a one-shot request with no explicit allowlist
    works out of the box. -/
private def buildCfg
    (llmUrl model daemonSocket : String) (params : Json) : AgentConfig :=
  let defaultAllow : List String :=
    Registry.default.map (·.name)
  let allowlist : List String :=
    match getField "toolAllowlist" params with
    | some (.arr arr) =>
        arr.toList.filterMap (fun j => asString j)
    | _ => defaultAllow
  {
    llmUrl := llmUrl,
    model := model,
    daemonSocket := daemonSocket,
    toolAllowlist := allowlist
  }

/-- Build the initial transcript: system prompt + the user's prompt. -/
private def buildTranscript (cfg : AgentConfig) (params : Json) :
    Except String (Array AgentMessage) := do
  let some promptJ := getField "prompt" params
    | .error "missing required field 'prompt'"
  let some prompt := asString promptJ
    | .error "'prompt' must be a string"
  let visibleTools : List Prompt.ToolDoc :=
    Tools.toToolDocs (filterByAllowlist Registry.default cfg.toolAllowlist)
  let sys := Prompt.buildSystemPrompt cfg visibleTools
  .ok #[ AgentMessage.system sys, AgentMessage.user prompt ]

/-- Dispatch one JSON-RPC method. Returns the wire string to emit. -/
def dispatch (req : Json) : IO String := do
  let id := idOf req
  let method := (getField "method" req >>= asString).getD ""
  let params := (getField "params" req).getD (.obj #[])
  match method with
  | "ping" =>
      pure (jsonEnvelopeOk id (.obj #[
        ("ok", .bool true),
        ("protocol", .str protocolVersion)
      ]))
  | "version" =>
      let llmUrl ← resolveLlmUrl
      let model ← resolveModel
      let socket ← resolveDaemonSocket
      pure (jsonEnvelopeOk id (.obj #[
        ("protocol", .str protocolVersion),
        ("agent", .obj #[
          ("backend", .str "lean-agent"),
          ("llmUrl", .str llmUrl),
          ("model", .str model),
          ("daemonSocket", .str socket)
        ])
      ]))
  | "llm.parseIntent" =>
      let llmUrl ← resolveLlmUrl
      let model ← resolveModel
      let socket ← resolveDaemonSocket
      let cfg := buildCfg llmUrl model socket params
      match buildTranscript cfg params with
      | .error e => pure (jsonEnvelopeErr id (-32602) s!"invalid params: {e}")
      | .ok msgs =>
          let s₀ : AgentState := { messages := msgs, cfg := cfg }
          match ← Loop.runOneShot s₀ Registry.default with
          | .error e => pure (jsonEnvelopeErr id (-32603) e)
          | .ok finalMsg =>
              -- Byte-compatible with the legacy sidecar: the daemon's
              -- LlmAgent.Bridge reads `result.raw` as the model's
              -- final-turn JSON. We pass through the assistant
              -- content as-is so the daemon's IntentParser stays the
              -- trust boundary.
              let raw := finalMsg.content.getD ""
              pure (jsonEnvelopeOk id (.obj #[
                ("raw", .str raw),
                ("backend", .str "lean-agent"),
                ("model", .str model),
                ("toolTurns", .num (Int.ofNat (msgs.size + 1)))
              ]))
  | _ =>
      pure (jsonEnvelopeErr id (-32601) s!"method not found: {method}")

/-- Find `--rpc '<json>'` in argv. Returns the JSON string. -/
private def findRpcArg : List String → Option String
  | "--rpc" :: v :: _ => some v
  | _ :: rest => findRpcArg rest
  | [] => none

def main (args : List String) : IO UInt32 := do
  match findRpcArg args with
  | none =>
      IO.eprintln "usage: leancli-agent --rpc '<json-rpc-request>'"
      pure 2
  | some raw =>
      match parse raw with
      | .error e =>
          IO.println (jsonEnvelopeErr .null (-32700) s!"parse error: {e}")
          pure 0
      | .ok req =>
          let line ← dispatch req
          IO.println line
          pure 0

end LeanCli.App.AgentMain

def main (args : List String) : IO UInt32 :=
  LeanCli.App.AgentMain.main args
