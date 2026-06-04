/-!
# Amount arithmetic invariants

We use `Nat` for token amounts (wei). The core invariant is that
arithmetic never underflows: subtraction is total on `Nat` but
`a - b = 0` when `b > a`, which would silently zero a balance.

Helpers here return `Option` to force callers to handle the
insufficient-funds case explicitly.
-/

namespace LeanCli.Invariants.Amount

/-- Checked subtraction: `some (a - b)` when `b ≤ a`, else `none`. -/
def subChecked (a b : Nat) : Option Nat :=
  if b ≤ a then some (a - b) else none

theorem subChecked_some_iff {a b : Nat} :
    (subChecked a b).isSome ↔ b ≤ a := by
  unfold subChecked
  by_cases h : b ≤ a
  · simp [h]
  · simp [h]

theorem subChecked_preserves_total {a b r : Nat}
    (h : subChecked a b = some r) : r + b = a := by
  unfold subChecked at h
  by_cases hba : b ≤ a
  · simp [hba] at h
    subst h
    exact Nat.sub_add_cancel hba
  · simp [hba] at h

end LeanCli.Invariants.Amount
