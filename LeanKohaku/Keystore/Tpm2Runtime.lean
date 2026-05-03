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

User verification is currently enforced as a local Linux gate through
`fprintd-verify` before creating a new key. This is not yet a cryptographic
TPM policy session, so signing must also require user verification when that
runtime path is added.
-/

namespace LeanKohaku.Keystore.Tpm2Runtime

open LeanKohaku.Ethereum.P256Precompile
open LeanKohaku.Crypto.Hex
open LeanKohaku.Keystore.Enclave
open LeanKohaku.Wallet.Account
open LeanKohaku.Encoding.Json

/-- A side-channel for biometric / TPM lifecycle events. The daemon
    overrides this with a closure that writes JSON-RPC notification
    frames onto the active UDS connection so the CLI can render
    user-facing prompts before the final response arrives. The default
    is a stderr trace (kept off the daemon stdout) for direct,
    non-daemon invocations. -/
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
  | missingTpmDevice
  | missingTool (tool : String)
  | biometricVerificationFailed (stderr : String)
  | policyRejected
  | commandFailed (cmd : String) (stderr : String)
  deriving Repr

inductive SignStatus where
  | signed
  | invalidKeyName
  | invalidDigest
  | missingKey
  | missingTpmDevice
  | missingTool (tool : String)
  | biometricVerificationFailed (stderr : String)
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

def requiredTools : List String :=
  ["tpm2_createprimary", "tpm2_create", "tpm2_load", "tpm2_readpublic"]

def signingTools : List String :=
  ["tpm2_createprimary", "tpm2_load", "tpm2_sign"]

def biometricTool : String :=
  "fprintd-verify"

def defaultBiometricFinger : String :=
  "right-index-finger"

def biometricAttempts : Nat :=
  3

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

def fprintdAvailable : IO Bool := do
  try
    let out ← IO.Process.output { cmd := biometricTool, args := #["--help"] }
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

def biometricFinger : IO String := do
  match ← IO.getEnv "LEAN_KOHAKU_BIOMETRIC_FINGER" with
  | some finger =>
      if finger.isEmpty then
        pure defaultBiometricFinger
      else
        pure finger
  | none => pure defaultBiometricFinger

/-- Build the JSON params for a biometric event notification. -/
private def biometricEventParams (finger : String) (attempt : Nat)
    (extra : Array (String × Json) := #[]) : Json :=
  .obj (#[
      ("finger", .str finger),
      ("attempt", .num (Int.ofNat attempt)),
      ("of", .num (Int.ofNat biometricAttempts))
    ] ++ extra)

partial def verifyLocalUserLoop
    (notify : Notifier) (finger : String) : Nat → Nat → IO (Except String Unit)
  | 0, _ =>
      pure (.error s!"{biometricTool} failed after {biometricAttempts} attempts")
  | remaining + 1, attemptNo => do
      logStep s!"starting biometric verification with fprintd using {finger} (attempt {attemptNo}/{biometricAttempts})"
      notify "biometric-required" (biometricEventParams finger attemptNo)
      -- Spawn fprintd-verify with stdio fully suppressed: stdin/stdout to
      -- /dev/null and stderr captured into a pipe so we can include it in
      -- a biometric-failed event without dumping it on the daemon terminal.
      let child ← IO.Process.spawn
        { cmd := biometricTool,
          args := #["-f", finger],
          stdin := .null,
          stdout := .null,
          stderr := .piped }
      let exitCode ← child.wait
      let errOut ← child.stderr.readToEnd
      if exitCode == 0 then
        logStep "biometric verification succeeded"
        notify "biometric-success" (biometricEventParams finger attemptNo)
        pure (.ok ())
      else
        logStep s!"biometric verification failed with exit code {exitCode}"
        notify "biometric-failed"
          (biometricEventParams finger attemptNo
            #[("exitCode", .num (Int.ofNat exitCode.toNat)),
              ("stderr", .str errOut)])
        verifyLocalUserLoop notify finger remaining (attemptNo + 1)

