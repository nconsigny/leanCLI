import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Hex
import LeanCli.Crypto.Random
import LeanCli.Encoding.Json
import LeanCli.Keystore.MasterPassphrase
import LeanCli.Sphincs.Bridge
import LeanCli.Wallet.Account

/-!
# SPHINCS- hybrid account encrypted store

Per-account JSON file persisting the SPHINCS- half of a hybrid
ECDSA+SPHINCS- ERC-4337 account. The ECDSA half lives in the wallet's
existing EoaStore via the `EcdsaAttachment` field — this store only owns
the SPHINCS- material (`pkSeed`, `pkRoot`, and the AEAD-sealed `sk`),
plus the configuration needed to wire the account on-chain (paramSet,
chain, deployed contract address once known).

Sealing model (v1):
  * Primary path — `passphraseCiphertext`: ChaCha20-Poly1305 over the
    SPHINCS- sk under a PBKDF2-SHA-512 key derived from a per-slot
    passphrase. Mirrors `EoaStore.ciphertext` exactly so a hybrid slot
    is recoverable with nothing more than its passphrase and this file.
  * Optional path — `masterWrap`: the same plaintext re-wrapped under
    the daemon's loaded master KEK
    (`LeanCli.Keystore.MasterPassphrase`). When present and the
    daemon already has the master KEK in memory (because the user
    unlocked via TPM PIN or master passphrase), no per-slot passphrase
    is required. When absent the slot still works through the primary
    path; the daemon lazy-enrolls `masterWrap` on first successful
    passphrase unlock if the master KEK is loaded — same upgrade story
    as `EoaStore.masterWrap`.

The TPM-PIN flow itself lives in `MasterPassphrase` (and ultimately
`Tpm2Runtime`); this store does not embed a TPM-direct wrap. That keeps
SPHINCS- accounts portable across hosts after a `wallet master init`
step that re-enrolls the master KEK under a new TPM.

The shim binary never touches this file: keygen produces the hex sk,
which the daemon seals here before any disk write. The sk is never
re-emitted to a sidecar — verify-after-sign and any future on-chain
deploy / send call goes back through `Sphincs.Bridge.signWithVerify`
with the sk supplied per-call after a fresh unseal.
-/

namespace LeanCli.Wallet.SphincsHybridStore

open LeanCli.Encoding.Json

/-- Per-hybrid-account persisted record. Everything except `passphraseCiphertext`
    is non-sensitive: the JSON is safe to inspect with `cat` and to back up
    alongside the EoaStore JSON. -/
