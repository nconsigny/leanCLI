import LeanKohaku.Keystore.Enclave
import LeanKohaku.Crypto.Hex
import LeanKohaku.Wallet.Account
import LeanKohaku.Encoding.Json

/-!
# Local TPM2 runtime backend

This module is the narrow runtime boundary for Linux TPM2 key creation. It
does not link TPM libraries or implement crypto outside Lean. Instead it
executes local `tpm2-tools` commands, producing TPM-protected key blobs and
public-key material in a local state directory.

The private key is never exported as raw key material. The `*.priv` file
created by `tpm2_create` is a TPM-wrapped private blob that must be loaded
back into the same TPM hierarchy to sign.

User verification is bound to the TPM object itself: the PIN is set as the
`userwithauth` value at `tpm2_create` time and re-checked by the TPM on every
`tpm2_sign`. Dictionary-attack protection (lockout after N consecutive
failures) is enforced by the TPM in hardware — it cannot be bypassed by a
compromised daemon. The PIN bytes never appear on `argv`; we route them
through a chmod-600 temp file (`auth.tmp` in the key directory) and pass
`-p file:<path>` to tpm2-tools.
-/

namespace LeanKohaku.Keystore.Tpm2Runtime

open LeanKohaku.Ethereum.P256Precompile
open LeanKohaku.Crypto.Hex
open LeanKohaku.Keystore.Enclave
open LeanKohaku.Wallet.Account
open LeanKohaku.Encoding.Json

/-- A side-channel for PIN / TPM lifecycle events. The daemon overrides
    this with a closure that writes JSON-RPC notification frames onto
    the active UDS connection so the CLI can render user-facing status
    updates before the final response arrives. The default is a stderr
    trace (kept off the daemon stdout) for direct, non-daemon invocations. -/
abbrev Notifier := String → Json → IO Unit

/-- Default notifier: write a one-line trace to stderr. The daemon
    replaces this with a UDS-backed notifier that emits JSON-RPC
    notifications to the connected CLI. We deliberately avoid stdout
    so daemon stdout stays free of biometric noise even without an
    override. -/
def stderrNotifier : Notifier := fun event params =>
  IO.eprintln s!"[leankohaku:event] {event} {compact params}"

structure Config where
  stateDir : System.FilePath := ".leankohaku/keystore/tpm2"
  keyName  : String := "default-r1"
  deriving Repr

inductive CreateStatus where
  | created
  | alreadyExists
  | invalidKeyName
  | invalidPin
  | missingTpmDevice
  | missingTool (tool : String)
  | pinAuthFailed (stderr : String)
  | pinDictionaryLockout (stderr : String)
  | policyRejected
  | commandFailed (cmd : String) (stderr : String)
  deriving Repr

inductive SignStatus where
  | signed
  | invalidKeyName
  | invalidDigest
  | invalidPin
  | missingKey
  | missingTpmDevice
  | missingTool (tool : String)
  | pinAuthFailed (stderr : String)
  | pinDictionaryLockout (stderr : String)
  | commandFailed (cmd : String) (stderr : String)
  deriving Repr

structure SignReport where
  status    : SignStatus
  keyDir    : System.FilePath
  digest    : System.FilePath
  signature : System.FilePath
  signatureHex : Option String
  keyName   : String
  deriving Repr

structure CreateReport where
  status      : CreateStatus
  keyDir      : System.FilePath
  publicKey   : System.FilePath
  manifest    : System.FilePath
  backend     : Backend
  curve       : Curve
  deriving Repr

def Config.keyDir (cfg : Config) : System.FilePath :=
  cfg.stateDir / cfg.keyName

def Config.primaryCtx (cfg : Config) : System.FilePath :=
  cfg.keyDir / "primary.ctx"

def Config.publicBlob (cfg : Config) : System.FilePath :=
  cfg.keyDir / "key.pub"

def Config.privateBlob (cfg : Config) : System.FilePath :=
  cfg.keyDir / "key.priv"

def Config.loadedCtx (cfg : Config) : System.FilePath :=
  cfg.keyDir / "key.ctx"

def Config.publicPem (cfg : Config) : System.FilePath :=
  cfg.keyDir / "public.pem"

def Config.manifest (cfg : Config) : System.FilePath :=
  cfg.keyDir / "manifest.txt"

