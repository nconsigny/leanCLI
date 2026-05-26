import LeanKohaku.Daemon.TxJournal

/-!
# Daemon server: tx-journal write helper

Single-function module hoisted out of `LeanKohaku/Daemon/Server.lean`.
Best-effort append into the per-slot TxJournal. Failures are logged
inside `Daemon.TxJournal.append` and never propagated to the caller
— journaling must not fail a signed transaction.
-/

namespace LeanKohaku.Daemon.Server

/-- Append one TxJournal entry for a tx the daemon just signed/broadcast.
    Best-effort: failures are logged but never raised. Why: keep journaling
    out of the success path so a write error can never fail the user's tx.

    The trailing keyword-style `signMs? / paramSet? / userOpHash?` knobs
    are SPHINCS+-specific metadata used by `kind = "sphincs.userOp"`
    entries to record the post-quantum sign duration ("the grind") and
    parameter set. Other kinds leave them as `none` and the JSON encoder
    drops them. -/
def journalRecord
    (slotName fromAddr toAddr txHash dataHex kind : String)
    (valueWei nonce chainId : Nat)
    (accountIndex? : Option Nat)
    (status? blockNumber? gasUsed? : Option String)
    (signMs? : Option Nat := none)
    (paramSet? : Option String := none)
    (userOpHash? : Option String := none) : IO Unit := do
  let nowMs ← IO.monoMsNow
  let nowSec : Nat := nowMs / 1000
  let entry : LeanKohaku.Daemon.TxJournal.Entry :=
    { timestamp := nowSec, txHash := txHash, fromAddr := fromAddr,
      toAddr := toAddr, valueWei := valueWei, dataHex := dataHex,
      nonce := nonce, chainId := chainId, kind := kind,
      accountIndex? := accountIndex?, slotName := slotName,
      status? := status?, blockNumber? := blockNumber?, gasUsed? := gasUsed?,
      signMs? := signMs?, paramSet? := paramSet?, userOpHash? := userOpHash? }
  LeanKohaku.Daemon.TxJournal.append slotName entry

end LeanKohaku.Daemon.Server
