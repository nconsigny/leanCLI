import LeanKohaku.Basic
import LeanKohaku.Daemon.Server.Core
import LeanKohaku.Daemon.Server.Helpers
import LeanKohaku.Daemon.Server.Endpoints
import LeanKohaku.Daemon.Server.Journal
import LeanKohaku.Daemon.Server.BookRpc
import LeanKohaku.Daemon.Server.SwapRpc
import LeanKohaku.Daemon.Server.TpmRpc
import LeanKohaku.Daemon.Server.MiscRpc
import LeanKohaku.Daemon.Server.AccountRpc
import LeanKohaku.Daemon.Server.ChatRpc
import LeanKohaku.Daemon.Server.TxRpc
import LeanKohaku.Daemon.Server.WalletRpc
import LeanKohaku.Daemon.Server.SphincsRpc
import LeanKohaku.Daemon.Server.ChainRpc
import LeanKohaku.Daemon.Server.ShieldedRpc
import LeanKohaku.Daemon.Server.EoaRpc
import LeanKohaku.Daemon.Server.DaemonRpc
import LeanKohaku.Daemon.AddressBook
import LeanKohaku.Daemon.LlmServer
import LeanKohaku.Daemon.Log
import LeanKohaku.Daemon.SkillsStore
import LeanKohaku.Daemon.State
import LeanKohaku.Daemon.Status
import LeanKohaku.Daemon.PpDestinations
import LeanKohaku.Daemon.TxJournal
import LeanKohaku.Daemon.Uds
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.Privacy.Bridge
import LeanKohaku.Clearsign.Bridge
import LeanKohaku.Sphincs.Bridge
import LeanKohaku.Sphincs.UserOp
import LeanKohaku.Sphincs.Send
import LeanKohaku.Colibri.Bridge
import LeanKohaku.Colibri.Persistent
import LeanKohaku.Helios.Bridge
import LeanKohaku.Helios.Persistent
import LeanKohaku.Daemon.Preflight
import LeanKohaku.Daemon.TokenMeta
import LeanKohaku.Daemon.EnsNames
import LeanKohaku.LlmAgent.Bridge
import LeanKohaku.LlmAgent.DirectSynth
import LeanKohaku.LlmAgent.IntentParser
import LeanKohaku.LlmAgent.RuleParser
import LeanKohaku.Cli.Commands
import LeanKohaku.Cli.NetworkConfig
import LeanKohaku.RPC.Outbound
import LeanKohaku.RPC.Server
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Eip712
import LeanKohaku.Ethereum.Ens
import LeanKohaku.Ethereum.Intent
import LeanKohaku.Ethereum.IntentCanonical
import LeanKohaku.Ethereum.IntentEncode
import LeanKohaku.Ethereum.IntentJson
import LeanKohaku.Ethereum.Ownership
import LeanKohaku.Ethereum.Tx
import LeanKohaku.Keystore.Tpm2Runtime
import LeanKohaku.Keystore.MasterKey
import LeanKohaku.Keystore.MasterPassphrase
import LeanKohaku.Wallet.Address
import LeanKohaku.Wallet.Bip44
import LeanKohaku.Wallet.EoaStore
import LeanKohaku.Wallet.Entropy
import LeanKohaku.Wallet.EOA
import LeanKohaku.Wallet.HDKey
import LeanKohaku.Wallet.Mnemonic
import LeanKohaku.Wallet.PpSecretStore
import LeanKohaku.Wallet.RgSecretStore
import LeanKohaku.Wallet.SphincsHybridStore
import LeanKohaku.Registry.KnownProtocols
import LeanKohaku.Swap.Tokens
import LeanKohaku.Swap.UniV3
import LeanKohaku.Swap.Prepare
import LeanKohaku.Aave.Prepare
import LeanKohaku.Util.Units
import LeanKohaku.Invariants.Swap

/-!
# Daemon server

Long-running process that exposes wallet operations over a local socket.
The daemon is the only component allowed to perform Ethereum node I/O, and
every attempted connection must pass `Privacy.NetworkPolicy`.
-/

namespace LeanKohaku.Daemon.Server

open LeanKohaku.Encoding.Json
open LeanKohaku.Keystore.Tpm2Runtime
open LeanKohaku.Wallet.Account
open LeanKohaku.Privacy.NetworkPolicy
open LeanKohaku.RPC.Server

