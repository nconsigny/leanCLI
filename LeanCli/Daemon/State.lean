import Std.Sync.Mutex
import LeanCli.Colibri.Persistent
import LeanCli.Helios.Persistent
import LeanCli.SafeNode.Persistent
import LeanCli.RPC.Outbound

/-!
# Daemon state

Small shared state for the daemon. Unlocked EOA seeds live only here.
-/

namespace LeanCli.Daemon.State

/-- An unlocked EOA slot in memory.

`unlockedAtMs` is interpreted as a *last-activity* timestamp, not a
fixed unlock timestamp: the RPC dispatcher refreshes it via
`touchActivity` on every incoming request, so `ttlMs` behaves as an
idle timeout. With the default `ttlMs = 300000` (5 min), a slot stays
unlocked for as long as the user keeps interacting with the daemon
(including the TUI's screen-mount RPCs); after 5 min of true silence,
the next access purges it via `slotAlive`. -/
structure UnlockedSlot where
  name           : String
  seed           : ByteArray
  address        : String
  derivationPath : String
  unlockedAtMs   : Nat
  ttlMs          : Nat

/-- The wallet-level master KEK, when currently loaded.

The KEK never persists in clear text on disk; it lives only here while
loaded. Same TTL semantics as `UnlockedSlot`: `unlockedAtMs` is bumped
to "now" by `touchActivity` on each RPC, so `ttlMs` is an idle timeout
rather than a fixed lifetime. Purged on every access once expired.
Cleared explicitly by `lockMaster` / `wallet.lock`. -/
structure MasterKekSlot where
  kek          : ByteArray
  unlockedAtMs : Nat
  ttlMs        : Nat

/-- Which backend the daemon defaults to for reads / simulations.
Mirrors the upstream `ethereum/kohaku` provider-package design where the
caller picks between `helios(...)` and `colibri(...)`; we expose it as a
daemon-wide toggle so the CLI/TUI/agent can flip backends once and have
every subsequent `tx.simulate` honour it without restating the choice.

- `rpc`     direct execution-RPC `eth_call` / `eth_estimateGas`. The
            historical default; broadest compatibility (multicall etc.).
- `colibri` Stateless light-client backend (`@corpus-core/colibri-stateless`).
            Consensus-verified state via committee-signed proofs; can
            mis-render some router/multicall calls as reverts (which is
            why `tx.simulate` originally pinned to `rpc`).
- `helios`  `@a16z/helios` + embedded REVM. Consensus-verified state via
            sync-committee proofs; opt-in here since helios depends on a
            beacon RPC plumbed in `sidecars/kohaku/helios/`. -/
inductive ReadBackend
  | rpc
  | colibri
  | helios
  deriving Repr, DecidableEq, Inhabited

def ReadBackend.asString : ReadBackend → String
  | .rpc => "rpc"
  | .colibri => "colibri"
  | .helios => "helios"

def ReadBackend.parse? (s : String) : Option ReadBackend :=
  match s.toLower with
  | "rpc" | "direct" | "raw" => some .rpc
  | "colibri" => some .colibri
  | "helios" => some .helios
  | _ => none

/-- Cached ERC-20 metadata. The actual struct lives in
`LeanCli.Daemon.TokenMeta`; we store `(decimals, symbol)` raw to avoid
a circular import. -/
abbrev TokenMetaEntry := Nat × String

structure DaemonState where
  startedAtMs : Nat
  shuttingDown : Bool := false
  unlocked : List UnlockedSlot := []
  /--
  Cooperative cancellation flag for long-running `chain.scanTransfers`.
  Set to `true` by the `chain.cancel` RPC; the scan handler checks this
  between chunks and aborts at the next safe point.
  -/
  scanCancelled : Bool := false
  /-- ERC-20 metadata cache keyed by `"chainId:address"` (lowercased
  address). Populated on demand by `tx.decodeIntent`. -/
  tokenMeta : List (String × TokenMetaEntry) := []
  /-- Long-running Colibri stateless client. `none` when colibri is
  disabled (the default). Toggled at runtime via `daemon.colibri.toggle`;
  spawning pays the sync-committee bootstrap once per chainId per
  lifetime, which is why we keep it persistent rather than spawning
  per-call. -/
  colibri : Option LeanCli.Colibri.Persistent.Client := none
  /-- Socket path used to spawn `colibri`. Cached so `colibriRespawn` can
  bring the sidecar back without re-deriving the path (which lives in
  `Daemon.Config` and is otherwise not reachable from here). Cleared
  alongside `colibri` on `colibriDisable`. -/
  colibriSocket : Option String := none
  /-- Long-running Helios light-client sidecar. `none` when helios is
  disabled (the default). Helios is an opt-in second backend that
  exposes the same `eth.proxy` / `tx.simulate` shape as Colibri but
  executes locally via REVM against sync-committee-verified state.
  Spawning is cheap; the first call pays the consensus sync. -/
  helios : Option LeanCli.Helios.Persistent.Client := none
  /-- Socket path used to spawn `helios`. Cached for future
  `heliosRespawn` parity with Colibri; not yet exercised because the
  initial helios surface does not auto-substitute into verified reads. -/
  heliosSocket : Option String := none
  /-- Long-running safenode sidecar (TDX-attested ORAM proxy). `none`
  when safenode is off (the default — only spawned when
  `LEANCLI_SAFE_NODE_URL` is set in the env). When present, helios
  call sites substitute the sidecar's local HTTP proxy URL for
  `executionRpc`, so every `eth_getProof` lookup tunnels through the
  TDX-pinned channel and is fetched obliviously. -/
  safeNode : Option LeanCli.SafeNode.Persistent.Client := none
  /-- Socket path used to spawn `safeNode`. Cached so a respawn after
  a transport-level death has it available. -/
  safeNodeSocket : Option String := none
  /-- Daemon-wide default backend for `tx.simulate` and future unified
  read RPCs. Initial value is `LEANCLI_READ_BACKEND` from the env (or
  `.helios` when unset — helios is the default because it's the most
  trust-minimised path we ship: consensus-verified state + REVM
  execution); flipped at runtime via `daemon.readBackend.set`;
  overridden per-call via `params.backend`. -/
  readBackend : ReadBackend := .helios
  /-- Wallet-level master KEK, when currently loaded. `none` means the
  wallet is locked at the master level — slot unlocks must come through
  the per-slot `eoa.unlock` path. Populated by `wallet.unlock`. -/
  masterKek : Option MasterKekSlot := none
  /-- Runtime override of the daemon's active/default chain, set via the
  `network.use` RPC. `none` ⇒ fall back to the start-up `cfg.chainId`.
  Applied at the dispatch boundary (`Server.methodHandler`) through
  `Config.withChain`, so one switch re-targets every handler — chat
  default, balance reads, `tx.simulate`, `network.show` — with no daemon
  restart. Per-call `chain:` params still win; this only moves the
  default. Read/endpoint plumbing only — no signing impact. -/
  activeChainId : Option Nat := none
  /-- Serializes access to the single-connection verified-read clients
  (helios / colibri `Persistent.call`). The daemon answers TUI polls
  CONCURRENTLY, but each light client holds ONE UDS connection — without
  this lock, concurrent verified reads interleave writes/reads on that one
  conn and corrupt the wire (observed as rpc-errors + 60s hangs on the
  balance poll). Held only around the client round-trip in
  `buildHeliosVia` / `buildColibriVia`, so verified reads queue safely
  instead of colliding. -/
  verifyLock : Std.BaseMutex

abbrev Shared := IO.Ref DaemonState

def new : IO Shared := do
  let verifyLock ← Std.BaseMutex.new
  IO.mkRef { startedAtMs := ← IO.monoMsNow, verifyLock }

/-- Reset the scan-cancellation flag at the start of a new scan. -/
def beginScan (state : Shared) : IO Unit := do
  state.modify (fun s => { s with scanCancelled := false })

/-- Idempotent: request cancellation of any in-flight `chain.scanTransfers`. -/
def cancelScan (state : Shared) : IO Unit := do
  state.modify (fun s => { s with scanCancelled := true })

def isScanCancelled (state : Shared) : IO Bool := do
  return (← state.get).scanCancelled

def requestShutdown (state : Shared) : IO Unit := do
  state.modify (fun s => { s with shuttingDown := true })

def isShuttingDown (state : Shared) : IO Bool := do
  return (← state.get).shuttingDown

private def slotAlive (nowMs : Nat) (slot : UnlockedSlot) : Bool :=
  slot.ttlMs == 0 || nowMs <= slot.unlockedAtMs + slot.ttlMs

def purgeExpired (state : Shared) : IO Unit := do
  let nowMs ← IO.monoMsNow
  state.modify fun s =>
    { s with unlocked := s.unlocked.filter (slotAlive nowMs) }

def isUnlocked (state : Shared) (name : String) : IO Bool := do
  purgeExpired state
  pure ((← state.get).unlocked.any (fun slot => slot.name == name))

def unlockedNames (state : Shared) : IO (List String) := do
  purgeExpired state
  pure ((← state.get).unlocked.map (fun slot => slot.name))

def unlock (state : Shared) (slot : UnlockedSlot) : IO Unit := do
  state.modify fun s =>
    { s with unlocked := slot :: s.unlocked.filter (fun old => old.name != slot.name) }

def lock (state : Shared) (name : String) : IO Unit := do
  state.modify fun s =>
    { s with unlocked := s.unlocked.filter (fun slot => slot.name != name) }

def getUnlocked? (state : Shared) (name : String) : IO (Option UnlockedSlot) := do
  purgeExpired state
  pure ((← state.get).unlocked.find? (fun slot => slot.name == name))

/-! ## Master-KEK helpers

  Symmetrical to `unlock` / `lock` / `getUnlocked?` for the wallet-level
  master KEK. TTL handling mirrors per-slot semantics: a slot with
  `ttlMs == 0` is permanent until `lockMaster`. Expiry is checked
  defensively on each read so a forgotten timer cannot leave a stale KEK
  in memory.
-/

private def masterAlive (nowMs : Nat) (slot : MasterKekSlot) : Bool :=
  slot.ttlMs == 0 || nowMs <= slot.unlockedAtMs + slot.ttlMs

def purgeMasterIfExpired (state : Shared) : IO Unit := do
  let nowMs ← IO.monoMsNow
  state.modify fun s =>
    { s with masterKek := s.masterKek.filter (masterAlive nowMs) }

def getMasterKek? (state : Shared) : IO (Option MasterKekSlot) := do
  purgeMasterIfExpired state
  pure (← state.get).masterKek

/-- Idempotent installation of a fresh master-KEK slot. Replaces any
    existing entry (e.g. on re-unlock after TTL expiry). -/
def unlockMaster (state : Shared) (slot : MasterKekSlot) : IO Unit := do
  state.modify fun s => { s with masterKek := some slot }

/-- Idempotent: clear the in-memory master KEK. Does NOT lock per-slot
    unlocks; callers that want "everything locked" iterate the unlocked
    list and call `lock` per slot. -/
def lockMaster (state : Shared) : IO Unit := do
  state.modify fun s => { s with masterKek := none }

/-- Lock every per-slot unlock AND the master KEK in one shot. -/
def lockAll (state : Shared) : IO Unit := do
  state.modify fun s => { s with unlocked := [], masterKek := none }

/-- Refresh the idle-TTL clock on the master KEK and every unlocked slot.

The RPC dispatcher (`handleConn` in `Daemon.Server`) calls this once per
incoming request, BEFORE dispatching the method handler. Effect: any
daemon traffic (`wallet.master.status`, `chain.balance`, an
`eoa.send` …) counts as activity and resets the lock countdown. With
the default `ttlMs = 300000`, the master + slots stay live as long as
the user keeps interacting; after 5 minutes of true silence the next
read purges them through `slotAlive` / `masterAlive`.

Cheap no-op when nothing is unlocked — the list/option `.map`s reduce
to identity and the single `state.modify` is an atomic ref write. -/
def touchActivity (state : Shared) : IO Unit := do
  let nowMs ← IO.monoMsNow
  state.modify fun s =>
    { s with
        masterKek := s.masterKek.map (fun slot => { slot with unlockedAtMs := nowMs }),
        unlocked := s.unlocked.map (fun slot => { slot with unlockedAtMs := nowMs }) }

/-- Spawn the persistent Colibri client and store it in shared state.
    Idempotent: if a client is already running, returns it. Throws on
    spawn / connect failure (caller decides whether to surface or fall
    back). The caller supplies the socket path because this module sits
    below `Daemon.Config` in the import order. -/
def colibriEnable (state : Shared) (socketPath : String) : IO LeanCli.Colibri.Persistent.Client := do
  let s ← state.get
  match s.colibri with
  | some c => pure c
  | none =>
      let c ← LeanCli.Colibri.Persistent.start socketPath
      state.modify (fun s => { s with colibri := some c, colibriSocket := some socketPath })
      pure c

/-- Tear down the persistent Colibri client. Idempotent. -/
def colibriDisable (state : Shared) : IO Unit := do
  let s ← state.get
  match s.colibri with
  | none => pure ()
  | some c =>
      try LeanCli.Colibri.Persistent.close c catch _ => pure ()
      state.modify (fun s => { s with colibri := none, colibriSocket := none })

/-- Best-effort respawn after a transport-level death of the persistent
    Colibri client (broken pipe / sidecar exit). Closes the dead client
    (ignoring secondary errors), spawns a fresh one on the same socket
    path, and atomically swaps it into shared state. Returns the new
    client on success, `none` if no socket path was previously recorded
    or the spawn failed.

    Single-call recovery scope: this is invoked by the closure built in
    `Server.lean`'s `colibriVia`, and only on the call that observed the
    crash. Because the daemon serializes through one persistent
    connection per `DaemonState`, two concurrent requests cannot both
    enter this path before the swap settles (the first will already have
    replaced the dead client by the time the second reads `state.colibri`
    in `colibriVia`). The single-actor recovery property documented in
    `Persistent.call` therefore still holds without an explicit lock. -/
def colibriRespawn (state : Shared) : IO (Option LeanCli.Colibri.Persistent.Client) := do
  let s ← state.get
  match s.colibriSocket with
  | none => pure none
  | some socketPath =>
      -- Close the dead client first so the spawned sidecar can claim the
      -- socket path cleanly. Errors here are expected (the conn is
      -- already broken) and intentionally swallowed.
      match s.colibri with
      | some c => try LeanCli.Colibri.Persistent.close c catch _ => pure ()
      | none => pure ()
      try
        let c ← LeanCli.Colibri.Persistent.start socketPath
        state.modify (fun s => { s with colibri := some c })
        pure (some c)
      catch _ =>
        -- Spawn failed: leave `colibri := none` so subsequent
        -- `colibriClient?` reads see verified-reads as off. Keep the
        -- socket path on state so an operator-triggered respawn (via
        -- `daemon.colibri.toggle`) still has it.
        state.modify (fun s => { s with colibri := none })
        pure none

/-- Read the current Colibri client without spawning. -/
def colibriClient? (state : Shared) : IO (Option LeanCli.Colibri.Persistent.Client) := do
  pure (← state.get).colibri

/-- Spawn the persistent Helios client and store it in shared state.
    Idempotent: if a client is already running, returns it. Throws on
    spawn / connect failure (caller decides whether to surface or fall
    back). Symmetric with `colibriEnable`. -/
def heliosEnable (state : Shared) (socketPath : String) : IO LeanCli.Helios.Persistent.Client := do
  let s ← state.get
  match s.helios with
  | some c => pure c
  | none =>
      let c ← LeanCli.Helios.Persistent.start socketPath
      state.modify (fun s => { s with helios := some c, heliosSocket := some socketPath })
      pure c

/-- Tear down the persistent Helios client. Idempotent. -/
def heliosDisable (state : Shared) : IO Unit := do
  let s ← state.get
  match s.helios with
  | none => pure ()
  | some c =>
      try LeanCli.Helios.Persistent.close c catch _ => pure ()
      state.modify (fun s => { s with helios := none, heliosSocket := none })

/-- Read the current Helios client without spawning. -/
def heliosClient? (state : Shared) : IO (Option LeanCli.Helios.Persistent.Client) := do
  pure (← state.get).helios

/-- Spawn the persistent safenode sidecar and store it in shared state.
    Idempotent: if a client is already running, returns it. Throws on
    spawn / connect failure (caller decides whether to surface or fall
    back). Symmetric with `heliosEnable`. The sidecar runs the full TDX
    verify flow before binding its sockets, so this call blocks for a
    few seconds on first spawn; subsequent enables are fast (the
    sidecar caches its attested pin).

    `extraEnv` is overlaid on the spawned child's environment — used by
    the daemon to default `LEANCLI_SAFE_NODE_FALLBACK_RPC` to its own
    configured Sepolia endpoint. -/
def safeNodeEnable (state : Shared) (socketPath : String)
    (extraEnv : Array (String × String) := #[]) :
    IO LeanCli.SafeNode.Persistent.Client := do
  let s ← state.get
  match s.safeNode with
  | some c => pure c
  | none =>
      let c ← LeanCli.SafeNode.Persistent.start socketPath extraEnv
      state.modify (fun s => { s with safeNode := some c, safeNodeSocket := some socketPath })
      -- Prime the cached proxy URL so the first `safeNodeProxyUrl?` read
      -- in the helios path doesn't pay a UDS round-trip.
      let _ ← LeanCli.SafeNode.Persistent.getProxyUrl c
      pure c

/-- Tear down the persistent safenode sidecar. Idempotent. -/
def safeNodeDisable (state : Shared) : IO Unit := do
  let s ← state.get
  match s.safeNode with
  | none => pure ()
  | some c =>
      try LeanCli.SafeNode.Persistent.close c catch _ => pure ()
      state.modify (fun s => { s with safeNode := none, safeNodeSocket := none })

/-- Read the current safenode client without spawning. -/
def safeNodeClient? (state : Shared) : IO (Option LeanCli.SafeNode.Persistent.Client) := do
  pure (← state.get).safeNode

/-- Read the safenode sidecar's local HTTP proxy URL if it is running.
    The daemon substitutes this URL for `executionRpc` on helios calls
    when present, so every `eth_getProof` is tunneled through the
    TDX-pinned channel. Returns `none` when safenode is off (helios then
    falls back to the configured `rpcEndpoint`). -/
def safeNodeProxyUrl? (state : Shared) : IO (Option String) := do
  match (← state.get).safeNode with
  | none => pure none
  | some c => LeanCli.SafeNode.Persistent.getProxyUrl c

/-- Read the daemon's current default read backend. -/
def getReadBackend (state : Shared) : IO ReadBackend := do
  pure (← state.get).readBackend

/-- Set the daemon's default read backend. -/
def setReadBackend (state : Shared) (b : ReadBackend) : IO Unit := do
  state.modify (fun s => { s with readBackend := b })

/-- Override the daemon's active/default chain at runtime (`network.use`). -/
def setActiveChain (state : Shared) (chainId : Nat) : IO Unit := do
  state.modify (fun s => { s with activeChainId := some chainId })

/-- The current runtime chain override, or `none` to use `cfg.chainId`. -/
def activeChain? (state : Shared) : IO (Option Nat) := do
  pure (← state.get).activeChainId

/-! ## Verified-read backend builder

  These helpers wire the persistent Colibri client into the Outbound RPC
  layer, including the auto-respawn-and-retry policy on transport
  crashes. They live in `Daemon.State` (rather than in `Daemon.Server`)
  because (a) `Daemon.TokenMeta` and `Daemon.Preflight` build verified-
  read clients too and need to share the same recovery semantics, and
  (b) the closure mutates `Shared`, so co-locating it with the state
  type keeps invariants reviewable.
-/

private def colibriCompact (j : LeanCli.Encoding.Json.Json) : String :=
  LeanCli.Encoding.Json.compact j

/-- Issue one Colibri request, classify the result, and surface transport-
    level deaths as `.transportDead` (distinct from legitimate sidecar-
    reported RPC errors). No recovery — the caller decides. -/
private def runColibriOnce (client : LeanCli.Colibri.Persistent.Client)
    (chainId : Nat) (method : LeanCli.Network.Provider.RpcMethod)
    (params : LeanCli.Encoding.Json.Json) :
    IO LeanCli.RPC.Outbound.ColibriOutcome := do
  let proxyParams : LeanCli.Encoding.Json.Json := .obj #[
    ("chainId", .num (Int.ofNat chainId)),
    ("method", .str method.asString),
    ("params", params)
  ]
  let resp ← LeanCli.Colibri.Persistent.call client "eth.proxy" proxyParams
  match resp with
  | .ok j => pure (.ok j)
  | .err code msg _ => pure (.rpcError s!"colibri rpc-error code={code}: {msg}")
  | .crash reason => pure (.rpcError s!"colibri transport: {reason}")
  | .transportCrash reason => pure (.transportDead reason)

/-- Append a JSONL line to the daemon network log under a colibri-respawn
    event kind. Mirrors `Outbound.logEvent` but is reproduced here to
    avoid widening the public surface of `Outbound`. -/
private def logColibriRespawnEvent
    (method : LeanCli.Network.Provider.RpcMethod) (phase : String)
    (extra : Array (String × LeanCli.Encoding.Json.Json)) : IO Unit := do
  let ts ← IO.monoMsNow
  match ← LeanCli.RPC.Outbound.networkLogPath with
  | none => pure ()
  | some p =>
      try
        let fp : System.FilePath := p
        match fp.parent with
        | some parent => IO.FS.createDirAll parent
        | none => pure ()
        let h ← IO.FS.Handle.mk fp .append
        let fields : Array (String × LeanCli.Encoding.Json.Json) :=
          #[("ts_ms", .num (Int.ofNat ts)),
            ("kind", .str "colibri-respawn"),
            ("method", .str method.asString),
            ("backend", .str "colibri"),
            ("phase", .str phase)] ++ extra
        h.putStr (colibriCompact (.obj fields) ++ "\n")
        h.flush
      catch _ => pure ()

