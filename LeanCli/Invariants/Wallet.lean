import LeanCli.Invariants.Amount

/-!
# Abstract wallet state + multi-output send

This module introduces the minimal wallet model used to formalize
invariant **1.2** (sum of outputs + fee ≤ sender balance) from
`INVARIANTS.md`. The model is deliberately thin — a balance per
account, a `Send` record, a guarded `apply`. No crypto, no RPC.
The operational wallet will eventually refine these types.

## Properties proved here

* `apply_some_affordable` — `apply` returns `some _` only when the
  send is affordable. The wallet cannot be tricked into debiting a
  sender below zero by silent `Nat.sub` clamping.
* `apply_sender_debited` — on success, the sender's new balance plus
  the send total equals the old balance (exact debit).
-/

namespace LeanCli.Invariants.Wallet

/-- Account identifier. Kept as a `String` here because this module is
about bookkeeping, not encoding — byte-level address canonicalization
lives in `LeanCli.Ethereum.Address`. -/
abbrev AccountId := String

/-- Minimal wallet model: one balance per account. -/
structure State where
  balance : AccountId → Nat

/-- The empty ledger: every account has zero balance. -/
def State.empty : State := { balance := fun _ => 0 }

/-- Credit `a` by `n`. Used to set up fixtures in tests; not part of
the invariant surface. -/
def State.credit (σ : State) (a : AccountId) (n : Nat) : State :=
  { balance := fun x => if x = a then σ.balance x + n else σ.balance x }

/-- A single output in a multi-output send. -/
structure Output where
  to     : AccountId
  amount : Nat
  deriving Repr

/-- A proposed send from one account to zero-or-more recipients, with
an explicit fee. Fee is separate from outputs so the `total` math is
impossible to conflate. -/
structure Send where
  sender  : AccountId
  outputs : List Output
  fee     : Nat
  deriving Repr

/-- Sum of all output amounts (excluding fee). -/
def Send.outputsTotal (s : Send) : Nat :=
  (s.outputs.map Output.amount).foldr (· + ·) 0

/-- Total wei leaving the sender: outputs + fee. -/
def Send.total (s : Send) : Nat :=
  s.outputsTotal + s.fee

/-- Affordability predicate: the sender has enough to cover the full total. -/
def Send.affordable (σ : State) (s : Send) : Prop :=
  s.total ≤ σ.balance s.sender

instance (σ : State) (s : Send) : Decidable (Send.affordable σ s) :=
  Nat.decLe s.total (σ.balance s.sender)

/-- Total amount credited to account `a` by a send. -/
def Send.creditedTo (s : Send) (a : AccountId) : Nat :=
  ((s.outputs.filter (fun o => decide (o.to = a))).map Output.amount).foldr (· + ·) 0

/-- Apply a send. Returns `none` when the sender can't afford it;
otherwise debits the sender by `s.total` and credits each recipient
by the sum of outputs addressed to them. -/
def apply (σ : State) (s : Send) : Option State :=
  if h : s.affordable σ then
    let _ := h  -- keep `h` in scope even though the resulting state
                -- doesn't structurally depend on it
    some {
      balance := fun a =>
        if a = s.sender then σ.balance a - s.total
        else σ.balance a + s.creditedTo a
    }
  else
    none

/-! ### Proofs of invariant 1.2 -/

/-- **Refuse-insufficient.** `apply` returns `some _` only when the
send is affordable. -/
theorem apply_some_affordable {σ σ' : State} {s : Send}
    (h : apply σ s = some σ') : s.affordable σ := by
  unfold apply at h
  by_cases hA : s.affordable σ
  · exact hA
  · simp [hA] at h

/-- **Sender-debited.** When `apply` succeeds, the sender's new
balance plus the send total equals the old balance — i.e. the sender
is debited by exactly `s.total`, with no silent underflow. -/
theorem apply_sender_debited {σ σ' : State} {s : Send}
    (h : apply σ s = some σ') :
    σ'.balance s.sender + s.total = σ.balance s.sender := by
  have hA : s.affordable σ := apply_some_affordable h
  unfold apply at h
  rw [dif_pos hA] at h
  injection h with hEq
  -- hEq : { balance := … } = σ'
  subst hEq
  simp
  exact Nat.sub_add_cancel hA

/-- **Non-sender accounting.** Every account other than the sender
sees its balance grow by exactly the sum of outputs addressed to it. -/
theorem apply_non_sender_balance {σ σ' : State} {s : Send} {a : AccountId}
    (h : apply σ s = some σ') (hne : a ≠ s.sender) :
    σ'.balance a = σ.balance a + s.creditedTo a := by
  have hA : s.affordable σ := apply_some_affordable h
  unfold apply at h
  rw [dif_pos hA] at h
  injection h with hEq
  subst hEq
  simp [hne]

end LeanCli.Invariants.Wallet
