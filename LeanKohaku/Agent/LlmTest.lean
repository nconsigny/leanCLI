import LeanKohaku.Agent.Llm
import LeanKohaku.Agent.ToolDefs.Decode

/-!
Compile-time exercises over the pure pieces of `Agent.Llm` —
`buildRequestBody` shape + `decodeChoiceMessage` parser. No HTTP is
performed.
-/

namespace LeanKohaku.Agent.Llm.Test

open LeanKohaku.Agent
open LeanKohaku.Agent.Llm
open LeanKohaku.Encoding.Json

private def cfg : AgentConfig := {
  llmUrl := "http://127.0.0.1:8080/v1/chat/completions",
  model := "qwen-test",
  daemonSocket := "/tmp/leankohaku.sock",
  toolAllowlist := ["decode_calldata"]
}

private def stateWithMessages : AgentState := {
  messages := #[
    AgentMessage.system "rules go here",
    AgentMessage.user "what does this do?"
  ],
  cfg := cfg
}

-- A model and the two messages are present in the request body.
#eval show IO Unit from do
  let body := buildRequestBody stateWithMessages
    [LeanKohaku.Agent.ToolDefs.Decode.decodeCalldata]
  if body.contains "qwen-test" && body.contains "rules go here"
      && body.contains "decode_calldata"
      && body.contains "\"tool_choice\":\"auto\""
  then pure ()
  else throw <| IO.userError s!"buildRequestBody output unexpected: {body}"

-- A chat response with a final assistant message + no tool_calls
-- parses to an AgentMessage with content set and toolCalls empty.
#eval show IO Unit from do
  let raw := "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}"
  match parse raw with
  | .error e => throw <| IO.userError s!"raw not JSON: {e}"
  | .ok j =>
      match decodeChoiceMessage j with
      | .error e => throw <| IO.userError s!"decode failed: {repr e}"
      | .ok msg =>
          if msg.content = some "ok" && msg.toolCalls.isEmpty then pure ()
          else throw <| IO.userError s!"unexpected parse: content={msg.content}, calls={msg.toolCalls.length}"

-- A chat response with structured tool_calls is decoded into our
-- ToolCall list with id / name / argsJson preserved.
#eval show IO Unit from do
  let raw := "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"decode_calldata\",\"arguments\":\"{\\\"chainId\\\":1}\"}}]}}]}"
  match parse raw with
  | .error e => throw <| IO.userError s!"raw not JSON: {e}"
  | .ok j =>
      match decodeChoiceMessage j with
      | .error e => throw <| IO.userError s!"decode failed: {repr e}"
      | .ok msg =>
          match msg.toolCalls with
          | [tc] =>
              if tc.id = "call_1" && tc.name = "decode_calldata"
                  && tc.argsJson = "{\"chainId\":1}"
              then pure ()
              else throw <| IO.userError s!"tool call decoded wrong: {repr tc}"
          | _ => throw <| IO.userError s!"expected exactly 1 tool_call, got {msg.toolCalls.length}"

end LeanKohaku.Agent.Llm.Test
