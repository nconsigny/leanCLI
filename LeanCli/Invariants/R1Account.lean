import LeanCli.Contract.R1Account

/-!
# R1 account invariants
-/

namespace LeanCli.Invariants.R1Account

open LeanCli.Contract.R1Account
open LeanCli.Ethereum.P256Precompile

theorem applySomeSupportedChainOnly
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' → supportedChainId op.chainId = true := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    exact ok.left
  · simp [ok] at h

theorem applySomeConsumesCurrentNonce
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' → op.nonce = st.nonce := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    exact ok.right.left
  · simp [ok] at h

theorem applySomeIncrementsNonce
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' → st'.nonce = st.nonce + 1 := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    rw [← h]
  · simp [ok] at h

theorem applySomeUsedValidEip7951Input
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' →
      validInput (toPrecompileInput st.key op) := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    exact ok.right.right.left
  · simp [ok] at h

theorem applySomeVerifiedByOracle
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' →
      verify (toPrecompileInput st.key op) = true := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    exact ok.right.right.right
  · simp [ok] at h

end LeanCli.Invariants.R1Account