-- Why: no `defaultConfig` with a URL substitute. The daemon must refuse to
-- start without a user-configured `rpc_url` (env or daemon.json); see
-- `LeanKohaku.Daemon.Config.resolve`. Avoids any silent loopback dial.



/-- JSON-RPC error code returned when a shielded handler that requires the
    Privacy-Pools spending secret is invoked but no encrypted secret is
    stored on disk. The CLI surfaces this as a friendly hint. -/
def methodHandler (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  -- Phase-4 onwards: per-family dispatch modules under
  -- `Server/<Family>Rpc.lean`. Prefix-route here, then fall through
  -- to the in-file match for families still pending extraction.
  if req.method.startsWith "book." then
    return ← BookRpc.dispatch cfg state notify req
  if req.method.startsWith "swap." then
    return ← SwapRpc.dispatch cfg state notify req
  if req.method.startsWith "tpm." || req.method.startsWith "r1." then
    return ← TpmRpc.dispatch cfg state notify req
  if req.method.startsWith "llm." || req.method.startsWith "skills."
      || req.method.startsWith "clearsign." || req.method.startsWith "aave." then
    return ← MiscRpc.dispatch cfg state notify req
  if req.method.startsWith "account." then
    return ← AccountRpc.dispatch cfg state notify req
  if req.method.startsWith "chat." then
    return ← ChatRpc.dispatch cfg state notify req
  if req.method.startsWith "tx." then
    return ← TxRpc.dispatch cfg state notify req
  if req.method.startsWith "wallet." then
    return ← WalletRpc.dispatch cfg state notify req
  if req.method.startsWith "sphincs." then
    return ← SphincsRpc.dispatch cfg state notify req
  if req.method.startsWith "chain." then
    return ← ChainRpc.dispatch cfg state notify req
  if req.method.startsWith "shielded." then
    return ← ShieldedRpc.dispatch cfg state notify req
  if req.method.startsWith "eoa." then
    return ← EoaRpc.dispatch cfg state notify req
  if req.method.startsWith "daemon." || req.method.startsWith "status."
      || req.method.startsWith "network." then
    return ← DaemonRpc.dispatch cfg state notify req
  pure (.error methodNotFound)


/-- Body of `handleConn` — all the request reading and dispatch.
    Extracted so it can be wrapped in a `try/catch` that converts
    any escaping IO error into a JSON-RPC error frame written on
    the connection. -/
private def handleConnBody (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (conn : LeanKohaku.Daemon.Uds.Conn) : IO Unit := do
  let started ← IO.monoMsNow
  let sameUid ← LeanKohaku.Daemon.Uds.peerUidMatchesCurrent conn
  if !sameUid then
    let response := compact <| errorResponse .null
      { code := -32001, message := "peer uid rejected" }
    discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
    LeanKohaku.Daemon.Log.write .warn "<peer>" ((← IO.monoMsNow) - started) false
      (some "peer uid rejected")
  else
    -- `readLine` buffers across SOCK_STREAM `read(2)` chunks until
    -- the terminating `\n`, so a request the kernel splits doesn't
    -- truncate into a parse error here.
    let bytes ← LeanKohaku.Daemon.Uds.readLine conn
    match decodeRequestBytes bytes with
    | .error err =>
        let response := compact <| errorResponse .null
          { parseError with data := some (.str err) }
        discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
        LeanKohaku.Daemon.Log.write .warn "<parse>" ((← IO.monoMsNow) - started) false
          (some err)
    | .ok line =>
        let parsed := LeanKohaku.RPC.Server.parseRequest line
        let method :=
          match parsed with
          | .ok req => req.method
          | .error _ => "<parse>"
        -- UDS-backed notifier: emit JSON-RPC notification frames
        -- (no `id`, no `result`/`error`) on the same connection
        -- before the final response. The CLI client buffers and
        -- splits on `\n`, rendering each notification before
        -- returning the response.
        let notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier :=
          fun event params => do
            let frame : Json := .obj #[
              ("jsonrpc", .str "2.0"),
              ("method", .str "notify"),
              ("params", .obj #[
                ("event", .str event),
                ("data", params)
              ])
            ]
            try
              discard <| LeanKohaku.Daemon.Uds.write conn (compact frame ++ "\n").toByteArray
            catch _ => pure ()
        let response ←
          match parsed with
          | .error err => pure (compact <| errorResponse .null err)
          | .ok req => do
              -- Idle-TTL refresh: any well-formed RPC counts as user
              -- activity, so the master KEK + per-slot unlocks behave
              -- as an idle timeout (lock after `ttlMs` of true
              -- silence) rather than an absolute timeout from
              -- unlock. See `State.touchActivity` for rationale.
              LeanKohaku.Daemon.State.touchActivity state
              let json ← LeanKohaku.RPC.Server.dispatch (methodHandler cfg state notify) req
              pure (compact json)
        discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
        LeanKohaku.Daemon.Log.write .info method ((← IO.monoMsNow) - started) true