/-- Build the verified-read backend if the persistent Colibri client is
    running. Returns `none` when colibri is off so calls fall through to
    the configured HTTP endpoint. Read sites pass the result to
    `Outbound.*` to opt every proofable read into stateless verification.

    The returned `VerifyVia` closes over `state` so it can do one
    auto-respawn-and-retry when the sidecar dies mid-session. On a
    second consecutive transport crash (or a respawn failure) the closure
    clears the client from shared state and returns `.transportDead`,
    letting `Outbound.call` fall back to HTTP and emit a user-visible
    notice. Single-actor recovery: only the call that hit the crash
    initiates respawn; the dead-client cascade observed in the original
    bug (every subsequent call ✗ in 0–1ms) is prevented by clearing
    `colibri` on the second crash. -/
def buildColibriVia (state : Shared) (chainId : Nat) :
    IO (Option LeanCli.RPC.Outbound.VerifyVia) := do
  match (← state.get).colibri with
  | none => pure none
  | some client =>
      let lock := (← state.get).verifyLock
      let runCall :
          LeanCli.Network.Provider.RpcMethod →
          LeanCli.Encoding.Json.Json →
          IO LeanCli.RPC.Outbound.ColibriOutcome :=
        fun method params => do
          -- Serialize on the single colibri connection (see `verifyLock`): a
          -- concurrent daemon handler must wait rather than interleave on the
          -- shared UDS conn. `finally` guarantees the lock is released even if
          -- the round-trip throws.
          lock.lock
          try
            match ← runColibriOnce client chainId method params with
            | .ok j => pure (.ok j)
            | .rpcError m => pure (.rpcError m)
            | .transportDead reason =>
                logColibriRespawnEvent method "start"
                  #[("reason", .str reason)]
                match ← colibriRespawn state with
                | none =>
                    logColibriRespawnEvent method "failed"
                      #[("reason", .str "spawn-failed")]
                    pure (.transportDead s!"respawn failed after {reason}")
                | some fresh =>
                    logColibriRespawnEvent method "ok" #[]
                    match ← runColibriOnce fresh chainId method params with
                    | .ok j => pure (.ok j)
                    | .rpcError m => pure (.rpcError m)
                    | .transportDead reason2 =>
                        colibriDisable state
                        logColibriRespawnEvent method "second-crash"
                          #[("reason", .str reason2)]
                        pure (.transportDead s!"second crash after respawn: {reason2}")
          finally
            lock.unlock
      pure (some { chainId := chainId, label := "colibri", runCall := runCall })

