import LeanCli.Basic
import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.Server.Journal
import LeanCli.Daemon.Server.BookRpc
import LeanCli.Daemon.Server.SwapRpc
import LeanCli.Daemon.Server.MiscRpc
import LeanCli.Daemon.Server.AccountRpc
import LeanCli.Daemon.Server.ChatRpc
import LeanCli.Daemon.Server.TxRpc
import LeanCli.Daemon.Server.WalletRpc
import LeanCli.Daemon.Server.SphincsRpc
import LeanCli.Daemon.Server.ChainRpc
import LeanCli.Daemon.Server.ShieldedRpc
import LeanCli.Daemon.Server.EoaRpc
import LeanCli.Daemon.Server.DaemonRpc
import LeanCli.Daemon.AddressBook
import LeanCli.Daemon.LlmServer
import LeanCli.Daemon.Log
import LeanCli.Daemon.SkillsStore
import LeanCli.Daemon.State
import LeanCli.Daemon.Status
import LeanCli.Daemon.PpDestinations
import LeanCli.Daemon.TxJournal
import LeanCli.Daemon.Uds
import LeanCli.Network.Policy
import LeanCli.Privacy.Bridge
import LeanCli.Clearsign.Bridge
import LeanCli.Sphincs.Bridge
import LeanCli.Sphincs.UserOp
import LeanCli.Sphincs.Send
import LeanCli.Colibri.Bridge
import LeanCli.Colibri.Persistent
import LeanCli.Helios.Bridge
import LeanCli.Helios.Persistent
import LeanCli.Daemon.Preflight
import LeanCli.Daemon.TokenMeta
import LeanCli.Daemon.EnsNames
import LeanCli.LlmAgent.Bridge
import LeanCli.LlmAgent.DirectSynth
import LeanCli.LlmAgent.IntentParser
import LeanCli.LlmAgent.RuleParser
import LeanCli.Cli.Commands
import LeanCli.Cli.NetworkConfig
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Eip712
import LeanCli.Ethereum.Ens
import LeanCli.Ethereum.Intent
import LeanCli.Ethereum.IntentCanonical
import LeanCli.Ethereum.IntentEncode
import LeanCli.Ethereum.IntentJson
import LeanCli.Ethereum.Ownership
import LeanCli.Ethereum.Tx
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.Keystore.MasterKey
import LeanCli.Keystore.MasterPassphrase
import LeanCli.Wallet.Address
import LeanCli.Wallet.Bip44
import LeanCli.Wallet.EoaStore
import LeanCli.Wallet.Entropy
import LeanCli.Wallet.EOA
import LeanCli.Wallet.HDKey
import LeanCli.Wallet.Mnemonic
import LeanCli.Wallet.PpSecretStore
import LeanCli.Wallet.RgSecretStore
import LeanCli.Wallet.SphincsHybridStore
import LeanCli.Registry.KnownProtocols
import LeanCli.Swap.Tokens
import LeanCli.Swap.UniV3
import LeanCli.Swap.Prepare
import LeanCli.Aave.Prepare
import LeanCli.Util.Units
import LeanCli.Invariants.Swap

/-!
# Daemon server

Long-running process that exposes wallet operations over a local socket.
The daemon is the only component allowed to perform Ethereum node I/O, and
every attempted connection must pass `Network.Policy`.
-/

namespace LeanCli.Daemon.Server

open LeanCli.Encoding.Json
open LeanCli.Keystore.Tpm2Runtime
open LeanCli.Wallet.Account
open LeanCli.Network.Policy
open LeanCli.RPC.Server

-- Why: no `defaultConfig` with a URL substitute. The daemon must refuse to
-- start without a user-configured `rpc_url` (env or daemon.json); see
-- `LeanCli.Daemon.Config.resolve`. Avoids any silent loopback dial.



/-- JSON-RPC error code returned when a shielded handler that requires the
    Privacy-Pools spending secret is invoked but no encrypted secret is
    stored on disk. The CLI surfaces this as a friendly hint. -/
