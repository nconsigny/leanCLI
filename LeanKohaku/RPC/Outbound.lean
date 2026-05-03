import LeanKohaku.Encoding.Json
import LeanKohaku.Network.Provider
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.RPC.JsonRpc

/-!
# Daemon outbound Ethereum JSON-RPC

Production transport boundary for daemon-to-node calls. Every request is
classified before `curl` is invoked.
-/

namespace LeanKohaku.RPC.Outbound

open LeanKohaku.Encoding.Json
open LeanKohaku.Network.Provider
open LeanKohaku.Privacy.NetworkPolicy

structure Endpoint where
  url       : String
  backend   : Backend
  transport : Transport
  deriving Repr

def isLoopbackUrl (url : String) : Bool :=
  url.startsWith "http://127.0.0.1" ||
  url.startsWith "http://localhost" ||
  url.startsWith "http://[::1]" ||
  url.startsWith "http://0.0.0.0"

def endpointFromUrl (url : String) (transport? : Option Transport := none) : Endpoint :=
  if isLoopbackUrl url then
    { url := url, backend := .localNode, transport := .loopback }
  else
    { url := url, backend := .configuredNode, transport := transport?.getD .direct }

/-- Resolve an endpoint from environment only. Fails closed with a clear
error if `LEANKOHAKU_RPC_URL` is unset/empty. The daemon proper uses
`LeanKohaku.Daemon.Config.resolve` which also reads `daemon.json`; this
helper exists for ad-hoc IO sites. No localhost fallback. -/
def resolveEndpoint : IO Endpoint := do
  let url ← match ← IO.getEnv "LEANKOHAKU_RPC_URL" with
    | some url =>
        let trimmed := url.trim
        if trimmed.isEmpty then
          throw <| IO.userError
            "no rpc_url configured: set LEANKOHAKU_RPC_URL (empty value rejected)"
        else
          pure trimmed
    | none =>
        throw <| IO.userError
          "no rpc_url configured: set LEANKOHAKU_RPC_URL or 'rpc_url' in daemon.json"
  let transport? ←
    match ← IO.getEnv "LEANKOHAKU_RPC_TRANSPORT" with
    | some "tor" => pure (some Transport.tor)
    | some "direct" => pure (some Transport.direct)
    | some "loopback" => pure (some Transport.loopback)
    | _ => pure none
  pure (endpointFromUrl url transport?)

def providerConfig (endpoint : Endpoint) : LeanKohaku.Network.Provider.Config :=
  { backend := endpoint.backend, transport := endpoint.transport }

def requestAllowed (policy : Policy) (endpoint : Endpoint)
    (method : RpcMethod) : Bool :=
  permitted policy (providerConfig endpoint) { method := method }

private def verboseLevel : IO Nat := do
  match ← IO.getEnv "LEANKOHAKU_VERBOSE" with
  | some s => pure (s.toNat?.getD 0)
  | none => pure 0

/-- Path for appending a JSONL network event log. Enabled by default at
`$XDG_STATE_HOME/leankohaku/network.log` (or `$HOME/.local/state/...`).
`LEANKOHAKU_NETWORK_LOG` overrides:
  - unset, `1`, `on`, `true`, `yes` → default path
  - `0`, `off`, `false`, `no`        → disabled
  - any other value                  → treated as an explicit log file path -/
def networkLogPath : IO (Option String) := do
  let defaultPath : IO String := do
    let base ←
      match ← IO.getEnv "XDG_STATE_HOME" with
      | some dir => pure dir
      | none =>
          match ← IO.getEnv "HOME" with
          | some home => pure s!"{home}/.local/state"
          | none => pure "/tmp"
    pure s!"{base}/leankohaku/network.log"
  match ← IO.getEnv "LEANKOHAKU_NETWORK_LOG" with
  | none => pure (some (← defaultPath))
  | some "" => pure (some (← defaultPath))
  | some "1" | some "on" | some "true" | some "yes" => pure (some (← defaultPath))
  | some "0" | some "off" | some "false" | some "no" => pure none
  | some path => pure (some path)

private def appendNetLog (line : String) : IO Unit := do
  match ← networkLogPath with
  | none => pure ()
  | some path =>
      try
        let fp : System.FilePath := path
        match fp.parent with
        | some parent => IO.FS.createDirAll parent
        | none => pure ()
        let h ← IO.FS.Handle.mk fp .append
        h.putStr (line ++ "\n")
        h.flush
      catch _ => pure ()

private def logEvent (kind method : String) (extra : Array (String × Json)) : IO Unit := do
  let ts ← IO.monoMsNow
  let fields : Array (String × Json) :=
    #[("ts_ms", .num (Int.ofNat ts)),
      ("kind", .str kind),
      ("method", .str method)] ++ extra
  appendNetLog (compact (.obj fields))

