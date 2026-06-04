import LeanCli.Ethereum.P256Precompile

/-!
# R1 account contract model

This is the Lean-level account logic we want to compile with Verity once
the dependency/toolchain boundary is settled. It keeps the wallet-specific
policy in Lean and treats EIP-7951 `P256VERIFY` as the precompile boundary.

The intended Verity shape is:
* store P-256 public key coordinates and nonce;
* build the 160-byte EIP-7951 input `h || r || s || qx || qy`;
* `staticcall` precompile `0x100` with 6900 gas;
* accept only the 32-byte success word;
* increment nonce exactly once for accepted operations.
-/

namespace LeanCli.Contract.R1Account

open LeanCli.Ethereum.P256Precompile

structure PublicKey where
  qx : Nat
  qy : Nat
  deriving Repr, DecidableEq

structure Signature where
  r : Nat
  s : Nat
  deriving Repr, DecidableEq

structure UserOperation where
  chainId : Nat
  nonce   : Nat
  digest  : Nat
  sig     : Signature
  deriving Repr, DecidableEq

structure State where
  key   : PublicKey
  nonce : Nat
  deriving Repr, DecidableEq

def toPrecompileInput (key : PublicKey) (op : UserOperation) : VerifyScalars :=
  { h := op.digest, r := op.sig.r, s := op.sig.s, qx := key.qx, qy := key.qy }

/--
Abstract verifier hook. In a Verity contract this corresponds to a staticcall
to EIP-7951 `P256VERIFY`; in proofs we reason about the boolean result and
the account policy around it.
-/
def VerifyOracle := VerifyScalars → Bool

def validForSupportedChain (st : State) (op : UserOperation) (verify : VerifyOracle) : Prop :=
  supportedChainId op.chainId = true ∧
    op.nonce = st.nonce ∧
    validInput (toPrecompileInput st.key op) ∧
    verify (toPrecompileInput st.key op) = true

def accepts (st : State) (op : UserOperation) (verify : VerifyOracle) : Prop :=
  validForSupportedChain st op verify

noncomputable def apply (st : State) (op : UserOperation) (verify : VerifyOracle) : Option State :=
  by
    classical
    exact
      if accepts st op verify then
        some { st with nonce := st.nonce + 1 }
      else
        none

end LeanCli.Contract.R1Account
