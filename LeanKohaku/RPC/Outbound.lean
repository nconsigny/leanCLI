import LeanKohaku.Encoding.Json
import LeanKohaku.Network.Provider
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.RPC.JsonRpc
import LeanKohaku.Colibri.Persistent

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
  /-- The chain this endpoint serves, when known. Populated by
  `endpointForChain` (which knows the chain name → id mapping) and
  read by the policy layer so testnet endpoints can have a more
  permissive default than mainnet. Optional for backward
  compatibility with callers that don't yet know the chain. -/
  chainId   : Option Nat := none
  deriving Repr

def isLoopbackUrl (url : String) : Bool :=
  url.startsWith "http://127.0.0.1" ||
  url.startsWith "http://localhost" ||
  url.startsWith "http://[::1]" ||
  url.startsWith "http://0.0.0.0"

/-- Best-effort host extraction from a URL: strips the scheme and returns
    everything up to the first `/` or `?`. Surfaces `<unknown>` when the
    URL doesn't look like one we recognise. Used purely for logging — no
    network logic depends on this. -/
def hostOfUrl (url : String) : String := Id.run do
  let chars := url.toList
  let afterScheme : List Char :=
    let dropPrefix (p : List Char) (xs : List Char) : Option (List Char) :=
      let rec go : List Char → List Char → Option (List Char)
        | [], rest => some rest
        | _ :: _, [] => none
        | a :: as, b :: bs => if a = b then go as bs else none
      go p xs
    match dropPrefix "https://".toList chars with
    | some r => r
    | none =>
        match dropPrefix "http://".toList chars with
        | some r => r
        | none =>
            match dropPrefix "wss://".toList chars with
            | some r => r
            | none =>
                match dropPrefix "ws://".toList chars with
                | some r => r
                | none => chars
  let mut acc : String := ""
  for c in afterScheme do
    if c = '/' || c = '?' then return acc
    acc := acc.push c
  return acc

def endpointFromUrl (url : String) (transport? : Option Transport := none)
    (chainId? : Option Nat := none) : Endpoint :=
  if isLoopbackUrl url then
    { url := url, backend := .localNode, transport := .loopback, chainId := chainId? }
  else
    { url := url, backend := .configuredNode, transport := transport?.getD .direct, chainId := chainId? }

/-- Map a configured chain *name* to its canonical chain ID. The
supported set is intentionally narrow — **mainnet and sepolia only**.
Anything else returns `none`, and the policy layer treats unknown
chains as strict. Numeric strings are also accepted as a literal
chainId so a future "add the chain you want" override stays open. -/
def chainNameToId : String → Option Nat
  | "mainnet"          => some 1
  | "ethereum"         => some 1
  | "sepolia"          => some 11155111
  | name               => name.toNat?

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
  permitted policy (providerConfig endpoint) { method := method } endpoint.chainId

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

/-- Outcome of one verified-read attempt. Distinguishes a real JSON-RPC
    error (which the upstream colibri sidecar produced and we should
    propagate as-is) from a transport-level failure (broken pipe / dead
    sidecar) that warrants respawn-and-fallback. -/
inductive ColibriOutcome where
  | ok            (result : Json)
  | rpcError      (msg : String)
  /-- Transport-level failure: the persistent UDS conn is unusable. The
      caller should fall back to HTTP and notify the user that verified
      reads were disabled. The recovery hook on `VerifyVia` will have
      already been invoked once before this is returned. -/
  | transportDead (reason : String)
  deriving Repr

/-- Optional verified-read backend. When supplied AND the method is
    proofable, the request is routed through the Colibri stateless light
    client over the persistent UDS instead of the configured HTTP
    endpoint. State is pulled via committee-signed Merkle proofs, so the
    result is verified against consensus. Non-proofable methods
    (sendRawTransaction, debug_traceCall) always go over HTTP regardless.

    `runCall` is a closure built per-request by the daemon (`Server.lean`'s
    `colibriVia`). It owns the policy for transport-crash recovery:
    auto-respawn once on broken pipe, then surface `.transportDead` so the
    Outbound layer can fall back to HTTP. The closure is the only place
    that has both the shared `DaemonState` and the sidecar socket path,
    so respawn lives there rather than here. -/
structure VerifyVia where
  chainId : Nat
  runCall : RpcMethod → Json → IO ColibriOutcome

/-- Invariant: every daemon call site must pass `cfg.rpcEndpoint` (the
endpoint resolved at startup from `LEANKOHAKU_RPC_URL` / `daemon.json`).
There is no implicit fallback: `Daemon.Config.resolve` errors out when no
URL is configured, so a non-empty `endpoint.url` here was sourced from
user configuration. We additionally fail closed on an empty URL.