/-- Invariant: every daemon call site must pass `cfg.rpcEndpoint` (the
endpoint resolved at startup from `LEANKOHAKU_RPC_URL` / `daemon.json`).
There is no implicit fallback: `Daemon.Config.resolve` errors out when no
URL is configured, so a non-empty `endpoint.url` here was sourced from
user configuration. We additionally fail closed on an empty URL. -/
def call (policy : Policy) (endpoint : Endpoint) (method : RpcMethod)
    (params : Json) : IO (Except String Json) := do
  if endpoint.url.trim.isEmpty then
    return .error "no rpc_url configured: refusing to dial (set LEANKOHAKU_RPC_URL or 'rpc_url' in daemon.json)"
  unless requestAllowed policy endpoint method do
    logEvent "denied" method.asString
      #[("url", .str endpoint.url),
        ("backend", .str endpoint.backend.asString),
        ("transport", .str endpoint.transport.asString)]
    return .error s!"network policy denied method={method.asString} backend={endpoint.backend.asString} transport={endpoint.transport.asString}"
  let v ← verboseLevel
  let t0 ← IO.monoMsNow
  if v ≥ 1 then
    let paramsRender := if v ≥ 2 then compact params else "..."
    IO.eprintln s!"[rpc→] {method.asString} url={endpoint.url} params={paramsRender}"
  logEvent "request" method.asString
    #[("url", .str endpoint.url),
      ("backend", .str endpoint.backend.asString),
      ("transport", .str endpoint.transport.asString),
      ("params", params)]
  try
    let raw ← LeanKohaku.RPC.JsonRpc.callRaw endpoint.url
      { method := method.asString, params := params, id := 1 }
    let dt := (← IO.monoMsNow) - t0
    match parse raw.trimAscii.toString with
    | .error err =>
        if v ≥ 1 then IO.eprintln s!"[rpc✗] {method.asString} {dt}ms parse-error"
        logEvent "parse-error" method.asString
          #[("ms", .num (Int.ofNat dt)), ("error", .str err)]
        pure (.error s!"invalid JSON-RPC response: {err}")
    | .ok json =>
        match getField "result" json, getField "error" json with
        | some result, _ =>
            if v ≥ 1 then
              let resRender := if v ≥ 2 then s!" result={compact result}" else ""
              IO.eprintln s!"[rpc←] {method.asString} {dt}ms ok{resRender}"
            logEvent "response" method.asString
              #[("ms", .num (Int.ofNat dt)), ("result", result)]
            pure (.ok result)
        | _, some err =>
            if v ≥ 1 then IO.eprintln s!"[rpc✗] {method.asString} {dt}ms error={compact err}"
            logEvent "rpc-error" method.asString
              #[("ms", .num (Int.ofNat dt)), ("error", err)]
            pure (.error s!"Ethereum JSON-RPC error: {compact err}")
        | _, _ =>
            if v ≥ 1 then IO.eprintln s!"[rpc✗] {method.asString} {dt}ms malformed"
            logEvent "malformed" method.asString
              #[("ms", .num (Int.ofNat dt))]
            pure (.error "malformed Ethereum JSON-RPC response")
  catch e =>
    let dt := (← IO.monoMsNow) - t0
    if v ≥ 1 then IO.eprintln s!"[rpc✗] {method.asString} {dt}ms exception={e.toString}"
    logEvent "exception" method.asString
      #[("ms", .num (Int.ofNat dt)), ("error", .str e.toString)]
    pure (.error e.toString)

def getBalance (policy : Policy) (endpoint : Endpoint)
    (address : String) (block : String := "latest") : IO (Except String Json) :=
  call policy endpoint .getBalance (.arr #[.str address, .str block])

def getTransactionCount (policy : Policy) (endpoint : Endpoint)
    (address : String) (block : String := "latest") : IO (Except String Json) :=
  call policy endpoint .getTransactionCount (.arr #[.str address, .str block])

def gasPrice (policy : Policy) (endpoint : Endpoint) : IO (Except String Json) :=
  call policy endpoint .gasPrice (.arr #[])

def maxPriorityFeePerGas (policy : Policy) (endpoint : Endpoint) : IO (Except String Json) :=
  call policy endpoint .maxPriorityFeePerGas (.arr #[])

def estimateGas (policy : Policy) (endpoint : Endpoint) (tx : Json)
    (block : String := "latest") : IO (Except String Json) :=
  call policy endpoint .estimateGas (.arr #[tx, .str block])

def ethCall (policy : Policy) (endpoint : Endpoint)
    (to data : String) (block : String := "latest") : IO (Except String Json) :=
  call policy endpoint .call
    (.arr #[
      .obj #[("to", .str to), ("data", .str data)],
      .str block
    ])

def sendRawTransaction (policy : Policy) (endpoint : Endpoint)
    (rawTx : String) : IO (Except String Json) :=
  call policy endpoint .sendRawTransaction (.arr #[.str rawTx])

def getTransactionReceipt (policy : Policy) (endpoint : Endpoint)
    (txHash : String) : IO (Except String Json) :=
  call policy endpoint .getTransactionReceipt (.arr #[.str txHash])

def blockNumber (policy : Policy) (endpoint : Endpoint) : IO (Except String Json) :=
  call policy endpoint .blockNumber (.arr #[])

/-- Single eth_getLogs query with explicit block range, address, and topics. -/
def getLogs (policy : Policy) (endpoint : Endpoint)
    (fromBlockHex toBlockHex address : String) (topics : Array Json) :
    IO (Except String Json) :=
  call policy endpoint .getLogs
    (.arr #[
      .obj #[
        ("fromBlock", .str fromBlockHex),
        ("toBlock", .str toBlockHex),
        ("address", .str address),
        ("topics", .arr topics)
      ]
    ])

end LeanKohaku.RPC.Outbound
