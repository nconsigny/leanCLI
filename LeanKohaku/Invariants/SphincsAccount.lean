import LeanKohaku.Contract.SphincsAccount

/-!
# Sphincs hybrid account invariants

Properties the on-chain `SphincsAccount` must satisfy.  These mirror the
R1-account invariants for chain restriction and nonce monotonicity, plus
hybrid-specific invariants:

* both signature halves verify against the **pre-state** keys (12.3);
* the three payloads each preserve exactly the half of the key material
  they don't rotate (12.4);
* `rotateOwner` rejects address-zero (12.5);
* after a successful rotation, signing under the previous keys can no
  longer produce an accepted op — this is the load-bearing recovery
  property (12.6, 12.7).

Modeling `VerifyOracle.sphincsVerify` and `VerifyOracle.ecdsaRecover` as
*pure functions* is what makes 12.6/12.7 statable: an oracle is committed
to its `(keys, digest, sig) → bool` mapping, so a subsequent op simply
cannot be accepted by the oracle's "old-keys" branch.
-/

namespace LeanKohaku.Invariants.SphincsAccount

open LeanKohaku.Contract.SphincsAccount
open LeanKohaku.Ethereum.P256Precompile

/-- 12.1 — accepted ops use a wallet-supported chain id. -/
theorem applySomeSupportedChainOnly
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' → supportedChainId op.chainId = true := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    exact ok.left
  · simp [ok] at h

/-- 12.2a — accepted ops consume the current nonce. -/
theorem applySomeConsumesCurrentNonce
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' → op.nonce = st.nonce := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    exact ok.right.left
  · simp [ok] at h

/-- 12.2b — accepted ops advance the nonce by exactly one. -/
theorem applySomeIncrementsNonce
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' → st'.nonce = st.nonce + 1 := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    rw [← h]
  · simp [ok] at h

/-- 12.3a — every accepted op had ECDSA recover to the **pre-state**
    `owner`.  A break of SPHINCS+ alone cannot forge an op. -/
theorem applySomeEcdsaRecoversToOwner
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' →
      verify.ecdsaRecover op.digest op.ecdsaSig = some st.key.owner := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    exact ok.right.right.left.left
  · simp [ok] at h

/-- 12.3b — every accepted op had the SPHINCS+ verifier accept against
    the **pre-state** `(pkSeed, pkRoot)`.  A break of ECDSA alone cannot
    forge an op. -/
theorem applySomePqVerifies
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' →
      verify.sphincsVerify st.key.pkSeed st.key.pkRoot op.digest op.sphincsSig = true := by
  intro h
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    exact ok.right.right.left.right
  · simp [ok] at h

