import LeanKohaku.Agent.State
import LeanKohaku.Agent.Http
import LeanKohaku.Agent.Tools
import LeanKohaku.Encoding.Json

/-!
# OpenAI-compatible chat completions client

Single-call POST to `<llmUrl>/chat/completions` over the local
loopback HTTP shim. The shape is OpenAI-compatible because every
local backend we support (`llama.cpp`'s server, vLLM, Ollama's `/v1`)
implements that surface; no per-server forking.

Each call sends the current message transcript plus the schemas of
the tools the operator allowed for the invocation, parses the
single-turn response, and returns an `AgentMessage`. The agent loop
in `Agent.Loop` is in charge of multiplexing tool calls and feeding
their results back in.
-/

namespace LeanKohaku.Agent.Llm

open LeanKohaku.Agent
open LeanKohaku.Encoding.Json

/-- Error returned to the loop. `transport` covers HTTP / loopback /
    socket failures; `protocol` covers a successful HTTP exchange with
    a body we cannot decode as a chat response. -/
inductive Error where
  | transport (msg : String)
  | protocol  (msg : String)
  deriving Repr

/-- Per-call cost stats parsed from the chat-completions response's
    optional `usage` block. Every field is `Option` because:

    * Some OpenAI-compat forks (notably older llama.cpp builds) omit the
      `usage` object entirely on streamed-and-then-flattened responses.
    * Even when the block is present, individual fields can be missing
      depending on backend version.

    `Loop` pairs these with the wall-clock duration it measured around
    the `chat` call and pushes the combined `TraceItem.llmCall` into the
    per-turn trace. Pure data — never gates a signing decision. -/
structure CallStats where
  promptTokens     : Option Nat := none
  completionTokens : Option Nat := none
  totalTokens      : Option Nat := none
  deriving Repr, Inhabited

namespace CallStats

/-- Empty stats — used when the backend omitted the `usage` block. -/
def empty : CallStats := {}

end CallStats

private def roleToWire : Role → String
  | .system    => "system"
  | .user      => "user"
  | .assistant => "assistant"
  | .tool      => "tool"

private def messageToJson (m : AgentMessage) : Json :=
  let baseFields : Array (String × Json) := #[
    ("role", .str (roleToWire m.role))
  ]
  let contentField : Array (String × Json) := #[
    ("content", match m.content with
      | some s => .str s
      | none   => .str "")
  ]
  let toolCallsField : Array (String × Json) :=
    if m.toolCalls.isEmpty then #[] else
      let calls : Array Json := m.toolCalls.toArray.map fun c =>
        .obj #[
          ("id",   .str c.id),
          ("type", .str "function"),
          ("function", .obj #[
            ("name",      .str c.name),
            ("arguments", .str c.argsJson)
          ])
        ]
      #[("tool_calls", .arr calls)]
  let toolCallIdField : Array (String × Json) :=
    match m.toolCallId with
    | some s => #[("tool_call_id", .str s)]
    | none   => #[]
  .obj (baseFields ++ contentField ++ toolCallsField ++ toolCallIdField)

private def toolToSchemaJson (t : Tools.ToolDecl) : Json :=
  .obj #[
    ("type", .str "function"),
    ("function", .obj #[
      ("name",        .str t.name),
      ("description", .str t.description),
      ("parameters",  t.paramSchema)
    ])
  ]

/-- Build the JSON body POSTed to `/chat/completions`. The `tools`
    list is included only when non-empty; OpenAI-compat servers
    typically tolerate an empty array but vLLM is stricter.

    `enable_thinking` is passed two ways for portability:

    * Inside `chat_template_kwargs` — the vLLM-canonical location for
      passing arguments to a chat template; Qwen3 / Qwen3.5's template
      reads this flag and skips the `<think>` block when false.
    * At the top level — some Qwen-specific OpenAI-compat forks expose
      it directly. Backends that don't recognize the field discard it.

    The field tracks `s.cfg.enableThinking` so an operator can flip it
    per invocation. See `AgentConfig.enableThinking` for the rationale
    on defaulting to false. -/
def buildRequestBody
    (s : AgentState) (tools : List Tools.ToolDecl) : String :=
  let baseFields : Array (String × Json) := #[
    ("model",       .str s.cfg.model),
    ("max_tokens",  .num (Int.ofNat s.cfg.maxTokens)),
    ("temperature", .num 0), -- explicit; deterministic mode
    ("stream",      .bool false),
    ("messages",    .arr (s.messages.map messageToJson)),
    ("enable_thinking", .bool s.cfg.enableThinking),
    ("chat_template_kwargs", .obj #[
      ("enable_thinking", .bool s.cfg.enableThinking)
    ])
  ]
  let toolFields : Array (String × Json) :=
    if tools.isEmpty then #[]
    else #[
      ("tools", .arr (tools.toArray.map toolToSchemaJson)),
      ("tool_choice", .str "auto")
    ]
  compact (.obj (baseFields ++ toolFields))