structure Record where
  version          : Nat
  /-- Slot name. Globally unique per host (slot files share the
      sphincs-hybrid namespace). -/
  name             : String
  /-- Parameter set: emitted using `LeanCli.Sphincs.ParamSet.toString`
      so the JSON tag round-trips through `parse?` on read. -/
  paramSet         : LeanCli.Sphincs.ParamSet
  /-- Which chain this hybrid is deployed (or will be deployed) on. The
      daemon uses this together with `paramSet` to look up the on-chain
      verifier address via `cfg.sphincsVerifiers`. -/
  chainId          : Nat
  /-- ECDSA half: either an existing wallet account, or a freshly-derived
      sub-path under a wallet's BIP-39 seed. -/
  ecdsaAttachment  : LeanCli.Wallet.Account.EcdsaAttachment
  /-- ECDSA owner address (recovered from `ecdsaAttachment`'s private
      key at create time). Cached so list/show RPCs don't need to unlock
      the EOA wallet just to render. -/
  ownerAddress     : String
  /-- SPHINCS- public seed and root (hex). For C13 these are 32-byte ABI
      words with the meaningful 16 bytes in the high half; for
      SLH-DSA-SHA2-128-24 they are 16-byte half-words. The Bridge's
      `KeyMaterial` shape governs. -/
  pkSeed           : String
  pkRoot           : String
  /-- PBKDF2-HMAC-SHA-512 parameters used to derive the passphrase-side
      key. Identical defaults to `EoaStore.defaultKdfIters`. -/
  kdfSalt          : ByteArray
  kdfIters         : Nat
  /-- ChaCha20-Poly1305 ciphertext of the SPHINCS- sk under the
      passphrase-derived key. Layout = nonce(12) || ciphertext+tag. -/
  passphraseCiphertext : ByteArray
  /-- Optional: same plaintext re-wrapped under the daemon's master KEK
      (see `Keystore.MasterPassphrase.wrapSlot`). When present, an
      already-loaded master KEK skips the per-slot passphrase prompt.
      `none` means the slot was created before master enrolment or with
      master enrolment disabled. -/
  masterWrap       : Option ByteArray := none
  /-- Counterfactual ERC-4337 smart-account address (CREATE2-derived).
      `none` until the daemon has computed it (which requires a deployed
      `SphincsAccountFactory` address, currently a config item). -/
  smartAccountAddress : Option String := none
  /-- Did the user explicitly pick a per-slot passphrase, or did the
      daemon mint an ephemeral one (because the master KEK was loaded
      and we only needed `passphraseCiphertext` as a fallback)? Mirrors
      `EoaStore.Record.customPassphrase`. `false` = ephemeral (re-enroll
      under master is always safe); `true` = user-managed (don't
      lazy-rewrap on unlock). -/
  customPassphrase : Bool := false
  /-- Unix epoch (seconds) at create time, for record-keeping. -/
  createdAt        : Nat

def currentVersion : Nat := 1

def defaultKdfIters : Nat := 100000

private def dirMode : IO.FileRight :=
  { user := { read := true, write := true, execution := true } }

private def fileMode : IO.FileRight :=
  { user := { read := true, write := true } }

def dataHome : IO System.FilePath := do
  match ← IO.getEnv "XDG_DATA_HOME" with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "HOME" with
      | some home => pure (home ++ "/.local/share")
      | none => pure ".leancli"

def storeDir : IO System.FilePath := do
  pure ((← dataHome) / "leancli" / "sphincs-hybrid")

def slotPath (name : String) : IO System.FilePath := do
  pure ((← storeDir) / (name ++ ".json"))

def ensureStoreDir : IO Unit := do
  let dir ← storeDir
  IO.FS.createDirAll dir
  IO.setAccessRights dir dirMode

private def hex (bytes : ByteArray) : Json :=
  .str (LeanCli.Crypto.Hex.encode bytes)

/-- ECDSA attachment → JSON. Discriminator stays explicit (`kind`) so the
    JSON file is self-describing under `cat`. -/
def ecdsaAttachmentToJson :
    LeanCli.Wallet.Account.EcdsaAttachment → Json
  | .existing wallet idx =>
      .obj #[
        ("kind",         .str "existing"),
        ("walletName",   .str wallet),
        ("accountIndex", .num (Int.ofNat idx))
      ]
  | .derived wallet path =>
      .obj #[
        ("kind",       .str "derived"),
        ("walletName", .str wallet),
        ("path",       .str path.asString)
      ]

def derivationPathFromString (s : String) :
    Except String LeanCli.Wallet.Account.DerivationPath := do
  -- Why: parse a BIP-44 path string m/44'/60'/account'/change/index. We
  -- only need round-trip with `DerivationPath.asString`, so a strict
  -- form-check is enough — anything else is treated as a serialization
  -- error. `.toString` calls below cast `String.Slice` results back to
  -- `String` (the v4.29.1 toolchain returns slices from `drop`/`dropEnd`).
  let stripped : String :=
    if s.startsWith "m/" then (s.drop 2).toString else s
  let parts : List String := stripped.splitOn "/"
  if parts.length ≠ 5 then
    .error s!"derivation path must have 5 components (got '{s}')"
  else
    let parseHardened (lvl : String) : Except String Nat := do
      let suffix : String :=
        if lvl.endsWith "'" then (lvl.dropEnd 1).toString else lvl
      match suffix.toNat? with
      | some n => .ok n
      | none => .error s!"path level not a Nat: '{lvl}'"
    let purpose ← parseHardened (parts[0]!)
    let coinType ← parseHardened (parts[1]!)
    let account ← parseHardened (parts[2]!)
    let change ← parseHardened (parts[3]!)
    let index ← parseHardened (parts[4]!)
    .ok { purpose := purpose, coinType := coinType, account := account,
          change := change, index := index }

