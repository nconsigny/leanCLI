import LeanCli.Crypto.Secp256k1

/-!
# Local enclave-backed keystore model

The wallet should never handle raw private keys in normal operation. This
module models a keystore boundary where key generation, public-key export,
and signing are delegated to a local platform/hardware backend.

This is not an online keystore. All accepted backends represent local OS,
local hardware, or local-device IPC boundaries. Remote custody and remote
signing services are intentionally absent.

The model is deliberately dependency-free: it describes policy decisions,
not runtime bindings to TPM2, FIDO2, Secure Enclave, or kernel APIs.

Ethereum mainnet support is modeled through P-256/R1 signatures verified
onchain by account logic that uses the P256VERIFY precompile. This keeps
the local hardware key native to TPM/FIDO/Secure Enclave devices.
-/

namespace LeanCli.Keystore.Enclave

open LeanCli.Crypto.Secp256k1

inductive Platform where
  | linux
  | macOS
  | iOS
  deriving DecidableEq, Repr

inductive Backend where
  | linuxKernelKeyring
  | linuxTpm2
  | fido2SecurityKey
  | appleSecureEnclave
  | externalHardwareWallet
  | softwareDevOnly
  deriving DecidableEq, Repr

inductive Locality where
  | localOnly
  deriving DecidableEq, Repr

inductive Curve where
  | p256
  deriving DecidableEq, Repr

inductive UserAuth where
  | none
  | userPresence
  | biometric
  deriving DecidableEq, Repr

inductive Operation where
  | createKey
  | publicKey
  | signDigest
  | deleteKey
  | exportSecret
  | importSecret
  deriving DecidableEq, Repr

structure KeyRef where
  id       : String
  platform : Platform
  backend  : Backend
  curve    : Curve
  deriving Repr, DecidableEq

structure KeyPolicy where
  curve                 : Curve
  backend               : Backend
  locality              : Locality := .localOnly
  requiredAuth          : UserAuth
  exportable            : Bool := false
  allowSoftwareFallback : Bool := false
  deriving Repr, DecidableEq

structure Request where
  op     : Operation
  policy : KeyPolicy
  deriving Repr, DecidableEq

/-- Abstract signature result; backend implementations fill in real bytes later. -/
structure EnclaveSignature where
  key : KeyRef
  sig : Signature
  deriving Repr, DecidableEq

def Backend.hardwareBacked : Backend → Bool
  | .linuxKernelKeyring => false
  | .linuxTpm2 => true
  | .fido2SecurityKey => true
  | .appleSecureEnclave => true
  | .externalHardwareWallet => true
  | .softwareDevOnly => false

def Backend.localOnly : Backend → Bool
  | .linuxKernelKeyring => true
  | .linuxTpm2 => true
  | .fido2SecurityKey => true
  | .appleSecureEnclave => true
  | .externalHardwareWallet => true
  | .softwareDevOnly => true

/--
Capability table for the wallet policy layer.

This table is deliberately local-only. It models hardware that can hold
P-256/R1 keys and sign locally without exporting private material. The Linux
kernel keyring is modeled as a local handle store, not as a hardware signer.
-/
def Backend.supportsCurve : Backend → Curve → Bool
  | .linuxTpm2, .p256 => true
  | .fido2SecurityKey, .p256 => true
  | .appleSecureEnclave, .p256 => true
  | .externalHardwareWallet, .p256 => true
  | _, _ => false

def UserAuth.strongEnoughForSign : UserAuth → Bool
  | .biometric => true
  | .userPresence => true
  | .none => false

def noSecretExport : Operation → Bool
  | .exportSecret => false
  | .importSecret => false
  | _ => true

def policyAccepts (req : Request) : Bool :=
  req.policy.backend.hardwareBacked &&
    req.policy.backend.localOnly &&
    decide (req.policy.locality = Locality.localOnly) &&
    req.policy.backend.supportsCurve req.policy.curve &&
    !req.policy.exportable &&
    !req.policy.allowSoftwareFallback &&
    noSecretExport req.op &&
    match req.op with
    | .signDigest => req.policy.requiredAuth.strongEnoughForSign
    | _ => true

def hardwarePolicy (backend : Backend) (auth : UserAuth) : KeyPolicy :=
  { curve := .p256,
    backend := backend,
    locality := .localOnly,
    requiredAuth := auth,
    exportable := false,
    allowSoftwareFallback := false }

def linuxTpm2Policy : KeyPolicy :=
  hardwarePolicy .linuxTpm2 .userPresence

def linuxFido2Policy : KeyPolicy :=
  hardwarePolicy .fido2SecurityKey .userPresence

def ethereumR1HardwarePolicy : KeyPolicy :=
  hardwarePolicy .externalHardwareWallet .userPresence

def appleNativePolicy : KeyPolicy :=
  hardwarePolicy .appleSecureEnclave .biometric

def appleEthereumR1Policy : KeyPolicy :=
  hardwarePolicy .appleSecureEnclave .biometric

end LeanCli.Keystore.Enclave