/-- One proofable read through the persistent Helios client. Mirrors
    `runColibriOnce`, but Helios's `eth.proxy` additionally requires the
    untrusted `executionRpc` it fetches proofs from and verifies against the
    sync-committee state root. Maps the transport-crash case to
    `.transportDead` so `Outbound.call` falls back to the configured HTTP
    endpoint (flagged unverified) rather than hanging. -/
private def runHeliosOnce (client : LeanCli.Helios.Persistent.Client)
    (chainId : Nat) (executionRpc : String)
    (method : LeanCli.Network.Provider.RpcMethod)
    (params : LeanCli.Encoding.Json.Json) :
    IO LeanCli.RPC.Outbound.ColibriOutcome := do
  let proxyParams : LeanCli.Encoding.Json.Json := .obj #[
    ("chainId",      .num (Int.ofNat chainId)),
    ("executionRpc", .str executionRpc),
    ("method",       .str method.asString),
    ("params",       params)
  ]
  let resp ← LeanCli.Helios.Persistent.call client "eth.proxy" proxyParams
  match resp with
  | .ok j => pure (.ok j)
  | .err code msg _ => pure (.rpcError s!"helios rpc-error code={code}: {msg}")
  | .crash reason => pure (.rpcError s!"helios transport: {reason}")
  | .transportCrash reason => pure (.transportDead reason)

