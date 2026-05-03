import LeanKohaku.Wallet.Account

/-!
# Account policy invariants
-/

namespace LeanKohaku.Invariants.Account

open LeanKohaku.Wallet.Account
open LeanKohaku.Ethereum.P256Precompile

theorem acceptedSupportedChainOnly (p : AccountPolicy) :
    accepted p = true → supportedChainId p.chainId = true := by
  intro h
  cases p with
  | mk kind source chainId path localOnly =>
    cases kind <;> cases source <;> cases path <;> cases localOnly <;>
      simp [accepted, compatible] at h ⊢
    · exact h.left
    · exact h

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

theorem defaultR1SmartAccepted :
    accepted defaultR1Smart = true := by
  simp [accepted, defaultR1Smart, supportedChainId, compatible]

theorem sepoliaEoaK1Accepted :
    accepted sepoliaEoaK1 = true := by
  simp [accepted, sepoliaEoaK1, defaultEoaK1, defaultEthereumPath, supportedChainId,
    compatible]

theorem sepoliaR1SmartAccepted :
    accepted sepoliaR1Smart = true := by
  simp [accepted, sepoliaR1Smart, defaultR1Smart, supportedChainId, compatible]

theorem mainnetR1SmartAccepted :
    accepted mainnetR1Smart = true := by
  simp [accepted, mainnetR1Smart, defaultR1Smart, supportedChainId, compatible]

theorem eoaK1UsesBip39WhenAccepted (p : AccountPolicy) :
    accepted p = true →
      p.kind = AccountKind.eoaK1 →
        p.source = KeySource.bip39Mnemonic := by
  intro h kindEq
  cases p with
  | mk kind source chainId path localOnly =>
    cases kind <;> cases source <;> cases path <;> cases localOnly <;>
      simp [accepted, compatible] at h kindEq ⊢

theorem r1SmartUsesLocalEnclaveWhenAccepted (p : AccountPolicy) :
    accepted p = true →
      p.kind = AccountKind.r1Smart →
        p.source = KeySource.localEnclave := by
  intro h kindEq
  cases p with
  | mk kind source chainId path localOnly =>
    cases kind <;> cases source <;> cases path <;> cases localOnly <;>
      simp [accepted, compatible] at h kindEq ⊢

end LeanKohaku.Invariants.Account