def Config.digestBin (cfg : Config) : System.FilePath :=
  cfg.keyDir / "digest.bin"

def Config.signatureBin (cfg : Config) : System.FilePath :=
  cfg.keyDir / "signature.bin"

/-- Transient auth-value file. Holds the user's PIN bytes only for the
    duration of a single tpm2-tools invocation, then is unlinked. Lives
    inside the chmod-700 key directory; mode is forced to 600. -/
def Config.authFile (cfg : Config) : System.FilePath :=
  cfg.keyDir / "auth.tmp"

def requiredTools : List String :=
  ["tpm2_createprimary", "tpm2_create", "tpm2_load", "tpm2_readpublic"]

def signingTools : List String :=
  ["tpm2_createprimary", "tpm2_load", "tpm2_sign"]

/-- Minimum acceptable PIN length, in characters. Below this we reject
    the request before touching the TPM, so an obvious mistype doesn't
    burn a slot in the dictionary-attack counter. -/
def minPinLength : Nat := 4

def validPin (pin : String) : Bool :=
  decide (pin.length ≥ minPinLength)

def logStep (msg : String) : IO Unit :=
  IO.println s!"[leankohaku:tpm2] {msg}"

def deviceAvailable : BaseIO Bool := do
  let tpm0 ← ("/dev/tpm0" : System.FilePath).pathExists
  let tpmrm0 ← ("/dev/tpmrm0" : System.FilePath).pathExists
  pure (tpm0 || tpmrm0)

def keyNameCharAllowed (c : Char) : Bool :=
  if ('a' ≤ c ∧ c ≤ 'z') then true
  else if ('A' ≤ c ∧ c ≤ 'Z') then true
  else if ('0' ≤ c ∧ c ≤ '9') then true
  else decide (c = '-') || decide (c = '_')

def validKeyName (name : String) : Bool :=
  !name.isEmpty &&
    decide (name.length ≤ 64) &&
    name.toList.all keyNameCharAllowed