def methodHandler (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  -- Phase-4 onwards: per-family dispatch modules under
  -- `Server/<Family>Rpc.lean`. Prefix-route here, then fall through
  -- to the in-file match for families still pending extraction.
  if req.method.startsWith "book." then
    return ← BookRpc.dispatch cfg state notify req
  if req.method.startsWith "swap." then
    return ← SwapRpc.dispatch cfg state notify req
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
private def handleConnBody (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (conn : LeanCli.Daemon.Uds.Conn) : IO Unit := do
  let started ← IO.monoMsNow
  let sameUid ← LeanCli.Daemon.Uds.peerUidMatchesCurrent conn
  if !sameUid then
    let response := compact <| errorResponse .null
      { code := -32001, message := "peer uid rejected" }
    discard <| LeanCli.Daemon.Uds.write conn (response ++ "\n").toByteArray
    LeanCli.Daemon.Log.write .warn "<peer>" ((← IO.monoMsNow) - started) false
      (some "peer uid rejected")
  else
    -- `readLine` buffers across SOCK_STREAM `read(2)` chunks until
    -- the terminating `\n`, so a request the kernel splits doesn't
    -- truncate into a parse error here.
    let bytes ← LeanCli.Daemon.Uds.readLine conn
    match decodeRequestBytes bytes with
    | .error err =>
        let response := compact <| errorResponse .null
          { parseError with data := some (.str err) }
        discard <| LeanCli.Daemon.Uds.write conn (response ++ "\n").toByteArray
        LeanCli.Daemon.Log.write .warn "<parse>" ((← IO.monoMsNow) - started) false
          (some err)
    | .ok line =>
        let parsed := LeanCli.RPC.Server.parseRequest line
        let method :=
          match parsed with
          | .ok req => req.method
          | .error _ => "<parse>"
        -- UDS-backed notifier: emit JSON-RPC notification frames
        -- (no `id`, no `result`/`error`) on the same connection
        -- before the final response. The CLI client buffers and
        -- splits on `\n`, rendering each notification before
        -- returning the response.
        let notify : LeanCli.Keystore.Tpm2Runtime.Notifier :=
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
              discard <| LeanCli.Daemon.Uds.write conn (compact frame ++ "\n").toByteArray
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
              LeanCli.Daemon.State.touchActivity state
              let json ← LeanCli.RPC.Server.dispatch (methodHandler cfg state notify) req
              pure (compact json)
        discard <| LeanCli.Daemon.Uds.write conn (response ++ "\n").toByteArray
        LeanCli.Daemon.Log.write .info method ((← IO.monoMsNow) - started) true

/-- Handle one wallet-daemon connection.

    The dispatch path is wrapped in a `try/catch` that always
    delivers a JSON-RPC error frame even when a handler raises an
    IO error past its own catch (FFI panic, untranslated `throw`,
    etc.). Without this arm the peer would observe a closed socket
    and surface the failure on the client as `unexpected end of
    JSON input` rather than a structured `-32603` envelope. -/
def handleConn (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (conn : LeanCli.Daemon.Uds.Conn) : IO Unit := do
  let recover (e : IO.Error) : IO Unit := do
    IO.eprintln s!"[daemon] handleConn raised, returning -32603: {toString e}"
    try
      let response := compact <| errorResponse .null
        { code := -32603, message := s!"internal error: {toString e}" }
      discard <| LeanCli.Daemon.Uds.write conn (response ++ "\n").toByteArray
    catch _ => pure ()
  let body : IO Unit := do
    try
      handleConnBody cfg state conn
    catch e =>
      recover e
  try
    body
  finally
    LeanCli.Daemon.Uds.close conn

partial def acceptLoop (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (listener : LeanCli.Daemon.Uds.Listener) : IO Unit := do
  let conn ← LeanCli.Daemon.Uds.accept listener
  discard <| IO.asTask (handleConn cfg state conn)
  if !(← LeanCli.Daemon.State.isShuttingDown state) then
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
        IO.eprintln s!"leancli-daemon: another instance is already listening on {cfg.socketPath} (pid unknown); refusing to start a second instance"
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
        LeanCli.Daemon.Uds.bind cfg.socketPath
  let state ← LeanCli.Daemon.State.new
  IO.eprintln s!"leancli-daemon: listening on {cfg.socketPath}"
  -- Default-on Colibri stateless verification. Spawning the sidecar is
  -- cheap (no committee bootstrap until the first proofable read), so
  -- enabling at startup costs us almost nothing and means proofable
  -- reads are verified out-of-the-box. Opt out with `LEANCLI_COLIBRI=0`.
  -- Failure is non-fatal: the daemon keeps serving and reads transparently
  -- fall through to the configured HTTP RPC.
  let colibriDisabled :=
    match ← IO.getEnv "LEANCLI_COLIBRI" with
    | some "0" | some "off" | some "false" | some "no" => true
    | _ => false
  unless colibriDisabled do
    let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
      | some d => pure d
      | none =>
          match ← IO.getEnv "TMPDIR" with
          | some d => pure d
          | none => pure "/tmp"
    let colibriSocket := s!"{runtimeRoot}/leancli/colibri.sock"
    try
      let _ ← LeanCli.Daemon.State.colibriEnable state colibriSocket
      IO.eprintln s!"leancli-daemon: colibri verified-reads enabled (socket={colibriSocket})"
    catch e =>
      IO.eprintln s!"leancli-daemon: colibri auto-enable failed ({e}); reads will use the configured RPC"
  -- Default-on Helios sidecar (helios is now the default `readBackend`,
  -- so the persistent client should be running for it to be useful — a
  -- cold one-shot spawn pays ~10s consensus sync per simulate). Spawning
  -- itself is cheap; the sync defers until the first proofable request.
  -- Opt out with `LEANCLI_HELIOS=0`. Failure is non-fatal: the daemon
  -- keeps serving and per-call `tx.simulateHelios` falls back to a fresh
  -- one-shot spawn (slower but functional).
  let heliosEnabled :=
    match ← IO.getEnv "LEANCLI_HELIOS" with
    | some "0" | some "off" | some "false" | some "no" => false
    | _ => true
  -- Honor `LEANCLI_READ_BACKEND` for the initial default backend. Same
  -- naming as the `daemon.readBackend.set { backend }` RPC. Unrecognized
  -- values fall through to the structure default (.helios) with a warning.
  match ← IO.getEnv "LEANCLI_READ_BACKEND" with
  | some raw =>
      match LeanCli.Daemon.State.ReadBackend.parse? raw with
      | some b =>
          LeanCli.Daemon.State.setReadBackend state b
          IO.eprintln s!"leancli-daemon: read backend default = {b.asString} (from LEANCLI_READ_BACKEND)"
      | none =>
          IO.eprintln s!"leancli-daemon: LEANCLI_READ_BACKEND={raw} unrecognized; using default helios"
  | none => pure ()
  if heliosEnabled then
    let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
      | some d => pure d
      | none =>
          match ← IO.getEnv "TMPDIR" with
          | some d => pure d
          | none => pure "/tmp"
    let heliosSocket := s!"{runtimeRoot}/leancli/helios.sock"
    try
      let _ ← LeanCli.Daemon.State.heliosEnable state heliosSocket
      IO.eprintln s!"leancli-daemon: helios enabled (socket={heliosSocket})"
    catch e =>
      IO.eprintln s!"leancli-daemon: helios auto-enable failed ({e}); use daemon.helios.toggle to retry"
  -- Opt-in safenode (TDX-attested ORAM proxy). Only spawned when the
  -- operator opts in via `LEANCLI_SAFE_NODE_URL`; failure to attest is
  -- non-fatal — the daemon keeps serving with helios reading directly
  -- from the configured `rpcEndpoint`. When safenode IS attested, helios
  -- transparently routes through it (see `Endpoints.applySafeNodeOverride`).
  match ← IO.getEnv "LEANCLI_SAFE_NODE_URL" with
  | none => pure ()
  | some _ =>
      let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
        | some d => pure d
        | none =>
            match ← IO.getEnv "TMPDIR" with
            | some d => pure d
            | none => pure "/tmp"
      let safeNodeSocket := s!"{runtimeRoot}/leancli/safenode.sock"
      -- Default the sidecar's non-private fallback to the daemon's
      -- configured Sepolia endpoint, so non-getProof reads use the same
      -- RPC the rest of the daemon uses (keyed Ankr, etc.). Operator can
      -- still force a different fallback by setting
      -- `LEANCLI_SAFE_NODE_FALLBACK_RPC` themselves before launching the
      -- daemon — we only set it on the child when the env var is unset.
      -- Falls back to `cfg.rpcEndpoint` when no per-chain entry is
      -- configured. The override is passed through `safeNodeEnable` →
      -- `Persistent.start` → `IO.Process.spawn.env`, so the daemon's own
      -- env is untouched.
      let safeNodeExtraEnv : Array (String × String) ←
        match ← IO.getEnv "LEANCLI_SAFE_NODE_FALLBACK_RPC" with
        | some _ => pure #[]  -- operator override wins
        | none =>
            let fallbackUrl :=
              match endpointForChain cfg (some "sepolia") with
              | .ok ep => ep.url
              | .error _ => cfg.rpcEndpoint.url
            IO.eprintln s!"leancli-daemon: safenode fallback RPC = {fallbackUrl} (configured sepolia endpoint)"
            pure #[("LEANCLI_SAFE_NODE_FALLBACK_RPC", fallbackUrl)]
      try
        let _ ← LeanCli.Daemon.State.safeNodeEnable state safeNodeSocket safeNodeExtraEnv
        IO.eprintln s!"leancli-daemon: safenode attested + enabled (socket={safeNodeSocket})"
      catch e =>
        IO.eprintln s!"leancli-daemon: safenode auto-enable failed ({e}); helios reads will use the configured RPC. Use daemon.safeNode.toggle to retry."
  try
    acceptLoop cfg state listener
  finally
    -- Tear down persistent sidecars before releasing the listener so we
    -- don't leak the colibri.sock / helios.sock / safenode.sock files
    -- (and the Node children) on shutdown.
    LeanCli.Daemon.State.colibriDisable state
    LeanCli.Daemon.State.heliosDisable state
    LeanCli.Daemon.State.safeNodeDisable state
    LeanCli.Daemon.Uds.closeListener listener
    if ownsSocket then
      removeSocketFile cfg.socketPath

end LeanCli.Daemon.Server