def verifyLocalUser (notify : Notifier := stderrNotifier) :
    IO (Except String Unit) := do
  verifyLocalUserLoop notify (← biometricFinger) biometricAttempts 1

def fileArg (path : System.FilePath) : String :=
  path.toString

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
  "creation_user_verification=fprintd-verify\n" ++
  s!"creation_user_verification_finger={defaultBiometricFinger}\n" ++
  s!"creation_user_verification_attempts={biometricAttempts}\n" ++
  "creation_user_verification_tpm_bound=false\n" ++
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
      "-r", fileArg cfg.privateBlob]

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
      fileArg cfg.digestBin]

-- Chain-agnostic R1 key creation. The key is a TPM2-wrapped P-256 keypair
-- usable on any EIP-7951–enabled chain; chain selection happens at deploy
-- time, not at key creation.
def createR1Key (cfg : Config := {}) (notify : Notifier := stderrNotifier) :
    IO CreateReport := do
  logStep s!"create requested: key={cfg.keyName}"
  logStep s!"state directory: {cfg.stateDir}"
  logStep s!"key directory: {cfg.keyDir}"
  unless validKeyName cfg.keyName do
    logStep "rejected invalid key name"
    return mkReport cfg .invalidKeyName
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

  unless (← fprintdAvailable) do
    logStep "biometric tool missing: fprintd-verify"
    return mkReport cfg (.missingTool biometricTool)

  match ← verifyLocalUser notify with
  | .error err => return mkReport cfg (.biometricVerificationFailed err)
  | .ok _ => pure ()

  logStep s!"creating key directory: {cfg.keyDir}"
  IO.FS.createDirAll cfg.keyDir
  hardenKeyDir cfg

  logStep "running tpm2_createprimary"
  match ← createPrimary cfg with
  | .error err => return mkReport cfg (.commandFailed "tpm2_createprimary" err)
  | .ok _ => pure ()

  logStep "running tpm2_create for P-256 signing key"
  match ← createSigningKey cfg with
  | .error err => return mkReport cfg (.commandFailed "tpm2_create" err)
  | .ok _ => pure ()

  logStep "running tpm2_load"
  match ← loadSigningKey cfg with
  | .error err => return mkReport cfg (.commandFailed "tpm2_load" err)
  | .ok _ => pure ()

  logStep "running tpm2_readpublic"
  match ← readPublicKey cfg with
  | .error err => return mkReport cfg (.commandFailed "tpm2_readpublic" err)
  | .ok _ => pure ()

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
    (cfg : Config := {})
    (notify : Notifier := stderrNotifier) : IO SignReport := do
  logStep s!"sign requested: chain=sepolia key={cfg.keyName}"
  logStep s!"key directory: {cfg.keyDir}"
  unless validKeyName cfg.keyName do
    logStep "rejected invalid key name"
    return mkSignReport cfg .invalidKeyName
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

      unless (← fprintdAvailable) do
        logStep "biometric tool missing: fprintd-verify"
        return mkSignReport cfg (.missingTool biometricTool)

      match ← verifyLocalUser notify with
      | .error err => return mkSignReport cfg (.biometricVerificationFailed err)
      | .ok _ => pure ()

      logStep s!"writing digest file: {cfg.digestBin}"
      IO.FS.writeBinFile cfg.digestBin digest
      hardenKeyDir cfg
      hardenFile cfg.digestBin

      logStep "running tpm2_createprimary"
      match ← createPrimary cfg with
      | .error err => return mkSignReport cfg (.commandFailed "tpm2_createprimary" err)
      | .ok _ => pure ()

      logStep "running tpm2_load"
      match ← loadSigningKey cfg with
      | .error err => return mkSignReport cfg (.commandFailed "tpm2_load" err)
      | .ok _ => pure ()

      logStep "running tpm2_sign"
      match ← signDigest cfg with
      | .error err => return mkSignReport cfg (.commandFailed "tpm2_sign" err)
      | .ok _ =>
          let sig ← IO.FS.readBinFile cfg.signatureBin
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
