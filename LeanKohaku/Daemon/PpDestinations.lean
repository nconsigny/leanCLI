import LeanKohaku.Encoding.Json

/-!
# Privacy-Pools unshield destinations log

A small append-only NDJSON file that records every recipient address
the daemon has unshielded ETH to. The wallets-hub TUI's "0-link" green
marker reads this list so an address that received its only funding
from a PP withdrawal still qualifies as unlinked — without it, the
naïve nonce/ERC-20-history check would lose its green tag the moment
the unshield landed.

Honesty caveat: this log only sees withdrawals THIS daemon performed.
An address funded by a PP withdrawal initiated by a different wallet
will not appear here; the freshness check degrades to "balance == 0"
in that case, which is the conservative answer. We do not try to
reconstruct PP recipients from chain state — the Withdrawn event's
indexed topic is the relayer/processooor, not the recipient, so doing
so would require fetching every withdrawal tx's calldata. Not worth
the complexity when the daemon already knows what it did.

File layout: one JSON object per line at
`$XDG_DATA_HOME/leankohaku/pp-destinations.ndjson`. Lookups are
linear in the file size, which is fine — a wallet typically
unshields tens of times over its life.
-/

namespace LeanKohaku.Daemon.PpDestinations

open LeanKohaku.Encoding.Json

private def fileMode : IO.FileRight :=
  { user := { read := true, write := true } }

private def dirMode : IO.FileRight :=
  { user := { read := true, write := true, execution := true } }

private def dataHome : IO System.FilePath := do
  match ← IO.getEnv "XDG_DATA_HOME" with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "HOME" with
      | some home => pure (home ++ "/.local/share")
      | none => pure ".leankohaku"

def storePath : IO System.FilePath := do
  pure ((← dataHome) / "leankohaku" / "pp-destinations.ndjson")

private def ensureDir : IO Unit := do
  let path ← storePath
  match path.parent with
  | some parent =>
      try
        IO.FS.createDirAll parent
        IO.setAccessRights parent dirMode
      catch _ => pure ()
  | none => pure ()

private def normalize (addr : String) : String :=
  (if addr.startsWith "0x" || addr.startsWith "0X" then
     "0x" ++ (addr.drop 2).toString
   else
     "0x" ++ addr).toLower

/-- Append a recipient address with the current timestamp + chainId
context. Best-effort: failures are logged but never propagated, so a
flaky disk never blocks an otherwise-successful unshield. -/
def append (recipient : String) (chainId : Nat) (method : String) : IO Unit := do
  try
    ensureDir
    let path ← storePath
    let nowMs ← IO.monoMsNow
    let nowSec : Nat := nowMs / 1000
    let entry := compact <| .obj #[
      ("timestamp", .num (Int.ofNat nowSec)),
      ("recipient", .str (normalize recipient)),
      ("chainId", .num (Int.ofNat chainId)),
      ("via", .str method)
    ]
    let h ← IO.FS.Handle.mk path .append
    h.putStr (entry ++ "\n")
    h.flush
    (do try IO.setAccessRights path fileMode catch _ => pure ())
  catch e =>
    IO.eprintln s!"[pp-destinations] append failed for {recipient}: {e.toString}"

/-- True if `addr` (case-insensitive) appears anywhere in the file. -/
def contains (addr : String) : IO Bool := do
  try
    let path ← storePath
    if !(← path.pathExists) then pure false
    else
      let text ← IO.FS.readFile path
      let target := normalize addr
      let mut hit := false
      for line in text.splitOn "\n" do
        if hit then break
        let trimmed := line.trim
        if trimmed.isEmpty then continue
        match parse trimmed with
        | .ok j =>
            match getField "recipient" j >>= asString with
            | some r => if normalize r = target then hit := true
            | none => pure ()
        | .error _ => pure ()
      pure hit
  catch e =>
    IO.eprintln s!"[pp-destinations] contains failed: {e.toString}"
    pure false

/-- Return every recipient on file. Used by `daemon.ppDestinations.list`
for inspection / debugging. -/
def list : IO (Array Json) := do
  try
    let path ← storePath
    if !(← path.pathExists) then pure #[]
    else
      let text ← IO.FS.readFile path
      let mut acc : Array Json := #[]
      for line in text.splitOn "\n" do
        let trimmed := line.trim
        if trimmed.isEmpty then continue
        match parse trimmed with
        | .ok j => acc := acc.push j
        | .error _ => pure ()
      pure acc
  catch _ => pure #[]

end LeanKohaku.Daemon.PpDestinations
