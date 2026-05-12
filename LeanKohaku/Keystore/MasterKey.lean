import LeanKohaku.Crypto.Hex
import LeanKohaku.Crypto.Random
import LeanKohaku.Keystore.Tpm2Runtime

/-!
# TPM-sealed master attestation key

Stores a 32-byte secret in a TPM-sealed blob. The secret is generated in
process memory, written to TPM via `tpm2_create -i`, and never persisted in
clear. Caller code must drop the unsealed bytes immediately after wrap or
unwrap operations.

The sealed object is created with a user-supplied PIN as its TPM auth value.
`tpm2_unseal -p file:<auth>` re-checks that PIN inside the TPM on every call,
and the TPM enforces dictionary-attack lockout in hardware — so a compromised
daemon process cannot brute-force the unseal even with kernel-mode access to
the TPM device, beyond the firmware-imposed retry rate.
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

-- Why: chmod-600 transient file holding the user's PIN bytes. We pass
-- `-p file:<path>` to tpm2-tools so the PIN never appears on argv.
def authFile : System.FilePath :=
  masterDir / "auth.tmp"

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
  "user_verification=tpm-auth-value\n" ++
  s!"user_verification_pin_min_length={minPinLength}\n" ++
  "user_verification_tpm_bound=true\n" ++
  "user_verification_dictionary_attack_protection=tpm-hardware\n" ++
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

/-- Write the PIN to the transient auth file with mode 600. -/
private def writeAuth (pin : String) : IO Unit := do
  IO.FS.writeBinFile authFile pin.toUTF8
  chmodPath "600" authFile

/-- Best-effort removal of the transient auth file. -/
private def clearAuth : IO Unit := do
  try
    if ← authFile.pathExists then
      IO.FS.removeFile authFile
  catch _ => pure ()

private def pinArg : String :=
  s!"file:{authFile.toString}"

private def containsCI (haystack needle : String) : Bool :=
  decide ((haystack.toLower.splitOn needle.toLower).length > 1)

private def isAuthFailureStderr (stderr : String) : Bool :=
  containsCI stderr "auth fail" ||
    containsCI stderr "0x9a2" ||
    containsCI stderr "0x922" ||
    containsCI stderr "0x98e" ||
    containsCI stderr "bad_auth" ||
    containsCI stderr "authorization hmac check failed"

private def isLockoutStderr (stderr : String) : Bool :=
  containsCI stderr "lockout" || containsCI stderr "0x921"

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
      "-a", "fixedtpm|fixedparent|userwithauth|noda",
      "-p", pinArg]

private def loadAt : IO (Except String String) :=
  runChecked "tpm2_load"
    #["-C", primaryCtx.toString,
      "-u", sealedPub.toString,
      "-r", sealed.toString,
      "-c", loadedCtx.toString]

private def unsealAt : IO (Except String ByteArray) := do
  match ← runChecked "tpm2_unseal"
      #["-c", loadedCtx.toString,
        "-p", pinArg,
        "-o", unsealOut.toString] with
  | .error err => pure (.error err)
  | .ok _ =>
      try
        let bytes ← IO.FS.readBinFile unsealOut
        IO.FS.removeFile unsealOut
        pure (.ok bytes)
      catch e =>
        pure (.error e.toString)

/-- Generate a fresh master key, seal it under the TPM with `pin` as the
    auth value, and persist the sealed blob + manifest. -/
def bootstrap (pin : String) (notify : Notifier) : IO (Except String Unit) := do
  if ← existsOnDisk then
    return .error "master key already initialized"
  unless validPin pin do
    return .error s!"PIN must be at least {minPinLength} characters"
  unless (← deviceAvailable) do
    return .error "TPM device not available (/dev/tpm0 or /dev/tpmrm0)"
  match ← firstMissingTool sealTools with
  | some tool => return .error s!"tpm2-tools missing: {tool}"
  | none => pure ()
  IO.FS.createDirAll masterDir
  hardenMasterDir
  notify "pin-required" (.obj #[("op", .str "master-bootstrap")])
  -- Why: 32 bytes is the symmetric-key size used by ChaCha20-Poly1305 wraps.
  let seedBytes ← LeanKohaku.Crypto.Random.getRandomBytes 32
  IO.FS.writeBinFile plainSeed seedBytes
  hardenFile plainSeed
  writeAuth pin
  match ← createPrimaryAt with
  | .error err =>
      clearAuth
      IO.FS.removeFile plainSeed
      return .error s!"tpm2_createprimary failed: {err}"
  | .ok _ => pure ()
  match ← sealAtSimple with
  | .error err =>
      clearAuth
      IO.FS.removeFile plainSeed
      return .error s!"tpm2_create (seal) failed: {err}"
  | .ok _ => pure ()
  clearAuth
  -- Why: erase the plaintext seed file as soon as the TPM has the sealed copy.
  IO.FS.removeFile plainSeed
  IO.FS.writeFile manifest manifestText
  hardenMasterFiles
  notify "pin-success" (.obj #[("op", .str "master-bootstrap")])
  pure (.ok ())

/-- Unseal the master key after PIN verification. Returns the 32-byte master
    key in memory; the caller MUST not persist it to disk. Wrong PIN or TPM
    lockout surface as distinct error strings so the daemon can map them to
    stable JSON-RPC error codes. Named `unsealMaster` (not `unseal`) because
    `unseal` is a Lean 4 reserved keyword (used by `unseal ... in ...`). -/
def unsealMaster (pin : String) (notify : Notifier) : IO (Except String ByteArray) := do
  unless (← existsOnDisk) do
    return .error "master key not initialized"
  unless validPin pin do
    return .error s!"PIN must be at least {minPinLength} characters"
  unless (← deviceAvailable) do
    return .error "TPM device not available (/dev/tpm0 or /dev/tpmrm0)"
  match ← firstMissingTool sealTools with
  | some tool => return .error s!"tpm2-tools missing: {tool}"
  | none => pure ()
  notify "pin-required" (.obj #[("op", .str "master-unseal")])
  writeAuth pin
  match ← createPrimaryAt with
  | .error err =>
      clearAuth
      return .error s!"tpm2_createprimary failed: {err}"
  | .ok _ => pure ()
  match ← loadAt with
  | .error err =>
      clearAuth
      return .error s!"tpm2_load failed: {err}"
  | .ok _ => pure ()
  match ← unsealAt with
  | .error err =>
      clearAuth
      if isLockoutStderr err then
        notify "pin-locked-out" (.obj #[("op", .str "master-unseal"), ("stderr", .str err)])
        return .error s!"tpm dictionary-attack lockout: {err}"
      else if isAuthFailureStderr err then
        notify "pin-auth-failed" (.obj #[("op", .str "master-unseal"), ("stderr", .str err)])
        return .error s!"pin auth failed: {err}"
      else
        return .error s!"tpm2_unseal failed: {err}"
  | .ok bytes =>
      clearAuth
      if bytes.size != 32 then
        pure (.error s!"tpm2_unseal returned unexpected size: {bytes.size}")
      else
        notify "pin-success" (.obj #[("op", .str "master-unseal")])
        pure (.ok bytes)

end LeanKohaku.Keystore.MasterKey