/-- Handle one wallet-daemon connection.

    The dispatch path is wrapped in a `try/catch` that always
    delivers a JSON-RPC error frame even when a handler raises an
    IO error past its own catch (FFI panic, untranslated `throw`,
    etc.). Without this arm the peer would observe a closed socket
    and surface the failure on the client as `unexpected end of
    JSON input` rather than a structured `-32603` envelope. -/
def handleConn (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (conn : LeanKohaku.Daemon.Uds.Conn) : IO Unit := do
  let recover (e : IO.Error) : IO Unit := do
    IO.eprintln s!"[daemon] handleConn raised, returning -32603: {toString e}"
    try
      let response := compact <| errorResponse .null
        { code := -32603, message := s!"internal error: {toString e}" }
      discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
    catch _ => pure ()
  let body : IO Unit := do
    try
      handleConnBody cfg state conn
    catch e =>
      recover e
  try
    body
  finally
    LeanKohaku.Daemon.Uds.close conn

partial def acceptLoop (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (listener : LeanKohaku.Daemon.Uds.Listener) : IO Unit := do
  let conn ← LeanKohaku.Daemon.Uds.accept listener
  discard <| IO.asTask (handleConn cfg state conn)
  if !(← LeanKohaku.Daemon.State.isShuttingDown state) then
    acceptLoop cfg state listener

/-- Probe the configured socket to detect whether another daemon is already
    listening on it.

    Returns:
    * `some "already running"` — connect succeeded and a `daemon.ping` round-trip
      either completed within the timeout, or the read window elapsed without
      the peer hanging up. Either way, *something* owns the socket and is
      accepting connections, so we must not start a second instance.
    * `none` — no live daemon (no socket file, or stale socket file removed).

    The probe is bounded to ~250 ms so a half-dead peer cannot stall startup.
    Stale socket files (connect fails with ENOENT or ECONNREFUSED but the path
    still exists / does not exist) are handled by inspecting `pathExists` after
    a connect failure: if the path exists, the file is stale and we remove it. -/

def run (cfg : Config) : IO Unit := do
  let ownsSocket := !(← socketActivated)
  -- Single-instance guard: if we are NOT socket-activated and another daemon
  -- already owns the configured socket, refuse to start a second instance
  -- rather than splitting auto-spawn / network-log state across processes.
  -- Socket activation is skipped because systemd guarantees uniqueness on its
  -- side and there is no path to probe (the fd comes via LISTEN_FDS).
  if !(← socketActivated) then
    match ← detectExistingDaemon cfg.socketPath with
    | some _ =>
        IO.eprintln s!"leankohaku-daemon: another instance is already listening on {cfg.socketPath} (pid unknown); refusing to start a second instance"
        IO.Process.exit 0
    | none => pure ()
  -- Boot-time precheck for native crypto helpers. Without these, every
  -- wallet op fails mid-flow with a generic `could not execute external
  -- process` error — far less actionable than refusing to start. Exits
  -- 70 (EX_SOFTWARE) on miss so callers can disambiguate from the
  -- code-0 second-instance exit above.
  verifyNativeHelpersOrExit
  let listener ←
    match ← listenerFromSocketActivation? with
    | some listener => pure listener
    | none =>
        ensureParentDir cfg.socketPath
        LeanKohaku.Daemon.Uds.bind cfg.socketPath
  let state ← LeanKohaku.Daemon.State.new
  IO.eprintln s!"leankohaku-daemon: listening on {cfg.socketPath}"
  -- Default-on Colibri stateless verification. Spawning the sidecar is
  -- cheap (no committee bootstrap until the first proofable read), so
  -- enabling at startup costs us almost nothing and means proofable
  -- reads are verified out-of-the-box. Opt out with `KOHAKU_COLIBRI=0`.
  -- Failure is non-fatal: the daemon keeps serving and reads transparently
  -- fall through to the configured HTTP RPC.
  let colibriDisabled :=
    match ← IO.getEnv "KOHAKU_COLIBRI" with
    | some "0" | some "off" | some "false" | some "no" => true
    | _ => false
  unless colibriDisabled do
    let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
      | some d => pure d
      | none =>
          match ← IO.getEnv "TMPDIR" with
          | some d => pure d
          | none => pure "/tmp"
    let colibriSocket := s!"{runtimeRoot}/leankohaku/colibri.sock"
    try
      let _ ← LeanKohaku.Daemon.State.colibriEnable state colibriSocket
      IO.eprintln s!"leankohaku-daemon: colibri verified-reads enabled (socket={colibriSocket})"
    catch e =>
      IO.eprintln s!"leankohaku-daemon: colibri auto-enable failed ({e}); reads will use the configured RPC"
  -- Default-on Helios sidecar (helios is now the default `readBackend`,
  -- so the persistent client should be running for it to be useful — a
  -- cold one-shot spawn pays ~10s consensus sync per simulate). Spawning
  -- itself is cheap; the sync defers until the first proofable request.
  -- Opt out with `KOHAKU_HELIOS=0`. Failure is non-fatal: the daemon
  -- keeps serving and per-call `tx.simulateHelios` falls back to a fresh
  -- one-shot spawn (slower but functional).
  let heliosEnabled :=
    match ← IO.getEnv "KOHAKU_HELIOS" with
    | some "0" | some "off" | some "false" | some "no" => false
    | _ => true
  -- Honor `KOHAKU_READ_BACKEND` for the initial default backend. Same
  -- naming as the `daemon.readBackend.set { backend }` RPC. Unrecognized
  -- values fall through to the structure default (.helios) with a warning.
  match ← IO.getEnv "KOHAKU_READ_BACKEND" with
  | some raw =>
      match LeanKohaku.Daemon.State.ReadBackend.parse? raw with
      | some b =>
          LeanKohaku.Daemon.State.setReadBackend state b
          IO.eprintln s!"leankohaku-daemon: read backend default = {b.asString} (from KOHAKU_READ_BACKEND)"
      | none =>
          IO.eprintln s!"leankohaku-daemon: KOHAKU_READ_BACKEND={raw} unrecognized; using default helios"
  | none => pure ()
  if heliosEnabled then
    let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
      | some d => pure d
      | none =>
          match ← IO.getEnv "TMPDIR" with
          | some d => pure d
          | none => pure "/tmp"
    let heliosSocket := s!"{runtimeRoot}/leankohaku/helios.sock"
    try
      let _ ← LeanKohaku.Daemon.State.heliosEnable state heliosSocket
      IO.eprintln s!"leankohaku-daemon: helios enabled (socket={heliosSocket})"
    catch e =>
      IO.eprintln s!"leankohaku-daemon: helios auto-enable failed ({e}); use daemon.helios.toggle to retry"
  -- Opt-in safenode (TDX-attested ORAM proxy). Only spawned when the
  -- operator opts in via `KOHAKU_SAFE_NODE_URL`; failure to attest is
  -- non-fatal — the daemon keeps serving with helios reading directly
  -- from the configured `rpcEndpoint`. When safenode IS attested, helios
  -- transparently routes through it (see `Endpoints.heliosEndpointFor`).
  match ← IO.getEnv "KOHAKU_SAFE_NODE_URL" with
  | none => pure ()
  | some _ =>
      let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
        | some d => pure d
        | none =>
            match ← IO.getEnv "TMPDIR" with
            | some d => pure d
            | none => pure "/tmp"
      let safeNodeSocket := s!"{runtimeRoot}/leankohaku/safenode.sock"
      try
        let _ ← LeanKohaku.Daemon.State.safeNodeEnable state safeNodeSocket
        IO.eprintln s!"leankohaku-daemon: safenode attested + enabled (socket={safeNodeSocket})"
      catch e =>
        IO.eprintln s!"leankohaku-daemon: safenode auto-enable failed ({e}); helios reads will use the configured RPC. Use daemon.safeNode.toggle to retry."
  try
    acceptLoop cfg state listener
  finally
    -- Tear down persistent sidecars before releasing the listener so we
    -- don't leak the colibri.sock / helios.sock / safenode.sock files
    -- (and the Node children) on shutdown.
    LeanKohaku.Daemon.State.colibriDisable state
    LeanKohaku.Daemon.State.heliosDisable state
    LeanKohaku.Daemon.State.safeNodeDisable state
    LeanKohaku.Daemon.Uds.closeListener listener
    if ownsSocket then
      removeSocketFile cfg.socketPath

end LeanKohaku.Daemon.Server
