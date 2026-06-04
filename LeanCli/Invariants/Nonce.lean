/-!
# Nonce monotonicity

Invariant: once the wallet has broadcast a transaction with nonce `k`
from an account, it must never sign another tx with nonce `≤ k` for
that account (without explicit replacement semantics we haven't
modeled yet). This prevents replay/replacement bugs.

We model the wallet state's "last used nonce" per account and require
that the next nonce is strictly greater.
-/

namespace LeanCli.Invariants.Nonce

/-- Abstract per-account nonce ledger. -/
def NonceLedger := String → Option Nat

def empty : NonceLedger := fun _ => none

def record (l : NonceLedger) (addr : String) (n : Nat) : NonceLedger :=
  fun a => if a = addr then some n else l a

/-- A proposed nonce is valid for an account iff it is strictly greater
than the last one recorded (or the account has never signed before). -/
def validNext (l : NonceLedger) (addr : String) (n : Nat) : Prop :=
  match l addr with
  | none   => True
  | some k => k < n

end LeanCli.Invariants.Nonce
