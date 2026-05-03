import LeanKohaku.Crypto.Hacl
import LeanKohaku.Crypto.Hex
import LeanKohaku.Crypto.Random
import LeanKohaku.Encoding.Json

/-!
# Encrypted EOA seed storage

Small JSON store for encrypted EOA seeds. The daemon will call this module;
the CLI must not import it after the library split.
-/

namespace LeanKohaku.Wallet.EoaStore

open LeanKohaku.Encoding.Json

structure Account where
  index   : Nat
  path    : String
  address : String
  label   : Option String := none
  deriving Repr

structure Record where
  version        : Nat
  name           : String
  kdfSalt        : ByteArray
  kdfIters       : Nat
  aeadNonce      : ByteArray
  ciphertext     : ByteArray
  derivationPath : String
  address        : String
  createdAt      : Nat
  -- Why: multi-account support; index 0 mirrors top-level address/derivationPath
  -- for backward compatibility with consumers that read those fields.
  accounts       : Array Account := #[]
  -- Why: optional ChaCha20-Poly1305 ciphertext of the seed under the TPM-sealed
  -- master attestation key. Layout = nonce(12) || ciphertext+tag. Slots
  -- without this field continue to work; only `wallet unlock --all --biometric`
  -- requires it.
  attestationWrap : Option ByteArray := none

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
      | none => pure ".leankohaku"

def storeDir : IO System.FilePath := do
  pure ((← dataHome) / "leankohaku" / "eoa")

def slotPath (name : String) : IO System.FilePath := do
  pure ((← storeDir) / (name ++ ".json"))

def ensureStoreDir : IO Unit := do
  let dir ← storeDir
  IO.FS.createDirAll dir
  IO.setAccessRights dir dirMode

private def hex (bytes : ByteArray) : Json :=
  .str (LeanKohaku.Crypto.Hex.encode bytes)

def Account.toJson (a : Account) : Json :=
  let base : Array (String × Json) := #[
    ("index", .num (Int.ofNat a.index)),
    ("path", .str a.path),
    ("address", .str a.address)
  ]
  match a.label with
  | none => .obj base
  | some lbl => .obj (base.push ("label", .str lbl))

def Record.toJson (r : Record) : Json :=
  let base : Array (String × Json) := #[
    ("version", .num (Int.ofNat r.version)),
    ("name", .str r.name),
    ("kdfSalt", hex r.kdfSalt),
    ("kdfIters", .num (Int.ofNat r.kdfIters)),
    ("aeadNonce", hex r.aeadNonce),
    ("ciphertext", hex r.ciphertext),
    ("derivationPath", .str r.derivationPath),
    ("address", .str r.address),
    ("createdAt", .num (Int.ofNat r.createdAt)),
    ("accounts", .arr (r.accounts.map Account.toJson))
  ]
  match r.attestationWrap with
  | none => .obj base
  | some w => .obj (base.push ("attestationWrap", hex w))

private def fieldString (obj : Json) (key : String) : Except String String :=
  match getField key obj >>= asString with
  | some value => .ok value
  | none => .error s!"missing string field: {key}"

private def fieldNat (obj : Json) (key : String) : Except String Nat :=
  match getField key obj >>= asNat with
  | some value => .ok value
  | none => .error s!"missing natural-number field: {key}"

private def fieldBytes (obj : Json) (key : String) : Except String ByteArray :=
  match getField key obj >>= asBytes with
  | some value => .ok value
  | none => .error s!"missing hex field: {key}"

def Account.fromJson (json : Json) : Except String Account := do
  let index ← fieldNat json "index"
  let path ← fieldString json "path"
  let address ← fieldString json "address"
  let label : Option String := getField "label" json >>= asString
  .ok { index := index, path := path, address := address, label := label }