def ecdsaAttachmentFromJson (json : Json) :
    Except String LeanCli.Wallet.Account.EcdsaAttachment := do
  let kind ← match getField "kind" json >>= asString with
    | some s => .ok s
    | none => .error "ecdsaAttachment.kind missing"
  match kind with
  | "existing" =>
      let wallet ← match getField "walletName" json >>= asString with
        | some s => .ok s | none => .error "ecdsaAttachment.walletName missing"
      let idx ← match getField "accountIndex" json >>= asNat with
        | some n => .ok n | none => .error "ecdsaAttachment.accountIndex missing"
      .ok (.existing wallet idx)
  | "derived" =>
      let wallet ← match getField "walletName" json >>= asString with
        | some s => .ok s | none => .error "ecdsaAttachment.walletName missing"
      let pathStr ← match getField "path" json >>= asString with
        | some s => .ok s | none => .error "ecdsaAttachment.path missing"
      let path ← derivationPathFromString pathStr
      .ok (.derived wallet path)
  | other => .error s!"unknown ecdsaAttachment.kind '{other}'"

def Record.toJson (r : Record) : Json :=
  let base : Array (String × Json) := #[
    ("version",              .num (Int.ofNat r.version)),
    ("name",                 .str r.name),
    ("paramSet",             .str r.paramSet.toString),
    ("chainId",              .num (Int.ofNat r.chainId)),
    ("ecdsaAttachment",      ecdsaAttachmentToJson r.ecdsaAttachment),
    ("ownerAddress",         .str r.ownerAddress),
    ("pkSeed",               .str r.pkSeed),
    ("pkRoot",               .str r.pkRoot),
    ("kdfSalt",              hex r.kdfSalt),
    ("kdfIters",             .num (Int.ofNat r.kdfIters)),
    ("passphraseCiphertext", hex r.passphraseCiphertext),
    ("createdAt",            .num (Int.ofNat r.createdAt))
  ]
  let withMaster :=
    match r.masterWrap with
    | none => base
    | some w => base.push ("masterWrap", hex w)
  let withSmart :=
    match r.smartAccountAddress with
    | none => withMaster
    | some a => withMaster.push ("smartAccountAddress", .str a)
  -- Emit customPassphrase only when true (mirror EoaStore JSON ergonomics).
  if r.customPassphrase then
    .obj (withSmart.push ("customPassphrase", .bool true))
  else
    .obj withSmart

private def fieldString (obj : Json) (key : String) : Except String String :=
  match getField key obj >>= asString with
  | some v => .ok v
  | none => .error s!"missing string field: {key}"

private def fieldNat (obj : Json) (key : String) : Except String Nat :=
  match getField key obj >>= asNat with
  | some v => .ok v
  | none => .error s!"missing natural-number field: {key}"

private def fieldBytes (obj : Json) (key : String) : Except String ByteArray :=
  match getField key obj >>= asBytes with
  | some v => .ok v
  | none => .error s!"missing hex field: {key}"