/-- Respawn the helios sidecar + reconnect after a transport crash. Mirrors
    `colibriRespawn`: close the dead client, re-spawn from the cached
    `heliosSocket`, store the fresh client. Returns `none` if respawn fails.
    This is the "keep helios up / restart" tier — a dropped connection or a
    sidecar crash recovers automatically instead of leaving helios dead. -/
def heliosRespawn (state : Shared) : IO (Option LeanCli.Helios.Persistent.Client) := do
  let s ← state.get
  match s.heliosSocket with
  | none => pure none
  | some socketPath =>
      match s.helios with
      | some c => try LeanCli.Helios.Persistent.close c catch _ => pure ()
      | none => pure ()
      try
        let c ← LeanCli.Helios.Persistent.start socketPath
        state.modify (fun s => { s with helios := some c })
        pure (some c)
      catch _ =>
        state.modify (fun s => { s with helios := none })
        pure none

/-- Cascade a verified read from a dead helios to colibri (the degradation
    order is helios → colibri → direct). Called only after a helios respawn
    failed to recover. Disables helios so subsequent reads route straight to
    colibri (via `verifiedReadVia`) without re-paying the helios attempt, and
    serves THIS read through colibri so it stays verified. Only if colibri is
    also down do we signal `.transportDead`, which Outbound turns into a
    direct (unverified) HTTP read. -/
