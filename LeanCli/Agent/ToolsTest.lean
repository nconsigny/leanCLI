import LeanCli.Agent.Tools
import LeanCli.Agent.ToolDefs.Decode

/-!
Compile-time exercises over `Agent.Tools.dispatch`. We do not contact
a daemon here — we register a stub tool, call dispatch with and
without the allowlist, and assert the envelope shape.
-/

namespace LeanCli.Agent.Tools.Test

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Encoding.Json

private def echoTool : ToolDecl := {
  name := "echo",
  description := "Return the args unchanged.",
  paramSchema := .obj #[("type", .str "object")],
  classify := .read,
  invoke := fun _cfg args => pure { ok := true, data := args }
}

private def stubCfg : AgentConfig := {
  llmUrl := "http://127.0.0.1:8080/v1/chat/completions",
  model := "test-model",
  daemonSocket := "/dev/null", -- never reached by the echo tool
  toolAllowlist := ["echo"]
}

private def registry : ToolRegistry := [echoTool]

-- A tool in the allowlist routes to its invoke and returns ok = true.
#eval show IO Unit from do
  let r ← dispatch registry stubCfg.toolAllowlist stubCfg
    { id := "1", name := "echo", argsJson := "{\"x\":1}" }
  let xOk : Bool := match getField "x" r.data with
    | some (.num 1) => true
    | _ => false
  if r.ok && xOk then
    pure ()
  else
    throw <| IO.userError s!"echo allow path failed: ok={r.ok} data={compact r.data}"

-- A tool name not in the allowlist is refused before invoke runs.
-- Marker: invoke would fail with a deliberate IO error if it ran.
private def trapTool : ToolDecl := {
  name := "trap",
  description := "Must never run in this test.",
  paramSchema := .obj #[],
  classify := .read,
  invoke := fun _ _ => throw <| IO.userError "trap was invoked"
}

#eval show IO Unit from do
  let r ← dispatch (echoTool :: trapTool :: []) ["echo"] stubCfg
    { id := "2", name := "trap", argsJson := "{}" }
  if r.ok then
    throw <| IO.userError "trap should have been refused, but ok=true"
  -- Match the literal error message produced by `dispatch`.
  match getField "error" r.data with
  | some (.str msg) =>
      if msg.startsWith "tool not in allowlist" then pure ()
      else throw <| IO.userError s!"unexpected refusal message: {msg}"
  | _ => throw <| IO.userError "refusal payload missing 'error' field"

-- Malformed argsJson yields ok = false with a parser-style error
-- message instead of bubbling up an exception.
#eval show IO Unit from do
  let r ← dispatch registry stubCfg.toolAllowlist stubCfg
    { id := "3", name := "echo", argsJson := "not json" }
  if r.ok then throw <| IO.userError "expected failure on malformed args"
  pure ()

-- Decode tools should be registrable into a registry and discoverable
-- by name. We only check the structural API here — no daemon call.
#eval show IO Unit from do
  let reg : ToolRegistry := [
    LeanCli.Agent.ToolDefs.Decode.decodeCalldata,
    LeanCli.Agent.ToolDefs.Decode.decodeEip712
  ]
  match findTool reg "decode_calldata", findTool reg "decode_eip712" with
  | some _, some _ => pure ()
  | _, _ => throw <| IO.userError "decode tools not registrable"

end LeanCli.Agent.Tools.Test
