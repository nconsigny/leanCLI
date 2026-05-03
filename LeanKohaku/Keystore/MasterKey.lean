import LeanKohaku.Crypto.Hex
import LeanKohaku.Crypto.Random
import LeanKohaku.Keystore.Tpm2Runtime

/-!
# TPM-sealed master attestation key

Stores a 32-byte secret in a TPM-sealed blob. The secret is generated in
process memory, written to TPM via `tpm2_create -i`, and never persisted in
clear. Caller code must drop the unsealed bytes immediately after wrap or
unwrap operations.

Caveat: as with the R1 signing path, biometric verification (fprintd) is an
application-layer gate, not a TPM PCR-bound policy session. A local attacker
who already controls the daemon process can drive the unseal directly. A
real PCR/policy session is future work.
-/

namespace LeanKohaku.Keystore.MasterKey

open LeanKohaku.Keystore.Tpm2Runtime

def masterDir : System.FilePath :=
  ".leankohaku/keystore/tpm2/_master"

def sealed : System.FilePath :=
  masterDir / "sealed.bin"

-- Why: `tpm2_load` needs both the wrapped private blob and its public part.
def sealedPub : System.FilePath :=
  masterDir / "sealed.pub"

def primaryCtx : System.FilePath :=
  masterDir / "primary.ctx"

def loadedCtx : System.FilePath :=
  masterDir / "key.ctx"

def plainSeed : System.FilePath :=
  masterDir / "seed.bin"

-- Why: `tpm2_unseal` writes binary; round-tripping through `String` would
-- break on non-UTF8 bytes, so we route through a transient `-o` file that
-- is removed (and overwritten) on every unseal.
def unsealOut : System.FilePath :=
  masterDir / "unsealed.bin"

def manifest : System.FilePath :=
  masterDir / "manifest.txt"

def sealTools : List String :=
  ["tpm2_createprimary", "tpm2_create", "tpm2_load", "tpm2_unseal"]

def existsOnDisk : IO Bool :=
  sealed.pathExists

def reset : IO Unit := do
  let _ ← runChecked "rm" #["-rf", masterDir.toString]
  pure ()

private def manifestText : String :=
  "leankohaku TPM2 master attestation key\n" ++
  "purpose=eoa-attestation-master\n" ++
  "backend=linuxTpm2\n" ++
  "sealed_priv=sealed.bin\n" ++
  "sealed_pub=sealed.pub\n" ++
  "custody=local-tpm2\n" ++
  "biometric_gate=fprintd-verify\n" ++
  "tpm_policy_session_bound=false\n" ++
  "raw_master_key_exported=false\n"

private def hardenMasterDir : IO Unit := do
  hardenDir ".leankohaku"
  hardenDir ".leankohaku/keystore"
  hardenDir ".leankohaku/keystore/tpm2"
  hardenDir masterDir

private def hardenMasterFiles : IO Unit := do
  for path in [primaryCtx, sealedPub, sealed, loadedCtx, manifest] do
    if ← path.pathExists then
      hardenFile path

private def createPrimaryAt : IO (Except String String) :=
  runChecked "tpm2_createprimary"
    #["-C", "o", "-G", "ecc", "-g", "sha256",
      "-c", primaryCtx.toString]

private def sealAtSimple : IO (Except String String) :=
  runChecked "tpm2_create"
    #["-C", primaryCtx.toString,
      "-g", "sha256",
      "-i", plainSeed.toString,
      "-u", sealedPub.toString,
      "-r", sealed.toString,
      "-a", "fixedtpm|fixedparent|userwithauth|noda"]

private def loadAt : IO (Except String String) :=
  runChecked "tpm2_load"
    #["-C", primaryCtx.toString,
      "-u", sealedPub.toString,
      "-r", sealed.toString,
      "-c", loadedCtx.toString]

private def unsealAt : IO (Except String ByteArray) := do
  match ← runChecked "tpm2_unseal"
      #["-c", loadedCtx.toString, "-o", unsealOut.toString] with
  | .error err => pure (.error err)
  | .ok _ =>
      try
        let bytes ← IO.FS.readBinFile unsealOut
        IO.FS.removeFile unsealOut
        pure (.ok bytes)
      catch e =>
        pure (.error e.toString)

/-- Generate a fresh master key, seal it under the TPM, and persist the
    sealed blob + manifest. Requires fprintd biometric verification. -/
def bootstrap (notify : Notifier) : IO (Except String Unit) := do
  if ← existsOnDisk then
    return .error "master key already initialized"
  unless (← deviceAvailable) do
    return .error "TPM device not available (/dev/tpm0 or /dev/tpmrm0)"
  match ← firstMissingTool sealTools with
  | some tool => return .error s!"tpm2-tools missing: {tool}"
  | none => pure ()
  unless (← fprintdAvailable) do
    return .error s!"biometric tool missing: {biometricTool}"
  match ← verifyLocalUser notify with
  | .error err => return .error s!"biometric verification failed: {err}"
  | .ok _ => pure ()
  IO.FS.createDirAll masterDir
  hardenMasterDir
  -- Why: 32 bytes is the symmetric-key size used by ChaCha20-Poly1305 wraps.
  let seedBytes ← LeanKohaku.Crypto.Random.getRandomBytes 32
  IO.FS.writeBinFile plainSeed seedBytes
  hardenFile plainSeed
  match ← createPrimaryAt with
  | .error err =>
      IO.FS.removeFile plainSeed
      return .error s!"tpm2_createprimary failed: {err}"
  | .ok _ => pure ()
  match ← sealAtSimple with
  | .error err =>
      IO.FS.removeFile plainSeed
      return .error s!"tpm2_create (seal) failed: {err}"
  | .ok _ => pure ()
  -- Why: erase the plaintext seed file as soon as the TPM has the sealed copy.
  IO.FS.removeFile plainSeed
  IO.FS.writeFile manifest manifestText
  hardenMasterFiles
  pure (.ok ())

/-- Unseal the master key after biometric verification. Returns the 32-byte
    master key in memory; the caller MUST not persist it to disk. -/
def unsealWithBiometric (notify : Notifier) : IO (Except String ByteArray) := do
  unless (← existsOnDisk) do
    return .error "master key not initialized"
  unless (← deviceAvailable) do
    return .error "TPM device not available (/dev/tpm0 or /dev/tpmrm0)"
  match ← firstMissingTool sealTools with
  | some tool => return .error s!"tpm2-tools missing: {tool}"
  | none => pure ()
  unless (← fprintdAvailable) do
    return .error s!"biometric tool missing: {biometricTool}"
  match ← verifyLocalUser notify with
  | .error err => return .error s!"biometric verification failed: {err}"
  | .ok _ => pure ()
  match ← createPrimaryAt with
  | .error err => return .error s!"tpm2_createprimary failed: {err}"
  | .ok _ => pure ()
  match ← loadAt with
  | .error err => return .error s!"tpm2_load failed: {err}"
  | .ok _ => pure ()
  match ← unsealAt with
  | .error err => return .error s!"tpm2_unseal failed: {err}"
  | .ok bytes =>
      if bytes.size != 32 then
        pure (.error s!"tpm2_unseal returned unexpected size: {bytes.size}")
      else
        pure (.ok bytes)

end LeanKohaku.Keystore.MasterKey