/-- 12.4a — `regular` payloads preserve all three key fields. -/
theorem applyRegularKeysUnchanged
    (st st' : State) (op : UserOperation) (verify : VerifyOracle) :
    apply st op verify = some st' →
      op.payload = Payload.regular →
      st'.key = st.key := by
  intro h hPayload
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    rw [← h]
    show applyPayload st.key op.payload = st.key
    rw [hPayload]
    rfl
  · simp [ok] at h

/-- 12.4b — `rotateKeys` payloads preserve the `owner`. -/
theorem applyRotateKeysPreservesOwner
    (st st' : State) (op : UserOperation) (verify : VerifyOracle)
    (newPkSeed newPkRoot : Bytes32) :
    apply st op verify = some st' →
      op.payload = Payload.rotateKeys newPkSeed newPkRoot →
      st'.key.owner = st.key.owner := by
  intro h hPayload
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    rw [← h]
    show (applyPayload st.key op.payload).owner = st.key.owner
    rw [hPayload]
    rfl
  · simp [ok] at h

/-- 12.4c — `rotateOwner` payloads preserve `pkSeed` and `pkRoot`. -/
theorem applyRotateOwnerPreservesKeys
    (st st' : State) (op : UserOperation) (verify : VerifyOracle)
    (newOwner : Address) :
    apply st op verify = some st' →
      op.payload = Payload.rotateOwner newOwner →
      st'.key.pkSeed = st.key.pkSeed ∧ st'.key.pkRoot = st.key.pkRoot := by
  intro h hPayload
  unfold apply at h
  by_cases ok : accepts st op verify
  · simp [ok] at h
    have hKey : st'.key = applyPayload st.key op.payload := by rw [← h]
    rw [hKey, hPayload]
    exact ⟨rfl, rfl⟩
  · simp [ok] at h

/-- 12.5 — `rotateOwner` rejects address-zero.  An op carrying the
    `rotateOwner addressZero` payload can never produce `some _`. -/
theorem applyRotateOwnerNonZero
    (st : State) (op : UserOperation) (verify : VerifyOracle) :
    op.payload = Payload.rotateOwner addressZero →
      apply st op verify = none := by
  intro hPayload
  unfold apply
  by_cases ok : accepts st op verify
  · -- Acceptance includes `payloadOk op.payload`, which for
    -- `rotateOwner addressZero` reduces to `addressZero ≠ addressZero`.
    exfalso
    have hPok : payloadOk op.payload := ok.right.right.right
    rw [hPayload] at hPok
    exact hPok rfl
  · simp [ok]

/-- 12.6 — **PQ key supersession.**  After a successful op the next op
    that succeeds must SPHINCS+-verify against the **post-state**
    `(pkSeed, pkRoot)`.  Combined with `applySomePqVerifies`, this means
    an oracle that only accepts the previous keys cannot accept any op
    after a rotation: the verifier reads post-rotation keys.  This makes
    `rotateKeys` an actual recovery primitive against PQ-key compromise. -/
theorem applyRotateKeysSupersedesOldPq
    (st st' st'' : State) (op1 op2 : UserOperation) (verify : VerifyOracle)
    (newPkSeed newPkRoot : Bytes32) :
    apply st op1 verify = some st' →
      op1.payload = Payload.rotateKeys newPkSeed newPkRoot →
      apply st' op2 verify = some st'' →
        verify.sphincsVerify newPkSeed newPkRoot op2.digest op2.sphincsSig = true := by
  intro h1 hRot h2
  -- After the rotation, st'.key.pkSeed = newPkSeed and st'.key.pkRoot = newPkRoot.
  have hSeed : st'.key.pkSeed = newPkSeed := by
    unfold apply at h1
    by_cases ok : accepts st op1 verify
    · simp [ok] at h1
      rw [← h1]
      show (applyPayload st.key op1.payload).pkSeed = newPkSeed
      rw [hRot]
      rfl
    · simp [ok] at h1
  have hRoot : st'.key.pkRoot = newPkRoot := by
    unfold apply at h1
    by_cases ok : accepts st op1 verify
    · simp [ok] at h1
      rw [← h1]
      show (applyPayload st.key op1.payload).pkRoot = newPkRoot
      rw [hRot]
      rfl
    · simp [ok] at h1
  -- The follow-up op verifies against the post-state keys.
  have hPq := applySomePqVerifies st' st'' op2 verify h2
  rw [hSeed, hRoot] at hPq
  exact hPq

/-- 12.7 — **Owner rotation supersession.**  Symmetric to 12.6: after a
    successful `rotateOwner`, the next accepted op must ECDSA-recover to
    the new owner.  An attacker holding only the previous owner's ECDSA
    key cannot produce a further accepted op. -/
theorem applyRotateOwnerSupersedesOldOwner
    (st st' st'' : State) (op1 op2 : UserOperation) (verify : VerifyOracle)
    (newOwner : Address) :
    apply st op1 verify = some st' →
      op1.payload = Payload.rotateOwner newOwner →
      apply st' op2 verify = some st'' →
        verify.ecdsaRecover op2.digest op2.ecdsaSig = some newOwner := by
  intro h1 hRot h2
  have hOwner : st'.key.owner = newOwner := by
    unfold apply at h1
    by_cases ok : accepts st op1 verify
    · simp [ok] at h1
      rw [← h1]
      show (applyPayload st.key op1.payload).owner = newOwner
      rw [hRot]
      rfl
    · simp [ok] at h1
  have hEc := applySomeEcdsaRecoversToOwner st' st'' op2 verify h2
  rw [hOwner] at hEc
  exact hEc

end LeanKohaku.Invariants.SphincsAccount