def toolAvailable (tool : String) : IO Bool := do
  try
    let out ← IO.Process.output { cmd := tool, args := #["--version"] }
    pure (out.exitCode == 0)
  catch _ =>
    pure false

partial def firstMissingTool : List String → IO (Option String)
  | [] => pure none
  | tool :: rest => do
      if ← toolAvailable tool then
        firstMissingTool rest
      else
        pure (some tool)

partial def firstMissingToolLogged : List String → IO (Option String)
  | [] => pure none
  | tool :: rest => do
      logStep s!"checking tool: {tool}"
      if ← toolAvailable tool then
        logStep s!"tool available: {tool}"
        firstMissingToolLogged rest
      else
        logStep s!"tool missing: {tool}"
        pure (some tool)

def runChecked (cmd : String) (args : Array String) : IO (Except String String) := do
  try
    let out ← IO.Process.output { cmd := cmd, args := args }
    if out.exitCode == 0 then
      pure (.ok out.stdout)
    else
      pure (.error out.stderr)
  catch e =>
    pure (.error e.toString)

def chmodPath (mode : String) (path : System.FilePath) : IO Unit := do
  let _ ← IO.Process.output { cmd := "chmod", args := #[mode, path.toString] }
  pure ()

def hardenDir (path : System.FilePath) : IO Unit :=
  chmodPath "700" path

def hardenFile (path : System.FilePath) : IO Unit :=
  chmodPath "600" path

def hardenKeyDir (cfg : Config) : IO Unit := do
  hardenDir ".leankohaku"
  hardenDir ".leankohaku/keystore"
  hardenDir cfg.stateDir
  hardenDir cfg.keyDir

def hardenKeyFiles (cfg : Config) : IO Unit := do
  for path in [cfg.primaryCtx, cfg.publicBlob, cfg.privateBlob, cfg.loadedCtx,
      cfg.publicPem, cfg.manifest, cfg.digestBin, cfg.signatureBin] do
    if ← path.pathExists then
      hardenFile path

/-- Build the JSON params for a PIN lifecycle notification. The PIN itself
    NEVER appears in these events — only the operation tag and any TPM
    stderr text that escaped to the daemon. -/
private def pinEventParams (op : String) (extra : Array (String × Json) := #[]) : Json :=
  .obj (#[("op", .str op)] ++ extra)

/-- Write the user-supplied PIN to a chmod-600 file inside the key directory.
    Why a file: passing `-p str:<pin>` on argv would expose the PIN in
    `/proc/<pid>/cmdline`, which is readable by same-UID processes by default.
    Why the key directory: it is already chmod-700, so the auth file is
    confined to the wallet's own state tree. -/
private def writePinFile (path : System.FilePath) (pin : String) : IO Unit := do
  IO.FS.writeBinFile path pin.toUTF8
  chmodPath "600" path

/-- Best-effort removal of the transient auth file. Suppresses failures
    because the file may have already been unlinked or never created. -/
private def clearPinFile (path : System.FilePath) : IO Unit := do
  try
    if ← path.pathExists then
      IO.FS.removeFile path
  catch _ => pure ()

/-- Case-insensitive substring check. Lean's stdlib has `endsWith`/`startsWith`
    but no built-in substring search; `splitOn` returns `[haystack]` (one
    element) when the needle is absent and a longer list otherwise. -/
private def containsCI (haystack needle : String) : Bool :=
  decide ((haystack.toLower.splitOn needle.toLower).length > 1)

/-- Recognize TPM error patterns produced by `tpm2-tools` when an auth value
    is wrong. tpm2-tools surfaces both numeric Esys/RC codes and English
    fragments; we match generously to cover firmware/tool-version drift. -/
private def isAuthFailureStderr (stderr : String) : Bool :=
  containsCI stderr "auth fail" ||
    containsCI stderr "0x9a2" ||
    containsCI stderr "0x922" ||
    containsCI stderr "0x98e" ||
    containsCI stderr "bad_auth" ||
    containsCI stderr "authorization hmac check failed"

/-- Recognize TPM dictionary-attack lockout responses. After enough wrong-PIN
    attempts, the TPM refuses to evaluate auth values until the lockout
    interval elapses (or an admin reset). -/
private def isLockoutStderr (stderr : String) : Bool :=
  containsCI stderr "lockout" || containsCI stderr "0x921"

def fileArg (path : System.FilePath) : String :=
  path.toString

/-- Format the `-p` argument that points tpm2-tools at the auth file. -/
def pinAuthArg (cfg : Config) : String :=
  s!"file:{cfg.authFile.toString}"

def manifestContents (cfg : Config) : String :=
  "leankohaku TPM2 key manifest\n" ++
  "account=r1-smart\n" ++
  "backend=linuxTpm2\n" ++
  "curve=p256\n" ++
  "public_pem=public.pem\n" ++
  "public_blob=key.pub\n" ++
  "private_blob=key.priv\n" ++
  "loaded_context=key.ctx\n" ++
  "custody=local-tpm2\n" ++
  "creation_user_verification=tpm-auth-value\n" ++
  s!"creation_user_verification_pin_min_length={minPinLength}\n" ++
  "creation_user_verification_tpm_bound=true\n" ++
  "creation_user_verification_dictionary_attack_protection=tpm-hardware\n" ++
  "raw_private_key_exported=false\n" ++
  s!"key_name={cfg.keyName}\n"

def mkReport (cfg : Config) (status : CreateStatus) : CreateReport :=
  { status := status,
    keyDir := cfg.keyDir,
    publicKey := cfg.publicPem,
    manifest := cfg.manifest,
    backend := .linuxTpm2,
    curve := .p256 }

def mkSignReport
    (cfg : Config)
    (status : SignStatus)
    (signatureHex : Option String := none) : SignReport :=
  { status := status,
    keyDir := cfg.keyDir,
    digest := cfg.digestBin,
    signature := cfg.signatureBin,
    signatureHex := signatureHex,
    keyName := cfg.keyName }

def createPrimary (cfg : Config) : IO (Except String String) :=
  runChecked "tpm2_createprimary"
    #["-C", "o",
      "-G", "ecc",
      "-g", "sha256",
      "-c", fileArg cfg.primaryCtx]

def createSigningKeyWithAlg (cfg : Config) (alg : String) : IO (Except String String) :=
  runChecked "tpm2_create"
    #["-C", fileArg cfg.primaryCtx,
      "-G", alg,
      "-g", "sha256",
      "-a", "sign|fixedtpm|fixedparent|sensitivedataorigin|userwithauth",
      "-u", fileArg cfg.publicBlob,
      "-r", fileArg cfg.privateBlob,
      "-p", pinAuthArg cfg]

def createSigningKey (cfg : Config) : IO (Except String String) := do
  match ← createSigningKeyWithAlg cfg "ecc_nist_p256" with
  | .ok out => pure (.ok out)
  | .error firstErr =>
      match ← createSigningKeyWithAlg cfg "ecc256" with
      | .ok out => pure (.ok out)
      | .error secondErr =>
          pure (.error (firstErr ++ "\nFallback ecc256 failed:\n" ++ secondErr))

def loadSigningKey (cfg : Config) : IO (Except String String) :=
  runChecked "tpm2_load"
    #["-C", fileArg cfg.primaryCtx,
      "-u", fileArg cfg.publicBlob,
      "-r", fileArg cfg.privateBlob,
      "-c", fileArg cfg.loadedCtx]

def readPublicKey (cfg : Config) : IO (Except String String) :=
  runChecked "tpm2_readpublic"
    #["-c", fileArg cfg.loadedCtx,
      "-o", fileArg cfg.publicPem,
      "-f", "pem"]