def Record.fromJson (json : Json) : Except String Record := do
  let version ← fieldNat json "version"
  let name ← fieldString json "name"
  let kdfSalt ← fieldBytes json "kdfSalt"
  let kdfIters ← fieldNat json "kdfIters"
  let aeadNonce ← fieldBytes json "aeadNonce"
  let ciphertext ← fieldBytes json "ciphertext"
  let derivationPath ← fieldString json "derivationPath"
  let address ← fieldString json "address"
  let createdAt ← fieldNat json "createdAt"
  -- Why: lazy migration — old slot files have no `accounts`; synthesize from
  -- top-level path/address. Don't rewrite the file just for reading.
  let accounts : Array Account ←
    match getField "accounts" json with
    | none =>
        .ok #[{ index := 0, path := derivationPath, address := address, label := none }]
    | some (.arr entries) =>
        entries.foldlM (init := (#[] : Array Account))
          (fun acc entry => do
            let a ← Account.fromJson entry
            .ok (acc.push a))
    | some _ => .error "accounts field must be a JSON array"
  -- Why: missing field → None; preserves backward compat with pre-attestation slot files.
  let attestationWrap : Option ByteArray := getField "attestationWrap" json >>= asBytes
  if version != 1 then
    .error s!"unsupported EOA store version: {version}"
  else if kdfSalt.size = 0 then
    .error "empty KDF salt"
  else if aeadNonce.size != 12 then
    .error "AEAD nonce must be 12 bytes"
  else
    .ok {
      version := version,
      name := name,
      kdfSalt := kdfSalt,
      kdfIters := kdfIters,
      aeadNonce := aeadNonce,
      ciphertext := ciphertext,
      derivationPath := derivationPath,
      address := address,
      createdAt := createdAt,
      accounts := accounts,
      attestationWrap := attestationWrap
    }

private def deriveKey (passphrase : String) (salt : ByteArray) (iters : Nat) :
    IO (Except String ByteArray) :=
  LeanKohaku.Crypto.Hacl.pbkdf2HmacSha512IO
    (LeanKohaku.Crypto.Hex.encode passphrase.toByteArray)
    (LeanKohaku.Crypto.Hex.encode salt)
    iters
    32

private def aad (name derivationPath address : String) : ByteArray :=
  (name ++ "\n" ++ derivationPath ++ "\n" ++ address).toByteArray

def makeRecord (name passphrase : String) (seed : ByteArray)
    (derivationPath address : String) : IO (Except String Record) := do
  let salt ← LeanKohaku.Crypto.Random.getRandomBytes 16
  let nonce ← LeanKohaku.Crypto.Random.getRandomBytes 12
  let key ← deriveKey passphrase salt defaultKdfIters
  match key with
  | .error err => pure (.error err)
  | .ok keyBytes =>
      let sealed ← LeanKohaku.Crypto.Hacl.chacha20Poly1305SealIO
        (LeanKohaku.Crypto.Hex.encode keyBytes)
        (LeanKohaku.Crypto.Hex.encode nonce)
        (LeanKohaku.Crypto.Hex.encode (aad name derivationPath address))
        (LeanKohaku.Crypto.Hex.encode seed)
      match sealed with
      | .error err => pure (.error err)
      | .ok ciphertext =>
          pure <| .ok {
            version := 1,
            name := name,
            kdfSalt := salt,
            kdfIters := defaultKdfIters,
            aeadNonce := nonce,
            ciphertext := ciphertext,
            derivationPath := derivationPath,
            address := address,
            createdAt := ← IO.monoMsNow,
            accounts := #[{ index := 0, path := derivationPath, address := address, label := none }]
          }

def save (record : Record) : IO Unit := do
  ensureStoreDir
  let path ← slotPath record.name
  IO.FS.writeFile path (compact record.toJson ++ "\n")
  IO.setAccessRights path fileMode

def saveEncryptedSeed (name passphrase : String) (seed : ByteArray)
    (derivationPath address : String) : IO (Except String Record) := do
  match ← makeRecord name passphrase seed derivationPath address with
  | .error err => pure (.error err)
  | .ok record =>
      save record
      pure (.ok record)

def load (name : String) : IO (Except String Record) := do
  try
    let text ← IO.FS.readFile (← slotPath name)
    match parse text with
    | .error err => pure (.error err)
    | .ok json => pure (Record.fromJson json)
  catch e =>
    pure (.error e.toString)

def unlockSeedIO (record : Record) (passphrase : String) : IO (Except String ByteArray) := do
  let key ← deriveKey passphrase record.kdfSalt record.kdfIters
  match key with
  | .error err => pure (.error err)
  | .ok keyBytes =>
      LeanKohaku.Crypto.Hacl.chacha20Poly1305OpenIO
        (LeanKohaku.Crypto.Hex.encode keyBytes)
        (LeanKohaku.Crypto.Hex.encode record.aeadNonce)
        (LeanKohaku.Crypto.Hex.encode (aad record.name record.derivationPath record.address))
        (LeanKohaku.Crypto.Hex.encode record.ciphertext)

-- Why: per-slot AAD prevents reusing a wrapped seed for a different slot.
private def attestationAad (name : String) : ByteArray :=
  ("pp-attest\n" ++ name).toByteArray

/-- Encrypt a seed under the 32-byte master attestation key. Returns
    `nonce(12) || ciphertext+tag`. -/
def wrapWithMaster (masterKey : ByteArray) (slotName : String) (seed : ByteArray) :
    IO (Except String ByteArray) := do
  let nonce ← LeanKohaku.Crypto.Random.getRandomBytes 12
  match ← LeanKohaku.Crypto.Hacl.chacha20Poly1305SealIO
      (LeanKohaku.Crypto.Hex.encode masterKey)
      (LeanKohaku.Crypto.Hex.encode nonce)
      (LeanKohaku.Crypto.Hex.encode (attestationAad slotName))
      (LeanKohaku.Crypto.Hex.encode seed) with
  | .error err => pure (.error err)
  | .ok ct => pure (.ok (nonce ++ ct))

/-- Inverse of `wrapWithMaster`. Expects `nonce(12) || ciphertext+tag`. -/
def unwrapWithMaster (masterKey : ByteArray) (slotName : String) (wrap : ByteArray) :
    IO (Except String ByteArray) := do
  if wrap.size < 12 then
    pure (.error "attestationWrap too short")
  else
    let nonce := wrap.extract 0 12
    let ct := wrap.extract 12 wrap.size
    LeanKohaku.Crypto.Hacl.chacha20Poly1305OpenIO
      (LeanKohaku.Crypto.Hex.encode masterKey)
      (LeanKohaku.Crypto.Hex.encode nonce)
      (LeanKohaku.Crypto.Hex.encode (attestationAad slotName))
      (LeanKohaku.Crypto.Hex.encode ct)

def list : IO (List String) := do
  let dir ← storeDir
  if !(← dir.pathExists) then
    pure []
  else
    let entries ← dir.readDir
    pure <| entries.toList.filterMap fun ent =>
      let fileName := ent.fileName
      if fileName.endsWith ".json" then
        some ((fileName.dropEnd 5).toString)
      else
        none

def delete (name : String) : IO Unit := do
  IO.FS.removeFile (← slotPath name)

end LeanKohaku.Wallet.EoaStore
