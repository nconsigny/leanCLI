import LeanCli.Encoding.Json
import LeanCli.Privacy.NetworkPolicy

/-!
# JSON-RPC 2.0 client

Minimal client for talking to Ethereum nodes. JSON parsing/serialization
stays in Lean to keep the "everything in Lean" promise.

Transport code must be mediated by `LeanCli.Privacy.NetworkPolicy`.
The CLI must never call this module directly. The daemon may use it only
for local/light-client reads and strictly necessary transaction broadcast.
-/

namespace LeanCli.RPC.JsonRpc

open LeanCli.Privacy.NetworkPolicy
open LeanCli.Encoding.Json

structure Request where
  method : String
  params : Json
  id     : Nat
  deriving Repr

structure Response where
  id     : Nat
  result : Option Json
  error  : Option Json
  deriving Repr

/-- Classify an Ethereum JSON-RPC method before transport code can send it. -/
def purposeForMethod (method : String) : Purpose :=
  if method = "eth_sendRawTransaction" then
    Purpose.broadcastTx
  else
    Purpose.nodeRead

def requestPolicyCheck (policy : Policy) (peer : Peer) (transport : Transport) (req : Request) : Bool :=
  policy { peer := peer, purpose := purposeForMethod req.method, transport := transport }

def encodeRequest (req : Request) : String :=
  compact <| .obj #[
    ("jsonrpc", .str "2.0"),
    ("method", .str req.method),
    ("params", req.params),
    ("id", .num (Int.ofNat req.id))
  ]

/-- HTTP transport metrics captured from `curl -w`. All fields are best-
    effort: older curl builds may not surface every variable, so each
    field is `Option`. -/
structure RawResponse where
  body       : String
  httpStatus : Option Nat := none
  bytes      : Option Nat := none
  remoteIp   : Option String := none
  deriving Repr

private def metricsSentinel : String := "\n--LK_CURL_METRICS--\n"

/-- HTTP shell-out with metric capture. Appends a sentinel-delimited
    metrics record (status / bytes / remote IP) to the response body via
    `curl -w` so we can surface "what server did the daemon actually
    reach" without taking a dep on a Lean HTTP client.

    Timeouts: `--connect-timeout 5` bounds DNS+TCP handshake; `--max-time
    20` bounds the whole operation. Without these curl waits forever on
    a stuck endpoint, which in fan-out callers (e.g. `swap.balances`'s
    18 parallel ERC20+ETH balance reads) presents to the user as a TUI
    stuck on "loading balances…" with no failure signal. On timeout
    curl exits 28 → we throw → `IO.asTask` records `.error` → caller
    surfaces or drops per its fail-soft rule. -/
def callRawDetailed (rpcUrl : String) (req : Request) : IO RawResponse := do
  let writeFmt :=
    metricsSentinel ++ "%{http_code}|%{size_download}|%{remote_ip}"
  let out ← IO.Process.output
    { cmd := "curl",
      args := #[
        "-sS",
        "--connect-timeout", "5",
        "--max-time", "20",
        "-H", "content-type: application/json",
        "--data", encodeRequest req,
        "-w", writeFmt,
        rpcUrl
      ] }
  if out.exitCode != 0 then
    throw <| IO.userError out.stderr
  let parts := out.stdout.splitOn metricsSentinel
  match parts with
  | [body, metrics] =>
      match metrics.splitOn "|" with
      | [statusS, bytesS, ip] =>
          let trimIp := ip.trimAscii.toString
          pure {
            body := body,
            httpStatus := statusS.trimAscii.toString.toNat?,
            bytes := bytesS.trimAscii.toString.toNat?,
            remoteIp := if trimIp.isEmpty then none else some trimIp
          }
      | _ => pure { body := body }
  | _ => pure { body := out.stdout }

def callRaw (rpcUrl : String) (req : Request) : IO String := do
  let r ← callRawDetailed rpcUrl req
  pure r.body

def ethSendRawTransaction (rpcUrl rawTxHex : String) : IO String :=
  callRaw rpcUrl { method := "eth_sendRawTransaction", params := .arr #[.str rawTxHex], id := 1 }

def ethCall (rpcUrl to data : String) : IO String :=
  callRaw rpcUrl
    { method := "eth_call",
      params := .arr #[
        .obj #[("to", .str to), ("data", .str data)],
        .str "latest"
      ],
      id := 1 }

end LeanCli.RPC.JsonRpc
