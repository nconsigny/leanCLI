import LeanCli.Ethereum.Chain

/-!
# Verified wallet core

The CLI, RPC, TPM, enclave, console, and network are runtime boundaries. This
module models the small core that decides whether a command may produce a
signature or broadcast request. Private keys are intentionally unrepresentable:
the core handles only key references and typed intents.
-/

namespace LeanCli.Core

open LeanCli.Ethereum.Chain

inductive SignerKind where
  | eoa
  deriving Repr, DecidableEq

inductive SignatureScheme where
  | secp256k1
  deriving Repr, DecidableEq

inductive TxType where
  | eip1559
  | eip7702
  deriving Repr, DecidableEq

inductive KeyRef where
  | eoa (derivationPath : String)
  deriving Repr, DecidableEq

def KeyRef.kind : KeyRef → SignerKind
  | .eoa _ => .eoa

def schemeForKind : SignerKind → SignatureScheme
  | .eoa => .secp256k1

structure Intent where
  chainId          : Nat
  txType           : TxType
  account          : String
  nonce            : Nat
  intentHash       : String
  signerKind       : SignerKind
  keyRef           : KeyRef
  approved         : Bool
  rpcChainId       : Option Nat
  rawSigning       : Bool := false
  is7702           : Bool := false
  delegateApproved : Bool := false
  deriving Repr, DecidableEq

structure State where
  selectedChain : Nat
  signed        : List Intent := []
  pending       : List Intent := []
  deriving Repr, DecidableEq

inductive Error where
  | unsupportedChain
  | chainMismatch
  | unverifiedIntent
  | wrongSignerPath
  deriving Repr, DecidableEq

inductive Output where
  | synced (chainId : Nat)
  | built (intent : Intent)
  | signature (scheme : SignatureScheme) (intent : Intent)
  | submitted (intent : Intent)
  | publicInfo (value : String)
  deriving Repr, DecidableEq

def containsPrivateKeyMaterial : Output → Bool
  | _ => false

/-- Local-key signing carries no hardware-policy precondition after the
    P-256/R1 enclave path was removed; this is constantly `true` for the
    sole `eoa` signer kind. Kept as a conjunct of `verifiedIntent` so the
    gate's shape is stable if a future hardware kind reintroduces a
    precondition. -/
def tpmPolicySatisfied (_intent : Intent) : Bool := true

def delegationPolicySatisfied (intent : Intent) : Bool :=
  if intent.is7702 then
    intent.delegateApproved && decide (intent.chainId ≠ 0)
  else
    true

def verifiedIntent (s : State) (intent : Intent) : Prop :=
  supportedChainId intent.chainId = true ∧
    intent.chainId = s.selectedChain ∧
    intent.rpcChainId = some intent.chainId ∧
    intent.approved = true ∧
    intent.rawSigning = false ∧
    intent.keyRef.kind = intent.signerKind ∧
    tpmPolicySatisfied intent = true ∧
    delegationPolicySatisfied intent = true

instance (s : State) (intent : Intent) : Decidable (verifiedIntent s intent) := by
  unfold verifiedIntent
  infer_instance

def signIntent (s : State) (intent : Intent) (kind : SignerKind) :
    Except Error (State × Output) :=
  if verifiedIntent s intent ∧ intent.signerKind = kind then
    let scheme := schemeForKind kind
    .ok ({ s with signed := intent :: s.signed }, .signature scheme intent)
  else
    .error .unverifiedIntent

inductive Command where
  | SyncChain (chainId : Nat)
  | BuildTx (intent : Intent)
  | SignEOA (intent : Intent)
  | Submit (intent : Intent)
  | Delegate7702 (intent : Intent)
  | ResetDelegation7702 (intent : Intent)
  | ExportPublicInfo
  deriving Repr, DecidableEq

def step (s : State) : Command → Except Error (State × Output)
  | .SyncChain chainId =>
      if supportedChainId chainId && decide (chainId = s.selectedChain) then
        .ok (s, .synced chainId)
      else
        .error .chainMismatch
  | .BuildTx intent =>
      if supportedChainId intent.chainId && decide (intent.chainId = s.selectedChain) then
        .ok (s, .built intent)
      else
        .error .unsupportedChain
  | .SignEOA intent =>
      signIntent s intent .eoa
  | .Submit intent =>
      if verifiedIntent s intent then
        .ok ({ s with pending := intent :: s.pending }, .submitted intent)
      else
        .error .unverifiedIntent
  | .Delegate7702 intent =>
      signIntent s { intent with is7702 := true } .eoa
  | .ResetDelegation7702 intent =>
      signIntent s { intent with is7702 := true, delegateApproved := true } .eoa
  | .ExportPublicInfo =>
      .ok (s, .publicInfo "public account metadata only")

end LeanCli.Core