When `via?` is supplied AND the method is `RpcMethod.proofable`, the call
is satisfied by the Colibri light client. The HTTP path is still used for
non-proofable methods (writes / debug tracers) even with `via?` set. -/
def call (policy : Policy) (endpoint : Endpoint) (method : RpcMethod)
    (params : Json) (via? : Option VerifyVia := none) :
    IO (Except String Json) := do
  -- Route proofable reads through the persistent Colibri client when
  -- enabled. Logged through the same network log so audit trails stay
  -- coherent — the entry just shows backend=colibri.
  match via? with
  | some via =>
      if method.proofable then
        let chainId := via.chainId
        let t0 ← IO.monoMsNow
        let v ← verboseLevel
        if v ≥ 1 then
          let paramsRender := if v ≥ 2 then compact params else "..."
          IO.eprintln s!"[rpc→colibri] {method.asString} chainId={chainId} params={paramsRender}"
        logEvent "request" method.asString
          #[("backend", .str "colibri"),
            ("host", .str "colibri.uds"),
            ("transport", .str "loopback"),
            ("chainId", .num (Int.ofNat chainId)),
            ("params", params)]
        -- Why: `runCall` is responsible for at most one respawn-and-retry
        -- on transport crashes; it returns `.transportDead` only after that
        -- attempt has been made and failed (or been refused). Outbound
        -- then falls through to the HTTP path so the user still gets data.
        let outcome ← via.runCall method params
        let dt := (← IO.monoMsNow) - t0
        match outcome with
        | .ok j =>
            if v ≥ 1 then
              let resRender := if v ≥ 2 then s!" result={compact j}" else ""
              IO.eprintln s!"[rpc←colibri] {method.asString} {dt}ms ok{resRender}"
            logEvent "response" method.asString
              #[("backend", .str "colibri"),
                ("host", .str "colibri.uds"),
                ("transport", .str "loopback"),
                ("ms", .num (Int.ofNat dt)),
                ("result", j)]
            return .ok j
        | .rpcError e =>
            if v ≥ 1 then IO.eprintln s!"[rpc✗colibri] {method.asString} {dt}ms {e}"
            logEvent "rpc-error" method.asString
              #[("backend", .str "colibri"),
                ("host", .str "colibri.uds"),
                ("transport", .str "loopback"),
                ("ms", .num (Int.ofNat dt)),
                ("error", .str e)]
            return .error e
        | .transportDead reason =>
            -- Verified-read backend is gone for this call. Log the
            -- transport death, log the explicit colibri-disabled event so
            -- the audit trail records the policy decision, and fall
            -- through to the HTTP path below. The terminal event for THIS
            -- proofable call will be the HTTP response/exception logged
            -- after the fall-through; the colibri side has already logged
            -- its own rpc-error / respawn / disabled events.
            if v ≥ 1 then
              IO.eprintln s!"[rpc✗colibri] {method.asString} {dt}ms transport-dead: {reason}"
            logEvent "colibri-disabled" method.asString
              #[("backend", .str "colibri"),
                ("host", .str "colibri.uds"),
                ("transport", .str "loopback"),
                ("ms", .num (Int.ofNat dt)),
                ("reason", .str reason),
                ("fallback", .str "http")]
            IO.eprintln s!"leankohaku-daemon: colibri verified-reads disabled ({reason}); falling back to HTTP for {method.asString}. Re-enable with `daemon.colibri.toggle` once the sidecar is back."
            -- fall through
  | none => pure ()
  if endpoint.url.trim.isEmpty then
    return .error "no rpc_url configured: refusing to dial (set LEANKOHAKU_RPC_URL or 'rpc_url' in daemon.json)"
  let host := hostOfUrl endpoint.url
  unless requestAllowed policy endpoint method do
    let chainTag : String := match endpoint.chainId with
      | none => "unknown"
      | some n => toString n
    logEvent "denied" method.asString
      #[("url", .str endpoint.url),
        ("host", .str host),
        ("backend", .str endpoint.backend.asString),
        ("transport", .str endpoint.transport.asString),
        ("chainId", .str chainTag)]
    return .error s!"network policy denied method={method.asString} backend={endpoint.backend.asString} transport={endpoint.transport.asString} chainId={chainTag}"
  let v ← verboseLevel
  let t0 ← IO.monoMsNow
  if v ≥ 1 then
    let paramsRender := if v ≥ 2 then compact params else "..."
    IO.eprintln s!"[rpc→] {method.asString} url={endpoint.url} params={paramsRender}"
  logEvent "request" method.asString
    #[("url", .str endpoint.url),
      ("host", .str host),
      ("backend", .str endpoint.backend.asString),
      ("transport", .str endpoint.transport.asString),
      ("params", params)]
  try
    let raw ← LeanKohaku.RPC.JsonRpc.callRawDetailed endpoint.url
      { method := method.asString, params := params, id := 1 }
    let dt := (← IO.monoMsNow) - t0
    let txExtra : Array (String × Json) :=
      let s : Array (String × Json) :=
        match raw.httpStatus with
        | some n => #[("httpStatus", .num (Int.ofNat n))]
        | none => #[]
      let s := s ++ (match raw.bytes with
        | some n => #[("bytes", .num (Int.ofNat n))]
        | none => #[])
      let s := s ++ (match raw.remoteIp with
        | some ip => #[("remoteIp", .str ip)]
        | none => #[])
      s ++ #[("host", .str host)]
    match parse raw.body.trimAscii.toString with
    | .error err =>
        if v ≥ 1 then IO.eprintln s!"[rpc✗] {method.asString} {dt}ms parse-error"
        logEvent "parse-error" method.asString
          (#[("ms", .num (Int.ofNat dt)), ("error", .str err)] ++ txExtra)
        pure (.error s!"invalid JSON-RPC response: {err}")
    | .ok json =>
        match getField "result" json, getField "error" json with
        | some result, _ =>
            if v ≥ 1 then
              let resRender := if v ≥ 2 then s!" result={compact result}" else ""
              IO.eprintln s!"[rpc←] {method.asString} {dt}ms ok{resRender}"
            logEvent "response" method.asString
              (#[("ms", .num (Int.ofNat dt)), ("result", result)] ++ txExtra)
            pure (.ok result)
        | _, some err =>
            if v ≥ 1 then IO.eprintln s!"[rpc✗] {method.asString} {dt}ms error={compact err}"
            logEvent "rpc-error" method.asString
              (#[("ms", .num (Int.ofNat dt)), ("error", err)] ++ txExtra)
            pure (.error s!"Ethereum JSON-RPC error: {compact err}")
        | _, _ =>
            if v ≥ 1 then IO.eprintln s!"[rpc✗] {method.asString} {dt}ms malformed"
            logEvent "malformed" method.asString
              (#[("ms", .num (Int.ofNat dt))] ++ txExtra)
            pure (.error "malformed Ethereum JSON-RPC response")
  catch e =>
    let dt := (← IO.monoMsNow) - t0
    if v ≥ 1 then IO.eprintln s!"[rpc✗] {method.asString} {dt}ms exception={e.toString}"
    logEvent "exception" method.asString
      #[("ms", .num (Int.ofNat dt)),
        ("host", .str host),
        ("error", .str e.toString)]
    pure (.error e.toString)

def getBalance (policy : Policy) (endpoint : Endpoint)
    (address : String) (block : String := "latest")
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .getBalance (.arr #[.str address, .str block]) via?

def getTransactionCount (policy : Policy) (endpoint : Endpoint)
    (address : String) (block : String := "latest")
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .getTransactionCount (.arr #[.str address, .str block]) via?

def gasPrice (policy : Policy) (endpoint : Endpoint)
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .gasPrice (.arr #[]) via?

def maxPriorityFeePerGas (policy : Policy) (endpoint : Endpoint)
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .maxPriorityFeePerGas (.arr #[]) via?

def estimateGas (policy : Policy) (endpoint : Endpoint) (tx : Json)
    (block : String := "latest")
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .estimateGas (.arr #[tx, .str block]) via?

def ethCall (policy : Policy) (endpoint : Endpoint)
    (to data : String) (block : String := "latest")
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .call
    (.arr #[
      .obj #[("to", .str to), ("data", .str data)],
      .str block
    ]) via?

def sendRawTransaction (policy : Policy) (endpoint : Endpoint)
    (rawTx : String) : IO (Except String Json) :=
  -- Writes never proofable; never accepts via?.
  call policy endpoint .sendRawTransaction (.arr #[.str rawTx])

def getTransactionReceipt (policy : Policy) (endpoint : Endpoint)
    (txHash : String) (via? : Option VerifyVia := none) :
    IO (Except String Json) :=
  call policy endpoint .getTransactionReceipt (.arr #[.str txHash]) via?

def blockNumber (policy : Policy) (endpoint : Endpoint)
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .blockNumber (.arr #[]) via?

/-- Single eth_getLogs query with explicit block range, address, and topics. -/
def getLogs (policy : Policy) (endpoint : Endpoint)
    (fromBlockHex toBlockHex address : String) (topics : Array Json)
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .getLogs
    (.arr #[
      .obj #[
        ("fromBlock", .str fromBlockHex),
        ("toBlock", .str toBlockHex),
        ("address", .str address),
        ("topics", .arr topics)
      ]
    ]) via?

/-- eth_getLogs over a block range filtered only by `topics`, with no
contract-address filter. Used by address-freshness scans where we want
"any ERC-20 contract emitted a Transfer involving this address" across
the whole chain in the window. Note: public providers may rate-limit
or cap this heavier query — callers must treat failures as "unknown",
not "0 link". -/
def getLogsAnyAddress (policy : Policy) (endpoint : Endpoint)
    (fromBlockHex toBlockHex : String) (topics : Array Json)
    (via? : Option VerifyVia := none) : IO (Except String Json) :=
  call policy endpoint .getLogs
    (.arr #[
      .obj #[
        ("fromBlock", .str fromBlockHex),
        ("toBlock", .str toBlockHex),
        ("topics", .arr topics)
      ]
    ]) via?

end LeanKohaku.RPC.Outbound