private def heliosCascadeColibri (state : Shared) (chainId : Nat)
    (method : LeanCli.Network.Provider.RpcMethod)
    (params : LeanCli.Encoding.Json.Json) (reason : String) (disableHelios : Bool) :
    IO LeanCli.RPC.Outbound.ColibriOutcome := do
  -- Disable helios only when its CONNECTION is dead (transportDead) so we stop
  -- hammering it. On a plain rpcError helios is alive — it just can't serve
  -- this particular read (e.g. unverifiable `pending`, or a revert) — so keep
  -- it enabled for subsequent reads. Either way we cascade THIS read to
  -- colibri; if colibri also can't serve it, the colibri outcome
  -- (rpcError / transportDead) propagates and Outbound degrades to direct
  -- (the last resort). Never a hard fail, never a skip straight to direct.
  if disableHelios then heliosDisable state
  match (← state.get).colibri with
  | some cclient =>
      IO.eprintln s!"leancli-daemon: helios couldn't serve ({reason}); cascading to colibri"
      runColibriOnce cclient chainId method params
  | none =>
      pure (.transportDead s!"helios+colibri unavailable: {reason}")

/-- Build the verified-read backend if the persistent Helios client is
    running. Parallel to `buildColibriVia` — returns `none` when helios is
    off so `verifiedReadVia` cascades to colibri / direct. `executionRpc` is
    threaded per call (Helios is multi-chain). The runCall implements the
    helios → colibri → direct degradation: try helios, respawn-once on a
    transport crash, and on persistent failure cascade to colibri. -/
