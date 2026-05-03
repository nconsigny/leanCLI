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

end LeanKohaku.Daemon.State
