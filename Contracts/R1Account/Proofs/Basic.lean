import Contracts.R1Account.Spec
import Contracts.R1Account.Invariants

/-!
# R1Account basic proof obligations

These theorems are intentionally small and mirror the already-built
`LeanCli.Contract.R1Account` model. Once Verity is added as a dependency,
these should be strengthened against Verity's generated compilation model.
-/

namespace Contracts.R1Account.Proofs.Basic

open Verity
open Verity.EVM.Uint256
open Contracts.R1Account
open Contracts.R1Account.Spec
open Contracts.R1Account.Invariants

theorem initialize_sets_key_and_nonce
    (qx qy : Uint256) (s : ContractState) :
    match (initialize qx qy).run s with
    | ContractResult.success _ s' => initializedSpec qx qy s s'
    | ContractResult.revert _ _ => False := by
  simp [initialize, initializedSpec, qxSlot, qySlot, nonceSlot]

theorem accepted_execute_advances_nonce_and_preserves_key
    (target : Address) (value dataHash r sigS : Uint256) (s s' : ContractState) :
    (execute target value dataHash r sigS).run s = ContractResult.success () s' →
      nonceAdvancedByOne s s' ∧ publicKeyUnchanged s s' := by
  intro h
  simp [execute, nonceAdvancedByOne, publicKeyUnchanged, qxSlot, qySlot, nonceSlot] at h ⊢

end Contracts.R1Account.Proofs.Basic
