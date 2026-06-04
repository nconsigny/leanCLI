import LeanCli.Keystore.Enclave
import LeanCli.Keystore.Linux

/-!
# Keystore invariants

The wallet-facing local keystore API must preserve a simple boundary:
private key material is never exported or imported through normal
operations, and P-256/R1 signing requires a local hardware-backed backend
plus user authorization.
-/

namespace LeanCli.Invariants.Keystore

open LeanCli.Keystore.Enclave
open LeanCli.Keystore.Linux

theorem acceptedNeverExportsSecrets (req : Request) :
    policyAccepts req = true →
      req.op ≠ Operation.exportSecret ∧ req.op ≠ Operation.importSecret := by
  intro h
  cases req with
  | mk op policy =>
    cases op <;> cases policy <;>
      simp [policyAccepts, noSecretExport] at h ⊢

theorem acceptedRequiresHardwareBackend (req : Request) :
    policyAccepts req = true → req.policy.backend.hardwareBacked = true := by
  intro h
  cases req with
  | mk op policy =>
    cases op <;> cases policy <;> cases ‹Curve› <;> cases ‹Backend› <;> cases ‹Locality› <;>
      cases ‹UserAuth› <;> cases ‹Bool› <;> cases ‹Bool› <;>
        simp [policyAccepts, Backend.hardwareBacked, Backend.localOnly,
          Backend.supportsCurve, UserAuth.strongEnoughForSign, noSecretExport] at h ⊢

theorem acceptedRequiresLocalOnly (req : Request) :
    req.policy.locality = Locality.localOnly := by
  cases req with
  | mk op policy =>
    cases policy with
    | mk curve backend locality requiredAuth exportable allowSoftwareFallback =>
      cases locality
      rfl

theorem acceptedSigningRequiresUserAuth (policy : KeyPolicy) :
    policyAccepts { op := Operation.signDigest, policy := policy } = true →
      policy.requiredAuth = UserAuth.biometric ∨
        policy.requiredAuth = UserAuth.userPresence := by
  intro h
  cases policy with
  | mk curve backend locality requiredAuth exportable allowSoftwareFallback =>
    cases curve <;> cases backend <;> cases locality <;> cases requiredAuth <;>
      simp [policyAccepts, UserAuth.strongEnoughForSign,
        Backend.hardwareBacked, Backend.localOnly, Backend.supportsCurve, noSecretExport] at h ⊢

theorem appleSecureEnclaveAcceptsEthereumR1Signing :
    policyAccepts
      { op := Operation.signDigest, policy := appleEthereumR1Policy } = true := by
  simp [policyAccepts, appleEthereumR1Policy, hardwarePolicy, Backend.hardwareBacked,
    Backend.localOnly, Backend.supportsCurve, UserAuth.strongEnoughForSign, noSecretExport]

theorem ethereumR1HardwareSigningAccepted :
    policyAccepts { op := Operation.signDigest, policy := ethereumR1HardwarePolicy } = true := by
  simp [policyAccepts, ethereumR1HardwarePolicy, hardwarePolicy, Backend.hardwareBacked,
    Backend.localOnly, Backend.supportsCurve, UserAuth.strongEnoughForSign, noSecretExport]

theorem appleNativeP256SigningAccepted :
    policyAccepts { op := Operation.signDigest, policy := appleNativePolicy } = true := by
  simp [policyAccepts, appleNativePolicy, hardwarePolicy, Backend.hardwareBacked,
    Backend.localOnly, Backend.supportsCurve, UserAuth.strongEnoughForSign, noSecretExport]

theorem linuxHpBusinessNotebookSelectsTpm2 :
    selectSigningPolicy hpBusinessNotebook = some linuxTpm2Policy := by
  rfl

theorem linuxHpMobileWorkstationSelectsTpm2 :
    selectSigningPolicy hpMobileWorkstation = some linuxTpm2Policy := by
  rfl

theorem linuxLenovoThinkPadSelectsTpm2 :
    selectSigningPolicy lenovoThinkPad = some linuxTpm2Policy := by
  rfl

theorem linuxLenovoThinkCentreSelectsTpm2 :
    selectSigningPolicy lenovoThinkCentre = some linuxTpm2Policy := by
  rfl

theorem linuxFido2FallbackSelectsFido2 :
    selectSigningPolicy genericFido2Only = some linuxFido2Policy := by
  rfl

theorem linuxKernelKeyringIsHandleStoreOnly :
    selectHandleStore hpBusinessNotebook = some Backend.linuxKernelKeyring := by
  rfl

end LeanCli.Invariants.Keystore