def Record.fromJson (json : Json) : Except String Record := do
  let version ← fieldNat json "version"
  if version ≠ currentVersion then
    .error s!"unsupported sphincs-hybrid store version: {version}"
  else do
    let name ← fieldString json "name"
    let paramSetStr ← fieldString json "paramSet"
    let paramSet ← match LeanCli.Sphincs.ParamSet.parse? paramSetStr with
      | some p => .ok p
      | none => .error s!"unknown paramSet '{paramSetStr}'"
    let chainId ← fieldNat json "chainId"
    let attachmentJson ← match getField "ecdsaAttachment" json with
      | some v => .ok v
      | none => .error "missing ecdsaAttachment"
    let ecdsaAttachment ← ecdsaAttachmentFromJson attachmentJson
    let ownerAddress ← fieldString json "ownerAddress"
    let pkSeed ← fieldString json "pkSeed"
    let pkRoot ← fieldString json "pkRoot"
    let kdfSalt ← fieldBytes json "kdfSalt"
    let kdfIters ← fieldNat json "kdfIters"
    let passphraseCiphertext ← fieldBytes json "passphraseCiphertext"
    let createdAt ← fieldNat json "createdAt"
    let masterWrap : Option ByteArray := getField "masterWrap" json >>= asBytes
    let smartAccountAddress : Option String :=
      getField "smartAccountAddress" json >>= asString
    let customPassphrase : Bool :=
      match getField "customPassphrase" json with
      | some (.bool b) => b
      | _ => false
    if kdfSalt.size = 0 then
      .error "empty KDF salt"
    else if passphraseCiphertext.size < 12 then
      .error "passphraseCiphertext too short (missing nonce)"
    else
      .ok {
        version := version, name := name, paramSet := paramSet,
        chainId := chainId, ecdsaAttachment := ecdsaAttachment,
        ownerAddress := ownerAddress, pkSeed := pkSeed, pkRoot := pkRoot,
        kdfSalt := kdfSalt, kdfIters := kdfIters,
        passphraseCiphertext := passphraseCiphertext,
        masterWrap := masterWrap,
        smartAccountAddress := smartAccountAddress,
        customPassphrase := customPassphrase,
        createdAt := createdAt
      }

private def deriveKey (passphrase : String) (salt : ByteArray) (iters : Nat) :
    IO (Except String ByteArray) :=
  LeanCli.Crypto.Hacl.pbkdf2HmacSha512IO
    (LeanCli.Crypto.Hex.encode passphrase.toByteArray)
    (LeanCli.Crypto.Hex.encode salt)
    iters
    32

/-- AAD binds the ciphertext to this slot's identity so a swapped JSON
    file (or replayed across slots) fails to decrypt. -/
private def aad (name paramSet ownerAddress : String) : ByteArray :=
  ("sphincs-hybrid-v1\n" ++ name ++ "\n" ++ paramSet ++ "\n" ++ ownerAddress).toByteArray

/-- Seal a SPHINCS- sk (hex string from `Bridge.KeyMaterial.sk`) under
    the per-slot passphrase. Returns `nonce(12) || ciphertext+tag`. -/
def sealSk (name : String) (paramSet : LeanCli.Sphincs.ParamSet)
    (ownerAddress passphrase skHex : String)
    (salt : ByteArray) (iters : Nat) :
    IO (Except String ByteArray) := do
  match ← deriveKey passphrase salt iters with
  | .error err => pure (.error err)
  | .ok key =>
      let nonce ← LeanCli.Crypto.Random.getRandomBytes 12
      let skBytes := match LeanCli.Crypto.Hex.decode skHex with
        | some bs => bs
        | none => ByteArray.empty
      if skBytes.size = 0 then
        pure (.error "sealSk: sk hex did not decode")
      else
        match ← LeanCli.Crypto.Hacl.chacha20Poly1305SealIO
            (LeanCli.Crypto.Hex.encode key)
            (LeanCli.Crypto.Hex.encode nonce)
            (LeanCli.Crypto.Hex.encode (aad name paramSet.toString ownerAddress))
            (LeanCli.Crypto.Hex.encode skBytes) with
        | .error err => pure (.error err)
        | .ok ct => pure (.ok (nonce ++ ct))

/-- Open a sealed sk back to its hex representation. The hex form is
    what `Sphincs.Bridge.signRaw` expects. -/
