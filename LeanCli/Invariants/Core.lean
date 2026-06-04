import LeanCli.Core

/-!
# Core wallet safety invariants
-/

namespace LeanCli.Invariants.Core

open LeanCli.Core
open LeanCli.Ethereum.P256Precompile

theorem no_key_exfiltration (out : Output) :
    containsPrivateKeyMaterial out = false := by
  cases out <;> rfl

theorem verified_no_raw_signing {s : State} {intent : Intent} :
    verifiedIntent s intent → intent.rawSigning = false := by
  intro h
  rcases h with ⟨_supported, _selected, _rpc, _approved, rawOk, _key, _tpm, _delegation⟩
  exact rawOk

theorem verified_wrong_chain_impossible {s : State} {intent : Intent} :
    verifiedIntent s intent →
      supportedChainId intent.chainId = true ∧ intent.chainId = s.selectedChain := by
  intro h
  rcases h with ⟨supported, selected, _rpc, _approved, _raw, _key, _tpm, _delegation⟩
  exact ⟨supported, selected⟩

theorem verified_rpc_chain_matches {s : State} {intent : Intent} :
    verifiedIntent s intent → intent.rpcChainId = some intent.chainId := by
  intro h
  rcases h with ⟨_supported, _selected, rpcOk, _approved, _raw, _key, _tpm, _delegation⟩
  exact rpcOk

theorem verified_requires_approval {s : State} {intent : Intent} :
    verifiedIntent s intent → intent.approved = true := by
  intro h
  rcases h with ⟨_supported, _selected, _rpc, approvedOk, _raw, _key, _tpm, _delegation⟩
  exact approvedOk

theorem verified_signer_path_separation {s : State} {intent : Intent} :
    verifiedIntent s intent → intent.keyRef.kind = intent.signerKind := by
  intro h
  rcases h with ⟨_supported, _selected, _rpc, _approved, _raw, keyOk, _tpm, _delegation⟩
  exact keyOk

theorem verified_r1_requires_tpm_policy {s : State} {intent : Intent} :
    verifiedIntent s intent →
      intent.signerKind = SignerKind.r1 →
        ∃ policy, intent.tpmPolicy = some policy ∧ policy.satisfied = true := by
  intro h signerEq
  rcases h with ⟨_supported, _selected, _rpc, _approved, _raw, _key, tpmOk, _delegation⟩
  unfold tpmPolicySatisfied at tpmOk
  rw [signerEq] at tpmOk
  cases hp : intent.tpmPolicy with
  | none =>
      simp [hp] at tpmOk
  | some policy =>
      simp [hp] at tpmOk ⊢
      exact tpmOk

theorem signIntent_verified
    {s s' : State} {intent : Intent} {kind : SignerKind} {scheme : SignatureScheme} :
    signIntent s intent kind = .ok (s', Output.signature scheme intent) →
      verifiedIntent s intent := by
  intro h
  unfold signIntent at h
  by_cases ok : verifiedIntent s intent ∧ intent.signerKind = kind
  · simp [ok] at h
    exact ok.1
  · simp [ok] at h

theorem signEOA_verified
    {s s' : State} {intent : Intent} {scheme : SignatureScheme} :
    step s (Command.SignEOA intent) = .ok (s', Output.signature scheme intent) →
      verifiedIntent s intent := by
  intro h
  exact signIntent_verified h

theorem signR1_verified
    {s s' : State} {intent : Intent} {scheme : SignatureScheme} :
    step s (Command.SignR1 intent) = .ok (s', Output.signature scheme intent) →
      verifiedIntent s intent := by
  intro h
  exact signIntent_verified h

theorem signEOA_uses_secp256k1
    {s s' : State} {intent : Intent} {scheme : SignatureScheme} :
    step s (Command.SignEOA intent) = .ok (s', Output.signature scheme intent) →
      scheme = SignatureScheme.secp256k1 := by
  intro h
  unfold step signIntent at h
  by_cases ok : verifiedIntent s intent ∧ intent.signerKind = SignerKind.eoa
  · simp [ok, schemeForKind] at h
    exact h.2.symm
  · simp [ok] at h

theorem signR1_uses_p256
    {s s' : State} {intent : Intent} {scheme : SignatureScheme} :
    step s (Command.SignR1 intent) = .ok (s', Output.signature scheme intent) →
      scheme = SignatureScheme.p256 := by
  intro h
  unfold step signIntent at h
  by_cases ok : verifiedIntent s intent ∧ intent.signerKind = SignerKind.r1
  · simp [ok, schemeForKind] at h
    exact h.2.symm
  · simp [ok] at h

theorem no_silent_7702_delegation {s : State} {intent : Intent} :
    verifiedIntent s intent →
      intent.is7702 = true →
        intent.delegateApproved = true ∧ intent.chainId ≠ 0 := by
  intro h h7702
  rcases h with ⟨_supported, _selected, _rpc, _approved, _raw, _key, _tpm, delegationOk⟩
  simp [delegationPolicySatisfied, h7702] at delegationOk
  exact delegationOk

end LeanCli.Invariants.Core
