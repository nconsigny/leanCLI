import LeanCli.Keystore.Enclave

/-!
# Linux keystore profile selection

Linux support starts with the common denominator across recent HP business
notebooks/workstations and Lenovo ThinkPad/ThinkCentre hardware: firmware TPM
2.0 for local P-256 signing, FIDO2 security keys as a hardware fallback, and
the kernel keyring only as a local handle store.

This module is still a pure model. It does not bind to TPM2, libfido2,
fprintd, D-Bus, or kernel APIs.
-/

namespace LeanCli.Keystore.Linux

open LeanCli.Keystore.Enclave

inductive Vendor where
  | hp
  | lenovo
  | generic
  deriving DecidableEq, Repr

inductive HardwareClass where
  | businessNotebook
  | mobileWorkstation
  | desktop
  | externalSecurityKeyOnly
  deriving DecidableEq, Repr

structure LinuxHardwareProfile where
  vendor             : Vendor
  hardwareClass      : HardwareClass
  hasTpm2            : Bool
  hasFido2           : Bool
  hasKernelKeyring   : Bool := true
  hasUserPresence    : Bool
  hasBiometricUnlock : Bool := false
  deriving Repr, DecidableEq

structure LinuxKeystoreSelection where
  signingPolicy : KeyPolicy
  handleStore   : Option Backend
  deriving Repr, DecidableEq

def LinuxHardwareProfile.backendAvailable
    (profile : LinuxHardwareProfile) : Backend → Bool
  | .linuxTpm2 => profile.hasTpm2
  | .fido2SecurityKey => profile.hasFido2
  | .linuxKernelKeyring => profile.hasKernelKeyring
  | _ => false

def LinuxHardwareProfile.authAvailable
    (profile : LinuxHardwareProfile) : UserAuth → Bool
  | .none => true
  | .userPresence => profile.hasUserPresence
  | .biometric => profile.hasBiometricUnlock

def LinuxHardwareProfile.signingAuth
    (profile : LinuxHardwareProfile) : Option UserAuth :=
  if profile.hasUserPresence then
    some .userPresence
  else if profile.hasBiometricUnlock then
    some .biometric
  else
    none

def canSignWith
    (profile : LinuxHardwareProfile)
    (backend : Backend)
    (curve : Curve)
    (auth : UserAuth) : Bool :=
  profile.backendAvailable backend &&
    backend.hardwareBacked &&
    backend.localOnly &&
    backend.supportsCurve curve &&
    profile.authAvailable auth &&
    auth.strongEnoughForSign

def selectSigningPolicy (profile : LinuxHardwareProfile) : Option KeyPolicy :=
  match profile.signingAuth with
  | none => none
  | some auth =>
      if canSignWith profile .linuxTpm2 .p256 auth then
        some (hardwarePolicy .linuxTpm2 auth)
      else if canSignWith profile .fido2SecurityKey .p256 auth then
        some (hardwarePolicy .fido2SecurityKey auth)
      else
        none

def selectHandleStore (profile : LinuxHardwareProfile) : Option Backend :=
  if profile.hasKernelKeyring then
    some .linuxKernelKeyring
  else
    none

def selectKeystore (profile : LinuxHardwareProfile) : Option LinuxKeystoreSelection :=
  match selectSigningPolicy profile with
  | none => none
  | some policy =>
      some { signingPolicy := policy, handleStore := selectHandleStore profile }

def hpBusinessNotebook : LinuxHardwareProfile :=
  { vendor := .hp,
    hardwareClass := .businessNotebook,
    hasTpm2 := true,
    hasFido2 := false,
    hasKernelKeyring := true,
    hasUserPresence := true,
    hasBiometricUnlock := false }

def hpMobileWorkstation : LinuxHardwareProfile :=
  { hpBusinessNotebook with hardwareClass := .mobileWorkstation }

def lenovoThinkPad : LinuxHardwareProfile :=
  { vendor := .lenovo,
    hardwareClass := .businessNotebook,
    hasTpm2 := true,
    hasFido2 := false,
    hasKernelKeyring := true,
    hasUserPresence := true,
    hasBiometricUnlock := false }

def lenovoThinkCentre : LinuxHardwareProfile :=
  { lenovoThinkPad with hardwareClass := .desktop }

def genericFido2Only : LinuxHardwareProfile :=
  { vendor := .generic,
    hardwareClass := .externalSecurityKeyOnly,
    hasTpm2 := false,
    hasFido2 := true,
    hasKernelKeyring := true,
    hasUserPresence := true,
    hasBiometricUnlock := false }

def commonHpLenovoProfiles : List LinuxHardwareProfile :=
  [hpBusinessNotebook, hpMobileWorkstation, lenovoThinkPad, lenovoThinkCentre]

theorem hpBusinessNotebook_selects_tpm2 :
    selectSigningPolicy hpBusinessNotebook = some linuxTpm2Policy := by
  rfl

theorem hpMobileWorkstation_selects_tpm2 :
    selectSigningPolicy hpMobileWorkstation = some linuxTpm2Policy := by
  rfl

theorem lenovoThinkPad_selects_tpm2 :
    selectSigningPolicy lenovoThinkPad = some linuxTpm2Policy := by
  rfl

theorem lenovoThinkCentre_selects_tpm2 :
    selectSigningPolicy lenovoThinkCentre = some linuxTpm2Policy := by
  rfl

theorem genericFido2Only_selects_fido2 :
    selectSigningPolicy genericFido2Only = some linuxFido2Policy := by
  rfl

theorem kernelKeyring_is_handle_store_only :
    selectHandleStore hpBusinessNotebook = some Backend.linuxKernelKeyring := by
  rfl

end LeanCli.Keystore.Linux
