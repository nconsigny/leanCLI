import LeanKohaku.Encoding.Json

/-!
# Local transaction journal

Append-only NDJSON log of every transaction the daemon broadcasts. One file
per slot under `$XDG_DATA_HOME/leankohaku/journal/<slot>.ndjson`. Status
updates are written as separate `kind="status"` lines so writes are always
append-only (atomic via `O_APPEND`). Best-effort: a write failure must
never fail the user's tx.
-/

namespace LeanKohaku.Daemon.TxJournal

open LeanKohaku.Encoding.Json

structure Entry where
  timestamp     : Nat
  txHash        : String
  fromAddr      : String
  toAddr        : String
  valueWei      : Nat
  dataHex       : String
  nonce         : Nat
  chainId       : Nat
  kind          : String
  accountIndex? : Option Nat := none
  slotName      : String
  status?       : Option String := none
  blockNumber?  : Option String := none
  gasUsed?      : Option String := none
  deriving Repr

private def fileMode : IO.FileRight :=
  { user := { read := true, write := true } }

private def dirMode : IO.FileRight :=
  { user := { read := true, write := true, execution := true } }

def dataHome : IO System.FilePath := do
  match ← IO.getEnv "XDG_DATA_HOME" with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "HOME" with
      | some home => pure (home ++ "/.local/share")
      | none => pure ".leankohaku"

def journalDir : IO System.FilePath := do
  pure ((← dataHome) / "leankohaku" / "journal")

def journalPath (slot : String) : IO System.FilePath := do
  pure ((← journalDir) / (slot ++ ".ndjson"))

def scanStatePath (slot : String) : IO System.FilePath := do
  pure ((← journalDir) / (slot ++ ".scan.json"))

def Entry.toJson (e : Entry) : Json :=
  let base : Array (String × Json) := #[
    ("timestamp", .num (Int.ofNat e.timestamp)),
    ("txHash", .str e.txHash),
    ("from", .str e.fromAddr),
    ("to", .str e.toAddr),
    ("valueWei", .str (toString e.valueWei)),
    ("dataHex", .str e.dataHex),
    ("nonce", .num (Int.ofNat e.nonce)),
    ("chainId", .num (Int.ofNat e.chainId)),
    ("kind", .str e.kind),
    ("slotName", .str e.slotName)
  ]
  let withAcc :=
    match e.accountIndex? with
    | none => base
    | some i => base.push ("accountIndex", .num (Int.ofNat i))
  let withStatus :=
    match e.status? with
    | none => withAcc
    | some s => withAcc.push ("status", .str s)
  let withBlock :=
    match e.blockNumber? with
    | none => withStatus
    | some b => withStatus.push ("blockNumber", .str b)
  let withGas :=
    match e.gasUsed? with
    | none => withBlock
    | some g => withBlock.push ("gasUsed", .str g)
  .obj withGas

private def ensureDir : IO Unit := do
  let dir ← journalDir
  try
    IO.FS.createDirAll dir
    IO.setAccessRights dir dirMode
  catch _ => pure ()

/-- Best-effort append. Never throws; logs to stderr on failure. -/
def append (slotName : String) (entry : Entry) : IO Unit := do
  try
    ensureDir
    let path ← journalPath slotName
    let h ← IO.FS.Handle.mk path .append
    h.putStr (compact entry.toJson ++ "\n")
    h.flush
    (do try IO.setAccessRights path fileMode catch _ => pure ())
  catch e =>
    IO.eprintln s!"[journal] append failed for slot={slotName}: {e.toString}"

/-- Append a status-update record. Reader reconciles by txHash. -/
def appendStatus (slotName txHash status : String)
    (blockNumber? gasUsed? : Option String := none) : IO Unit := do
  try
    ensureDir
    let path ← journalPath slotName
    let nowMs ← IO.monoMsNow
    let nowSec : Nat := nowMs / 1000
    let base : Array (String × Json) := #[
      ("timestamp", .num (Int.ofNat nowSec)),
      ("kind", .str "status"),
      ("txHash", .str txHash),
      ("status", .str status),
      ("slotName", .str slotName)
    ]
    let withBlock :=
      match blockNumber? with
      | none => base
      | some b => base.push ("blockNumber", .str b)
    let withGas :=
      match gasUsed? with
      | none => withBlock
      | some g => withBlock.push ("gasUsed", .str g)
    let h ← IO.FS.Handle.mk path .append
    h.putStr (compact (.obj withGas) ++ "\n")
    h.flush
  catch e =>
    IO.eprintln s!"[journal] appendStatus failed for slot={slotName}: {e.toString}"

private partial def parseLines : List String → Array Json → Array Json
  | [], acc => acc
  | line :: rest, acc =>
      let trimmed := line.trim
      if trimmed.isEmpty then parseLines rest acc
      else
        match parse trimmed with
        | .ok j => parseLines rest (acc.push j)
        | .error _ => parseLines rest acc

/-- Returns all entries for a slot. Missing file → empty. The reader does
    not reconcile status updates here; the caller (CLI) merges by `txHash`. -/
def read (slotName : String) (limit? : Option Nat := none) : IO (Array Json) := do
  try
    let path ← journalPath slotName
    if !(← path.pathExists) then
      pure #[]
    else
      let text ← IO.FS.readFile path
      let lines := text.splitOn "\n"
      let entries := parseLines lines #[]
      match limit? with
      | none => pure entries
      | some n =>
          let total := entries.size
          if total ≤ n then pure entries
          else pure (entries.extract (total - n) total)
  catch e =>
    IO.eprintln s!"[journal] read failed for slot={slotName}: {e.toString}"
    pure #[]

/-- Read the last-scanned-block marker for `--scan-logs`. -/
def readScanState (slotName : String) : IO (Option Nat) := do
  try
    let path ← scanStatePath slotName
    if !(← path.pathExists) then pure none
    else
      let text ← IO.FS.readFile path
      match parse text with
      | .ok j =>
          pure (getField "lastScannedBlock" j >>= asNat)
      | .error _ => pure none
  catch _ => pure none

def writeScanState (slotName : String) (lastScannedBlock : Nat) : IO Unit := do
  try
    ensureDir
    let path ← scanStatePath slotName
    let body := compact <| .obj #[
      ("lastScannedBlock", .num (Int.ofNat lastScannedBlock))
    ]
    IO.FS.writeFile path (body ++ "\n")
    (do try IO.setAccessRights path fileMode catch _ => pure ())
  catch e =>
    IO.eprintln s!"[journal] writeScanState failed for slot={slotName}: {e.toString}"

end LeanKohaku.Daemon.TxJournal
