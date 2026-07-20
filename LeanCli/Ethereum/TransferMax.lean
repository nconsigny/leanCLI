import LeanCli.Invariants.Amount

/-!
# Maximum native transfer amount

The daemon reserves a conservative gas budget before binding a `max` send to
a concrete wei value.  Keeping the subtraction here makes the underflow
behaviour explicit and independently checkable.
-/

namespace LeanCli.Ethereum.TransferMax

open LeanCli.Invariants.Amount

/-- Spendable balance after reserving transaction fees. Returns zero rather
than underflowing when the reserve consumes the balance. -/
def transferMaxAmountFromBalance (balance reserve : Nat) : Nat :=
  (subChecked balance reserve).getD 0

theorem transferMaxAmountFromBalance_le (balance reserve : Nat) :
    transferMaxAmountFromBalance balance reserve ≤ balance := by
  unfold transferMaxAmountFromBalance subChecked
  split <;> simp_all [Nat.sub_le]

theorem transferMaxAmountFromBalance_eq_zero_of_le
    {balance reserve : Nat} (h : balance ≤ reserve) :
    transferMaxAmountFromBalance balance reserve = 0 := by
  unfold transferMaxAmountFromBalance subChecked
  split
  · rename_i hReserve
    have : balance = reserve := Nat.le_antisymm h hReserve
    simp [this]
  · rfl

example : transferMaxAmountFromBalance 100 25 = 75 := by native_decide
example : transferMaxAmountFromBalance 25 25 = 0 := by native_decide
example : transferMaxAmountFromBalance 24 25 = 0 := by native_decide

end LeanCli.Ethereum.TransferMax