def buildHeliosVia (state : Shared) (chainId : Nat) (executionRpc : String) :
    IO (Option LeanCli.RPC.Outbound.VerifyVia) := do
  match ← heliosClient? state with
  | none => pure none
  | some client =>
      let lock := (← state.get).verifyLock
      let runCall := fun method params => do
        -- Serialize on the single helios connection (see `verifyLock`).
        lock.lock
        try
          match ← runHeliosOnce client chainId executionRpc method params with
          | .ok j => pure (.ok j)
          | .rpcError m =>
              -- Helios is alive but can't serve this read (e.g. unverifiable
              -- `pending`, or a revert) → cascade to colibri, keep helios up.
              heliosCascadeColibri state chainId method params m false
          | .transportDead reason =>
              -- Helios conn dead → respawn the sidecar once and retry (keep
              -- helios alive across transient drops). If it's still dead,
              -- disable + cascade to colibri (helios → colibri → direct).
              IO.eprintln s!"leancli-daemon: helios transport dead ({reason}); respawning…"
              match ← heliosRespawn state with
              | some fresh =>
                  match ← runHeliosOnce fresh chainId executionRpc method params with
                  | .ok j => pure (.ok j)
                  | .rpcError m => heliosCascadeColibri state chainId method params m false
                  | .transportDead reason2 =>
                      heliosCascadeColibri state chainId method params reason2 true
              | none =>
                  heliosCascadeColibri state chainId method params reason true
        finally
          lock.unlock
      pure (some { chainId := chainId, label := "helios", runCall := runCall })

end LeanCli.Daemon.State
