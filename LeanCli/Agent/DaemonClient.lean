import LeanCli.Transport.Uds
import LeanCli.Encoding.Json

/-!
# UDS JSON-RPC client used by agent tools

Thin client over the daemon socket. One-shot per call: open, write
request line, drain, close. The daemon's RPC handler responds with a
single JSON object terminated by `\n` (see
`LeanCli/Daemon/Server.lean::serve`); we read until end-of-stream
and parse the last line.

Trust model: every tool that reads chain state goes through this
client. The daemon enforces `Privacy.NetworkPolicy` on the resulting
RPC; nothing the agent can ask for bypasses that gate. The agent
never asks the daemon to sign — there is no path here for
`eoa.send` / `r1.send*`.
-/

namespace LeanCli.Agent.DaemonClient

open LeanCli.Encoding.Json
open LeanCli.Transport.Uds

private def maxResponseBytes : Nat := 1024 * 1024 -- 1 MiB cap

/-- A daemon RPC failure. `transport` means the socket failed;
    `protocol` means we got bytes back but they did not parse as a
    JSON-RPC response. `appError` is the daemon's own `error` envelope.
    -/
inductive Error where
  | transport (msg : String)
  | protocol  (msg : String)
  | appError  (code : Int) (message : String) (data : Option Json)
  deriving Repr

/-- Encode a JSON-RPC 2.0 request with a fixed id (the daemon does not
    care about the value — it echoes it back). -/
private def encodeReq (method : String) (params : Json) : String :=
  compact (.obj #[
    ("jsonrpc", .str "2.0"),
    ("method",  .str method),
    ("params",  params),
    ("id",      .num 1)
  ]) ++ "\n"

/-- Read everything available from the connection up to `cap` bytes.
    Uses a fixed-size chunked loop because the underlying `read`
    returns at most `maxBytes` bytes per call. -/
private partial def drainConn
    (conn : Conn) (acc : ByteArray) (remaining : Nat) : IO ByteArray := do
  -- PHASE_N: prove termination — bounded by `remaining` decreasing
  -- monotonically until either EOF or the cap is reached. Marked
  -- partial only because the read-loop's termination depends on a
  -- runtime invariant we have not yet hoisted into types.
  if remaining = 0 then
    return acc
  let chunkSize : UInt32 := (min remaining 65536).toUInt32
  let chunk ← read conn chunkSize
  if chunk.size = 0 then
    return acc -- EOF
  else
    let next := acc ++ chunk
    drainConn conn next (remaining - chunk.size)

/-- Extract the last JSON object from the streamed body. The daemon
    may emit one or more lines; the canonical reply is on the last
    non-empty line. -/
private def lastJsonLine (raw : String) : String :=
  let trimmed := raw.trimAscii.toString
  match trimmed.splitOn "\n" |>.reverse |>.dropWhile (·.trimAscii.toString.isEmpty) with
  | first :: _ => first
  | [] => trimmed

/-- Dispatch a single `method, params` call to the daemon. Returns
    the `result` field on success, or a structured `Error` on any
    failure. -/
def call
    (socketPath : String) (method : String) (params : Json) :
    IO (Except Error Json) := do
  try
    let conn ← connect socketPath
    try
      let _ ← write conn (encodeReq method params).toByteArray
      let bytes ← drainConn conn ByteArray.empty maxResponseBytes
      let body := String.fromUTF8! bytes
      let line := lastJsonLine body
      match parse line with
      | .error e => return .error (.protocol s!"daemon reply not JSON: {e}: {line}")
      | .ok j =>
          match getField "error" j with
          | some (.obj ef) =>
              let code := match (ef.findSome? (fun (k, v) =>
                  if k = "code" then some v else none)).getD .null with
                | .num n => n
                | _ => -32603
              let msg := match (ef.findSome? (fun (k, v) =>
                  if k = "message" then some v else none)).getD .null with
                | .str s => s
                | _ => "daemon error"
              let data := ef.findSome? (fun (k, v) =>
                if k = "data" then some v else none)
              return .error (.appError code msg data)
          | _ =>
              match getField "result" j with
              | some r => return .ok r
              | none => return .error (.protocol s!"daemon reply missing result: {line}")
    finally
      close conn
  catch e =>
    return .error (.transport (toString e))

end LeanCli.Agent.DaemonClient
