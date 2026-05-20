import LeanKohaku.Crypto.Hex
import LeanKohaku.Crypto.Random
import LeanKohaku.Keystore.Tpm2Runtime
import LeanKohaku.Wallet.EoaStore

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

/-- Absolute root for TPM-sealed master-key artefacts. Anchored at the same
`dataHome` (typically `${XDG_DATA_HOME:-$HOME/.local/share}/leankohaku/`) as
the rest of the wallet state, so the daemon finds the sealed key regardless
of its CWD at spawn time. Historically this was a CWD-relative path
(`.leankohaku/keystore/tpm2/_master`) and the sealed key ended up wherever
`kohaku wallet master init` was run from; the master.json manifest is and
always was absolute, so any subsequent daemon spawn from a different CWD
desynced the two and unseal failed with "master key not initialized". -/
def masterDir : IO System.FilePath := do
  pure ((← LeanKohaku.Wallet.EoaStore.dataHome) / "leankohaku" / "keystore" / "tpm2" / "_master")

def sealed : IO System.FilePath := do pure ((← masterDir) / "sealed.bin")

-- Why: `tpm2_load` needs both the wrapped private blob and its public part.
def sealedPub : IO System.FilePath := do pure ((← masterDir) / "sealed.pub")

def primaryCtx : IO System.FilePath := do pure ((← masterDir) / "primary.ctx")

def loadedCtx : IO System.FilePath := do pure ((← masterDir) / "key.ctx")

def plainSeed : IO System.FilePath := do pure ((← masterDir) / "seed.bin")

-- Why: `tpm2_unseal` writes binary; round-tripping through `String` would
-- break on non-UTF8 bytes, so we route through a transient `-o` file that
-- is removed (and overwritten) on every unseal.
def unsealOut : IO System.FilePath := do pure ((← masterDir) / "unsealed.bin")

-- Why: chmod-600 transient file holding the user's PIN bytes. We pass
-- `-p file:<path>` to tpm2-tools so the PIN never appears on argv.
def authFile : IO System.FilePath := do pure ((← masterDir) / "auth.tmp")

def manifest : IO System.FilePath := do pure ((← masterDir) / "manifest.txt")

def sealTools : List String :=
  ["tpm2_createprimary", "tpm2_create", "tpm2_load", "tpm2_unseal"]

def existsOnDisk : IO Bool := do
  (← sealed).pathExists

/-- True when the host can actually use the TPM: kernel device node is
    present AND every tool in `sealTools` is callable. Used at init time
    so the CLI can decide whether to prompt for a TPM PIN, and at status
    probe time so the front-end can label slots as "TPM-backed". -/
def hardwareReady : IO Bool := do
  if !(← deviceAvailable) then pure false
  else
    match ← firstMissingTool sealTools with
    | some _ => pure false
    | none => pure true

def reset : IO Unit := do
  let dir ← masterDir
  let _ ← runChecked "rm" #["-rf", dir.toString]
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
  -- Walk up from the master dir and harden each ancestor under leankohaku/.
  -- Built explicitly rather than via splitOn so we keep the absolute form.
  let dir ← masterDir
  -- dir = <dataHome>/leankohaku/keystore/tpm2/_master
  let tpm2 := dir.parent.getD dir
  let keystore := tpm2.parent.getD tpm2
  let leanKohaku := keystore.parent.getD keystore
  for p in [leanKohaku, keystore, tpm2, dir] do
    hardenDir p

private def hardenMasterFiles : IO Unit := do
  for thunk in [primaryCtx, sealedPub, sealed, loadedCtx, manifest] do
    let path ← thunk
    if ← path.pathExists then
      hardenFile path

/-- Write the PIN to the transient auth file with mode 600. -/
private def writeAuth (pin : String) : IO Unit := do
  let path ← authFile
  IO.FS.writeBinFile path pin.toUTF8
  chmodPath "600" path

/-- Best-effort removal of the transient auth file. -/
private def clearAuth : IO Unit := do
  try
    let path ← authFile
    if ← path.pathExists then
      IO.FS.removeFile path
  catch _ => pure ()

private def pinArg : IO String := do
  pure s!"file:{(← authFile).toString}"

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

private def createPrimaryAt : IO (Except String String) := do
  let pc ← primaryCtx
  runChecked "tpm2_createprimary"
    #["-C", "o", "-G", "ecc", "-g", "sha256",
      "-c", pc.toString]

private def sealAtSimple : IO (Except String String) := do
  let pc ← primaryCtx
  let seed ← plainSeed
  let pub ← sealedPub
  let s ← sealed
  let auth ← pinArg
  runChecked "tpm2_create"
    #["-C", pc.toString,
      "-g", "sha256",
      "-i", seed.toString,
      "-u", pub.toString,
      "-r", s.toString,
      "-a", "fixedtpm|fixedparent|userwithauth|noda",
      "-p", auth]

private def loadAt : IO (Except String String) := do
  let pc ← primaryCtx
  let pub ← sealedPub
  let s ← sealed
  let lc ← loadedCtx
  runChecked "tpm2_load"
    #["-C", pc.toString,
      "-u", pub.toString,
      "-r", s.toString,
      "-c", lc.toString]

private def unsealAt : IO (Except String ByteArray) := do
  let lc ← loadedCtx
  let auth ← pinArg
  let out ← unsealOut
  match ← runChecked "tpm2_unseal"
      #["-c", lc.toString,
        "-p", auth,
        "-o", out.toString] with
  | .error err => pure (.error err)
  | .ok _ =>
      try
        let bytes ← IO.FS.readBinFile out
        IO.FS.removeFile out
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
  let dir ← masterDir
  let seedPath ← plainSeed
  let manifestPath ← manifest
  IO.FS.createDirAll dir
  hardenMasterDir
  notify "pin-required" (.obj #[("op", .str "master-bootstrap")])
  -- Why: 32 bytes is the symmetric-key size used by ChaCha20-Poly1305 wraps.
  let seedBytes ← LeanKohaku.Crypto.Random.getRandomBytes 32
  IO.FS.writeBinFile seedPath seedBytes
  hardenFile seedPath
  writeAuth pin
  match ← createPrimaryAt with
  | .error err =>
      clearAuth
      IO.FS.removeFile seedPath
      return .error s!"tpm2_createprimary failed: {err}"
  | .ok _ => pure ()
  match ← sealAtSimple with
  | .error err =>
      clearAuth
      IO.FS.removeFile seedPath
      return .error s!"tpm2_create (seal) failed: {err}"
  | .ok _ => pure ()
  clearAuth
  -- Why: erase the plaintext seed file as soon as the TPM has the sealed copy.
  IO.FS.removeFile seedPath
  IO.FS.writeFile manifestPath manifestText
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
