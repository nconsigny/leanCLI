import LeanKohaku.Ethereum.P256Precompile

/-!
# Sphincs hybrid ECDSA + post-quantum account contract model

Abstract Lean model that mirrors the on-chain `SphincsAccount` contract — a
generic ERC-4337 hybrid account that gates every UserOp on **both**:

1. ECDSA recovery to a stored, rotatable `owner` address;
2. a stateless SPHINCS+ verifier (delegated by `staticcall` to a shared
   verifier contract) keyed by a stored, rotatable `(pkSeed, pkRoot)` pair.

The verifier contract address is part of the deployed account's immutable
configuration, so all parameter-set selection is _outside_ the abstract
model: the user's local signer must produce signatures that match the
parameter set the deployed verifier accepts. The Lean model abstracts the
PQ verifier as a pure boolean function of `(pkSeed, pkRoot, digest, sig)`,
which is the actual semantics of stateless SPHINCS+ and is what makes
key-rotation a meaningful recovery primitive.

The contract exposes three callable shapes that we model as three
`UserOperation` constructors:

* `regular` — generic call (`to`, `value`, `data`); keys unchanged.
* `rotateKeys` — replaces `(pkSeed, pkRoot)`; owner unchanged.
* `rotateOwner` — replaces `owner`; keys unchanged. Rejects address zero.

Both signature halves are checked against the **pre-state** keys: the new
keys do not become active until the next op. This matches the contract's
`_validateSignature` reading `owner`/`pkSeed`/`pkRoot` before any rotation
takes effect.

Out of scope for this Phase 1 model: EVM call body interpretation, gas
accounting, and the slot/sub-key state machinery from the unrelated JARDIN
variant. This file is deliberately simpler than the previous JARDIN draft.
-/

namespace LeanKohaku.Contract.SphincsAccount

open LeanKohaku.Ethereum.P256Precompile

/-- Ethereum address as `Nat` for proof tractability.  Wallet/Ethereum
    types elsewhere refine this to a 20-byte representation. -/
abbrev Address := Nat

/-- Address-zero, used by `rotateOwner` to reject the unowned account state. -/
def addressZero : Address := 0

/-- 32-byte field, modelled as `Nat`.  Matches the shape used for R1
    public-key coordinates in `Contract/R1Account.lean`; refinement to a
    fixed-width byte vector is a future concern. -/
abbrev Bytes32 := Nat

/-- Public on-chain key material for the hybrid account. -/
structure PublicKey where
  /-- ECDSA signer address; rotatable via `rotateOwner`. -/
  owner  : Address
  /-- SPHINCS+ public seed; rotatable via `rotateKeys`. -/
  pkSeed : Bytes32
  /-- SPHINCS+ Merkle root; rotatable via `rotateKeys`. -/
  pkRoot : Bytes32
  deriving Repr, DecidableEq

/-- Per-op payload.  The contract's discriminator is the calldata target
    (`address(this)` + selector) — we model the three shapes the contract
    cares about explicitly so the abstract layer doesn't need an EVM
    interpreter. -/
inductive Payload where
  /-- Generic outbound call.  The body (`to`/`value`/`data`) does not
      affect verification or rotation, so it is opaque here. -/
  | regular
  /-- Self-call to `rotateKeys(bytes32,bytes32)`. -/
  | rotateKeys (newPkSeed newPkRoot : Bytes32)
  /-- Self-call to `rotateOwner(address)`. -/
  | rotateOwner (newOwner : Address)
  deriving Repr, DecidableEq

/-- ERC-4337 UserOperation, abstracted to the fields verification reads
    plus the payload distinguishing rotation from regular calls. -/
structure UserOperation where
  chainId : Nat
  nonce   : Nat
  /-- The hashed digest the signature commits to (the contract's
      `userOpHash`). -/
  digest  : Bytes32
  ecdsaSig   : ByteArray
  sphincsSig : ByteArray
  payload    : Payload

/-- Account state.  The supported-chain set is global (see
    `P256Precompile.supportedChainId`); per-account chain pinning is a
    deployment concern outside this model. -/
structure State where
  key   : PublicKey
  nonce : Nat

/-- Hybrid verification oracle.  Both halves are *pure functions* of their
    inputs, which matches the real semantics — ECDSA recovery and stateless
    SPHINCS+ verify are both deterministic — and is what lets us state the
    key-rotation supersession invariants (12.6, 12.7).

    Modeling these as functions rather than opaque relations is a
    deliberate strengthening over the previous JARDIN draft: it forces the
    oracle to commit to "this signature against these keys yields this
    boolean", so an oracle that accepted the old keys cannot retroactively
    accept new ones. -/
structure VerifyOracle where
  /-- ECDSA-recover the signer address from a digest and signature.  The
      contract uses OpenZeppelin's `ECDSA.recover`; the abstract layer
      cares only about the recovered address. -/
  ecdsaRecover  : Bytes32 → ByteArray → Option Address
  /-- Stateless SPHINCS+ `verify(pkSeed, pkRoot, digest, sig)`.  Pure and
      total: the verifier contract is a `staticcall` and returns a single
      bool. -/
  sphincsVerify : Bytes32 → Bytes32 → Bytes32 → ByteArray → Bool

/-- Hybrid signature gate, mirroring the contract's `_validateSignature`:
    ECDSA must recover **exactly** to the current `owner`, AND the SPHINCS+
    verifier must accept against the current `(pkSeed, pkRoot)`. -/
def hybridValid (st : State) (op : UserOperation) (verify : VerifyOracle) : Prop :=
  verify.ecdsaRecover op.digest op.ecdsaSig = some st.key.owner ∧
    verify.sphincsVerify st.key.pkSeed st.key.pkRoot op.digest op.sphincsSig = true

/-- The `rotateOwner(address)` self-call rejects address-zero in the
    contract.  We hoist that here so it is visible to proofs. -/
def payloadOk : Payload → Prop
  | .regular              => True
  | .rotateKeys _ _       => True
  | .rotateOwner newOwner => newOwner ≠ addressZero

/-- Combined acceptance gate. -/
def accepts (st : State) (op : UserOperation) (verify : VerifyOracle) : Prop :=
  supportedChainId op.chainId = true ∧
    op.nonce = st.nonce ∧
    hybridValid st op verify ∧
    payloadOk op.payload

/-- Apply the payload to the post-acceptance state.  Rotation replaces
    only the rotated half of the key material; nonce always advances. -/
def applyPayload (key : PublicKey) : Payload → PublicKey
  | .regular                         => key
  | .rotateKeys newPkSeed newPkRoot  => { key with pkSeed := newPkSeed, pkRoot := newPkRoot }
  | .rotateOwner newOwner            => { key with owner := newOwner }

/-- State transition.  `none` for any rejected op; on acceptance the nonce
    advances by one and the payload's rotation (if any) takes effect. -/
noncomputable def apply
    (st : State) (op : UserOperation) (verify : VerifyOracle) : Option State :=
  by
    classical
    exact
      if accepts st op verify then
        some { key := applyPayload st.key op.payload, nonce := st.nonce + 1 }
      else
        none

end LeanKohaku.Contract.SphincsAccount