def openSk (rec : Record) (passphrase : String) :
    IO (Except String String) := do
  if rec.passphraseCiphertext.size < 12 then
    pure (.error "passphraseCiphertext too short")
  else
    match ← deriveKey passphrase rec.kdfSalt rec.kdfIters with
    | .error err => pure (.error err)
    | .ok key =>
        let nonce := rec.passphraseCiphertext.extract 0 12
        let ct := rec.passphraseCiphertext.extract 12 rec.passphraseCiphertext.size
        match ← LeanCli.Crypto.Hacl.chacha20Poly1305OpenIO
            (LeanCli.Crypto.Hex.encode key)
            (LeanCli.Crypto.Hex.encode nonce)
            (LeanCli.Crypto.Hex.encode
              (aad rec.name rec.paramSet.toString rec.ownerAddress))
            (LeanCli.Crypto.Hex.encode ct) with
        | .error err => pure (.error s!"wrong passphrase or tampered slot: {err}")
        | .ok skBytes => pure (.ok (LeanCli.Crypto.Hex.encode skBytes))

/-- "Derivation path" surrogate used as the AAD middle component for
    `MasterPassphrase.wrapSlot` / `unwrapSlot`. SPHINCS- hybrids don't
    have a BIP-44 path of their own (the ECDSA half does, but the wrap
    here covers the SPHINCS- sk), so we use a synthetic
    `"sphincs-hybrid:" + paramSet.toString` string. Keeping the same
    triple `(name, derivPathAad, address)` shape lets us call into the
    existing `MasterPassphrase.wrapSlot` without forking it. -/
def derivPathAad (paramSet : LeanCli.Sphincs.ParamSet) : String :=
  "sphincs-hybrid:" ++ paramSet.toString

/-- Seal a SPHINCS- sk under the daemon's loaded master KEK. The caller
    must obtain `kek` from `LeanCli.Daemon.State.getMasterKek?`. -/
def sealUnderMaster (kek : ByteArray) (name : String)
    (paramSet : LeanCli.Sphincs.ParamSet) (ownerAddress skHex : String) :
    IO (Except String ByteArray) := do
  match LeanCli.Crypto.Hex.decode skHex with
  | none => pure (.error "sealUnderMaster: sk hex did not decode")
  | some skBytes =>
      LeanCli.Keystore.MasterPassphrase.wrapSlot
        kek name (derivPathAad paramSet) ownerAddress skBytes

/-- Inverse of `sealUnderMaster`. Returns the sk as hex (the form
    `Sphincs.Bridge.signRaw` consumes). -/
def openWithMaster (kek : ByteArray) (rec : Record) :
    IO (Except String String) := do
  match rec.masterWrap with
  | none => pure (.error "no masterWrap on this slot")
  | some wrap =>
      match ← LeanCli.Keystore.MasterPassphrase.unwrapSlot
          kek rec.name (derivPathAad rec.paramSet) rec.ownerAddress wrap with
      | .error err => pure (.error err)
      | .ok skBytes => pure (.ok (LeanCli.Crypto.Hex.encode skBytes))

def writeRecord (rec : Record) : IO Unit := do
  ensureStoreDir
  let path ← slotPath rec.name
  let bytes := compact rec.toJson
  IO.FS.writeFile path bytes
  IO.setAccessRights path fileMode

def readRecord (name : String) : IO (Except String Record) := do
  let path ← slotPath name
  if ! (← path.pathExists) then
    pure (.error s!"sphincs-hybrid slot not found: {name}")
  else
    let contents ← IO.FS.readFile path
    match parse contents with
    | .error err => pure (.error s!"slot JSON parse: {err}")
    | .ok json => pure (Record.fromJson json)

/-- List slot names (basenames without `.json`) in the store dir. -/
def listSlotNames : IO (Array String) := do
  let dir ← storeDir
  if ! (← dir.pathExists) then
    pure #[]
  else
    let entries ← dir.readDir
    pure <| entries.filterMap fun e =>
      let n := e.fileName
      if n.endsWith ".json" then some (n.dropEnd 5).toString else none

end LeanCli.Wallet.SphincsHybridStore
