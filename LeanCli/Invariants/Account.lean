import LeanCli.Wallet.Account

/-!
# Account policy invariants
-/

namespace LeanCli.Invariants.Account

open LeanCli.Wallet.Account
open LeanCli.Ethereum.Chain

theorem acceptedSupportedChainOnly (p : AccountPolicy) :
    accepted p = true → supportedChainId p.chainId = true := by
  intro h
  cases p with
  | mk kind source chainId path localOnly =>
    cases kind <;> cases source <;> cases path <;> cases localOnly <;>
      simp [accepted, compatible] at h ⊢ <;>
      first | exact h | exact h.left

theorem acceptedLocalOnly (p : AccountPolicy) :
    accepted p = true → p.localOnly = true := by
  intro h
  cases p with
  | mk kind source chainId path localOnly =>
    cases kind <;> cases source <;> cases path <;> cases localOnly <;>
      simp [accepted, compatible] at h ⊢

theorem defaultEoaK1Accepted :
    accepted defaultEoaK1 = true := by
  simp [accepted, defaultEoaK1, defaultEthereumPath, supportedChainId, compatible]

theorem sepoliaEoaK1Accepted :
    accepted sepoliaEoaK1 = true := by
  simp [accepted, sepoliaEoaK1, defaultEoaK1, defaultEthereumPath, supportedChainId,
    compatible]

theorem eoaK1UsesBip39WhenAccepted (p : AccountPolicy) :
    accepted p = true →
      p.kind = AccountKind.eoaK1 →
        p.source = KeySource.bip39Mnemonic := by
  intro h kindEq
  cases p with
  | mk kind source chainId path localOnly =>
    cases kind <;> cases source <;> cases path <;> cases localOnly <;>
      simp [accepted, compatible] at h kindEq ⊢

end LeanCli.Invariants.Account
