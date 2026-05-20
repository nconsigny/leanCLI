import LeanKohaku.Colibri.Persistent
import LeanKohaku.RPC.Outbound

/-!
# Daemon state

Small shared state for the daemon. Unlocked EOA seeds live only here.
-/

namespace LeanKohaku.Daemon.State

structure UnlockedSlot where
  name           : String
  seed           : ByteArray
  address        : String
  derivationPath : String
  unlockedAtMs   : Nat
  ttlMs          : Nat

/-- The wallet-level master KEK, when currently loaded.

The KEK never persists in clear text on disk; it lives only here while
loaded. Same TTL semantics as `UnlockedSlot` — purged on every access
once expired. Cleared explicitly by `lockMaster` / `wallet.lock`. -/
structure MasterKekSlot where
  kek          : ByteArray
  unlockedAtMs : Nat
  ttlMs        : Nat

/-- Cached ERC-20 metadata. The actual struct lives in
`LeanKohaku.Daemon.TokenMeta`; we store `(decimals, symbol)` raw to avoid
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
  colibri : Option LeanKohaku.Colibri.Persistent.Client := none
  /-- Socket path used to spawn `colibri`. Cached so `colibriRespawn` can
  bring the sidecar back without re-deriving the path (which lives in
  `Daemon.Config` and is otherwise not reachable from here). Cleared
  alongside `colibri` on `colibriDisable`. -/
  colibriSocket : Option String := none
  /-- Wallet-level master KEK, when currently loaded. `none` means the
  wallet is locked at the master level — slot unlocks must come through
  the per-slot `eoa.unlock` path. Populated by `wallet.unlock`. -/
  masterKek : Option MasterKekSlot := none

abbrev Shared := IO.Ref DaemonState

def new : IO Shared := do
  IO.mkRef { startedAtMs := ← IO.monoMsNow }

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

/-- Spawn the persistent Colibri client and store it in shared state.
    Idempotent: if a client is already running, returns it. Throws on
    spawn / connect failure (caller decides whether to surface or fall
    back). The caller supplies the socket path because this module sits
    below `Daemon.Config` in the import order. -/
def colibriEnable (state : Shared) (socketPath : String) : IO LeanKohaku.Colibri.Persistent.Client := do
  let s ← state.get
  match s.colibri with
  | some c => pure c
  | none =>
      let c ← LeanKohaku.Colibri.Persistent.start socketPath
      state.modify (fun s => { s with colibri := some c, colibriSocket := some socketPath })
      pure c

/-- Tear down the persistent Colibri client. Idempotent. -/
def colibriDisable (state : Shared) : IO Unit := do
  let s ← state.get
  match s.colibri with
  | none => pure ()
  | some c =>
      try LeanKohaku.Colibri.Persistent.close c catch _ => pure ()
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
def colibriRespawn (state : Shared) : IO (Option LeanKohaku.Colibri.Persistent.Client) := do
  let s ← state.get
  match s.colibriSocket with
  | none => pure none
  | some socketPath =>
      -- Close the dead client first so the spawned sidecar can claim the
      -- socket path cleanly. Errors here are expected (the conn is
      -- already broken) and intentionally swallowed.
      match s.colibri with
      | some c => try LeanKohaku.Colibri.Persistent.close c catch _ => pure ()
      | none => pure ()
      try
        let c ← LeanKohaku.Colibri.Persistent.start socketPath
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
def colibriClient? (state : Shared) : IO (Option LeanKohaku.Colibri.Persistent.Client) := do
  pure (← state.get).colibri

/-! ## Verified-read backend builder

  These helpers wire the persistent Colibri client into the Outbound RPC
  layer, including the auto-respawn-and-retry policy on transport
  crashes. They live in `Daemon.State` (rather than in `Daemon.Server`)
  because (a) `Daemon.TokenMeta` and `Daemon.Preflight` build verified-
  read clients too and need to share the same recovery semantics, and
  (b) the closure mutates `Shared`, so co-locating it with the state
  type keeps invariants reviewable.
-/

private def colibriCompact (j : LeanKohaku.Encoding.Json.Json) : String :=
  LeanKohaku.Encoding.Json.compact j

/-- Issue one Colibri request, classify the result, and surface transport-
    level deaths as `.transportDead` (distinct from legitimate sidecar-
    reported RPC errors). No recovery — the caller decides. -/
private def runColibriOnce (client : LeanKohaku.Colibri.Persistent.Client)
    (chainId : Nat) (method : LeanKohaku.Network.Provider.RpcMethod)
    (params : LeanKohaku.Encoding.Json.Json) :
    IO LeanKohaku.RPC.Outbound.ColibriOutcome := do
  let proxyParams : LeanKohaku.Encoding.Json.Json := .obj #[
    ("chainId", .num (Int.ofNat chainId)),
    ("method", .str method.asString),
    ("params", params)
  ]
  let resp ← LeanKohaku.Colibri.Persistent.call client "eth.proxy" proxyParams
  match resp with
  | .ok j => pure (.ok j)
  | .err code msg _ => pure (.rpcError s!"colibri rpc-error code={code}: {msg}")
  | .crash reason => pure (.rpcError s!"colibri transport: {reason}")
  | .transportCrash reason => pure (.transportDead reason)

/-- Append a JSONL line to the daemon network log under a colibri-respawn
    event kind. Mirrors `Outbound.logEvent` but is reproduced here to
    avoid widening the public surface of `Outbound`. -/
private def logColibriRespawnEvent
    (method : LeanKohaku.Network.Provider.RpcMethod) (phase : String)
    (extra : Array (String × LeanKohaku.Encoding.Json.Json)) : IO Unit := do
  let ts ← IO.monoMsNow
  match ← LeanKohaku.RPC.Outbound.networkLogPath with
  | none => pure ()
  | some p =>
      try
        let fp : System.FilePath := p
        match fp.parent with
        | some parent => IO.FS.createDirAll parent
        | none => pure ()
        let h ← IO.FS.Handle.mk fp .append
        let fields : Array (String × LeanKohaku.Encoding.Json.Json) :=
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
    IO (Option LeanKohaku.RPC.Outbound.VerifyVia) := do
  match (← state.get).colibri with
  | none => pure none
  | some client =>
      let runCall :
          LeanKohaku.Network.Provider.RpcMethod →
          LeanKohaku.Encoding.Json.Json →
          IO LeanKohaku.RPC.Outbound.ColibriOutcome :=
        fun method params => do
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
      pure (some { chainId := chainId, runCall := runCall })

end LeanKohaku.Daemon.State