def signDigest (cfg : Config) : IO (Except String String) :=
  runChecked "tpm2_sign"
    #["-c", fileArg cfg.loadedCtx,
      "-g", "sha256",
      "-d",
      "-f", "plain",
      "-o", fileArg cfg.signatureBin,
      "-p", pinAuthArg cfg,
      fileArg cfg.digestBin]

-- Chain-agnostic R1 key creation. The key is a TPM2-wrapped P-256 keypair
-- usable on any EIP-7951–enabled chain; chain selection happens at deploy
-- time, not at key creation. The supplied `pin` becomes the TPM auth value
-- on the new key object and will be required by every subsequent sign.
def createR1Key (pin : String) (cfg : Config := {})
    (notify : Notifier := stderrNotifier) : IO CreateReport := do
  logStep s!"create requested: key={cfg.keyName}"
  logStep s!"state directory: {cfg.stateDir}"
  logStep s!"key directory: {cfg.keyDir}"
  unless validKeyName cfg.keyName do
    logStep "rejected invalid key name"
    return mkReport cfg .invalidKeyName
  unless validPin pin do
    logStep s!"rejected PIN: must be at least {minPinLength} characters"
    return mkReport cfg .invalidPin
  unless (← deviceAvailable) do
    logStep "no TPM device found at /dev/tpm0 or /dev/tpmrm0"
    return mkReport cfg .missingTpmDevice
  logStep "TPM device visible"
  match ← firstMissingToolLogged requiredTools with
  | some tool => return mkReport cfg (.missingTool tool)
  | none => pure ()

  if ← cfg.manifest.pathExists then
    logStep s!"existing manifest found, refusing overwrite: {cfg.manifest}"
    return mkReport cfg .alreadyExists

  logStep s!"creating key directory: {cfg.keyDir}"
  IO.FS.createDirAll cfg.keyDir
  hardenKeyDir cfg

  notify "pin-required" (pinEventParams "create")
  writePinFile cfg.authFile pin

  logStep "running tpm2_createprimary"
  match ← createPrimary cfg with
  | .error err =>
      clearPinFile cfg.authFile
      return mkReport cfg (.commandFailed "tpm2_createprimary" err)
  | .ok _ => pure ()

  logStep "running tpm2_create for P-256 signing key (auth value bound)"
  match ← createSigningKey cfg with
  | .error err =>
      clearPinFile cfg.authFile
      if isLockoutStderr err then
        return mkReport cfg (.pinDictionaryLockout err)
      else if isAuthFailureStderr err then
        -- Should not happen on create (no prior auth value), but mapping
        -- it explicitly keeps the surface symmetric with sign.
        return mkReport cfg (.pinAuthFailed err)
      else
        return mkReport cfg (.commandFailed "tpm2_create" err)
  | .ok _ => pure ()

  logStep "running tpm2_load"
  match ← loadSigningKey cfg with
  | .error err =>
      clearPinFile cfg.authFile
      return mkReport cfg (.commandFailed "tpm2_load" err)
  | .ok _ => pure ()

  logStep "running tpm2_readpublic"
  match ← readPublicKey cfg with
  | .error err =>
      clearPinFile cfg.authFile
      return mkReport cfg (.commandFailed "tpm2_readpublic" err)
  | .ok _ => pure ()

  clearPinFile cfg.authFile
  notify "pin-success" (pinEventParams "create")

  logStep s!"writing manifest: {cfg.manifest}"
  IO.FS.writeFile cfg.manifest (manifestContents cfg)
  hardenKeyFiles cfg
  logStep "TPM2 key creation complete"
  return mkReport cfg .created