private def parseToolCalls (msg : Json) : List ToolCall :=
  match getField "tool_calls" msg with
  | some (.arr arr) =>
      arr.toList.filterMap fun call =>
        match call with
        | .obj _ =>
            let id := (getField "id" call >>= asString).getD ""
            let fn := getField "function" call
            let name := (fn >>= getField "name" >>= asString).getD ""
            let argsJson := (fn >>= getField "arguments" >>= asString).getD "{}"
            if name.isEmpty then none
            else some { id := id, name := name, argsJson := argsJson }
        | _ => none
  | _ => []

/-- Truncate a response body for inclusion in a protocol error.
    Keeps the user-facing message bounded while still surfacing
    what the LLM backend actually returned. The full body is
    `IO.eprintln`'d separately to journalctl so the operator can
    see everything without restarting the daemon. -/
private def excerptForError (txt : String) : String :=
  let cap : Nat := 500
  if txt.length ≤ cap then txt
  else (txt.take cap).toString ++ s!"…[+{txt.length - cap} more]"

/-- Decode the first `choices[0].message` of a chat-completions
    response into our `AgentMessage` shape. `rawTxt` is the original
    response body, passed through so protocol-shape errors can
    surface what the LLM actually returned (a llama-server context
    overflow returns `{"error":...}` with no `choices` key — the
    previous version reported only "missing 'choices'" without the
    underlying cause). -/
def decodeChoiceMessage (resp : Json) (rawTxt : String) :
    Except Error AgentMessage := do
  let some choicesJ := getField "choices" resp
    | .error (.protocol s!"chat response missing 'choices'; body: {excerptForError rawTxt}")
  let some choices := asArray choicesJ
    | .error (.protocol s!"chat response 'choices' not array; body: {excerptForError rawTxt}")
  let some choice := choices[0]?
    | .error (.protocol s!"chat response 'choices' is empty; body: {excerptForError rawTxt}")
  let some msg := getField "message" choice
    | .error (.protocol s!"chat response choice missing 'message'; body: {excerptForError rawTxt}")
  let content : Option String := getField "content" msg >>= asString
  -- `reasoning_content` is the OpenAI-compat field Qwen3.5 and some
  -- R1 backends emit alongside `content`. Captured here purely so
  -- `Agent.Trace` can surface it in the TUI's foldable trace block —
  -- it is NOT echoed back to the model and never influences signing.
  let reasoning : Option String :=
    getField "reasoning_content" msg >>= asString
  let toolCalls := parseToolCalls msg
  .ok {
    role := .assistant,
    content := content,
    toolCalls := toolCalls,
    reasoning := reasoning
  }

/-- Decode the optional `usage` block on a chat-completions response.
    Missing fields stay `none` — the backend gets to omit them and the
    consumer (the agent loop) records only what it was actually told. -/
def decodeUsage (resp : Json) : CallStats :=
  match getField "usage" resp with
  | some u =>
      { promptTokens     := getField "prompt_tokens" u >>= asNat,
        completionTokens := getField "completion_tokens" u >>= asNat,
        totalTokens      := getField "total_tokens" u >>= asNat }
  | none => CallStats.empty

/-- One chat-completions round-trip. Returns the assistant message
    parsed from `choices[0].message` paired with the `usage` block
    parsed from the same response. -/
def chat
    (s : AgentState) (tools : List Tools.ToolDecl) :
    IO (Except Error (AgentMessage × CallStats)) := do
  let body := buildRequestBody s tools
  match ← Http.postJson s.cfg.llmUrl body s.cfg.timeoutMs with
  | .error (.transport m) => return .error (.transport s!"http transport: {m}")
  | .error (.nonLoopback m) => return .error (.transport s!"non-loopback: {m}")
  | .error (.tooLarge) => return .error (.transport "response exceeded 8 MiB cap")
  | .error (.timeout) => return .error (.transport "http timeout")
  | .error (.nonJsonResponse m) => return .error (.protocol m)
  | .ok resp =>
      match Http.Response.bodyString resp with
      | .error _ => return .error (.protocol "response body not valid UTF-8")
      | .ok txt =>
          match parse txt with
          | .error e => return .error (.protocol s!"response not JSON: {e}: {excerptForError txt}")
          | .ok j =>
              let result := decodeChoiceMessage j txt
              -- On any protocol-shape failure, dump the FULL body to
              -- stderr so the operator can pull it out of journalctl
              -- without restarting the daemon. The user-facing error
              -- carries only the truncated prefix.
              match result with
              | .error (.protocol m) =>
                  IO.eprintln s!"[llm] protocol error; full response body follows:\n{txt}"
                  return .error (.protocol m)
              | .error e => return .error e
              | .ok msg  => return .ok (msg, decodeUsage j)

end LeanKohaku.Agent.Llm