def listSepoliaKeys (stateDir : System.FilePath := ".leankohaku/keystore/tpm2") :
    IO (List String) := do
  unless (← stateDir.pathExists) do
    return []
  let entries ← stateDir.readDir
  let mut names : List String := []
  for entry in entries do
    if (← entry.path.isDir) && (← (entry.path / "manifest.txt").pathExists) then
      names := names ++ [entry.fileName]
  return names

def signSepoliaDigest
    (digestHex : String)
    (pin : String)
    (cfg : Config := {})
    (notify : Notifier := stderrNotifier) : IO SignReport := do
  logStep s!"sign requested: chain=sepolia key={cfg.keyName}"
  logStep s!"key directory: {cfg.keyDir}"
  unless validKeyName cfg.keyName do
    logStep "rejected invalid key name"
    return mkSignReport cfg .invalidKeyName
  unless validPin pin do
    logStep s!"rejected PIN: must be at least {minPinLength} characters"
    return mkSignReport cfg .invalidPin
  unless (← deviceAvailable) do
    logStep "no TPM device found at /dev/tpm0 or /dev/tpmrm0"
    return mkSignReport cfg .missingTpmDevice
  logStep "TPM device visible"
  unless (← cfg.manifest.pathExists) do
    logStep s!"missing manifest: {cfg.manifest}"
    return mkSignReport cfg .missingKey
  match decode digestHex with
  | none =>
      logStep "digest hex decode failed"
      return mkSignReport cfg .invalidDigest
  | some digest =>
      unless digest.size == 32 do
        logStep s!"invalid digest byte length: {digest.size}"
        return mkSignReport cfg .invalidDigest
      logStep "digest accepted: 32 bytes"
      match ← firstMissingToolLogged signingTools with
      | some tool => return mkSignReport cfg (.missingTool tool)
      | none => pure ()

      logStep s!"writing digest file: {cfg.digestBin}"
      IO.FS.writeBinFile cfg.digestBin digest
      hardenKeyDir cfg
      hardenFile cfg.digestBin

      notify "pin-required" (pinEventParams "sign")
      writePinFile cfg.authFile pin

      logStep "running tpm2_createprimary"
      match ← createPrimary cfg with
      | .error err =>
          clearPinFile cfg.authFile
          return mkSignReport cfg (.commandFailed "tpm2_createprimary" err)
      | .ok _ => pure ()

      logStep "running tpm2_load"
      match ← loadSigningKey cfg with
      | .error err =>
          clearPinFile cfg.authFile
          return mkSignReport cfg (.commandFailed "tpm2_load" err)
      | .ok _ => pure ()

      logStep "running tpm2_sign"
      match ← signDigest cfg with
      | .error err =>
          clearPinFile cfg.authFile
          if isLockoutStderr err then
            notify "pin-locked-out" (pinEventParams "sign" #[("stderr", .str err)])
            return mkSignReport cfg (.pinDictionaryLockout err)
          else if isAuthFailureStderr err then
            notify "pin-auth-failed" (pinEventParams "sign" #[("stderr", .str err)])
            return mkSignReport cfg (.pinAuthFailed err)
          else
            return mkSignReport cfg (.commandFailed "tpm2_sign" err)
      | .ok _ =>
          let sig ← IO.FS.readBinFile cfg.signatureBin
          clearPinFile cfg.authFile
          notify "pin-success" (pinEventParams "sign")
          hardenKeyFiles cfg
          logStep s!"signature written: {cfg.signatureBin}"
          return mkSignReport cfg .signed (some (encode sig))

def CreateStatus.exitCode : CreateStatus → UInt32
  | .created => 0
  | .alreadyExists => 0
  | _ => 1

def SignStatus.exitCode : SignStatus → UInt32
  | .signed => 0
  | _ => 1

end LeanKohaku.Keystore.Tpm2Runtime
