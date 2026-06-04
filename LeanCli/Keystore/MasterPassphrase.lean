import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Hex
import LeanCli.Crypto.Random
import LeanCli.Encoding.Json
import LeanCli.Wallet.EoaStore

/-!
# Wallet master passphrase keystore

Holds a freshly-generated 32-byte master KEK (key encryption key). The
KEK never lives on disk in the clear — it is wrapped:

* under a **passphrase-derived key** (PBKDF2-HMAC-SHA-512 → ChaCha20-Poly1305),
* optionally under the **TPM-sealed master attestation key** (see
  `LeanCli.Keystore.MasterKey`), so on TPM-equipped boxes typing the
  master passphrase becomes optional.

Both wraps decrypt to the same 32-byte KEK. The KEK is then used by
`EoaStore` (`wrapWithKek` / `unwrapWithKek`) and `PpSecretStore` to seal
EOA seeds and the PP mnemonic under one unified unlock surface, while
keeping the underlying secret material cryptographically distinct (the
PP mnemonic is a separate BIP-39 phrase from any EOA seed).

The manifest also stores a small `verifier` ciphertext (a known plaintext
re-encrypted under the KEK) so we can distinguish a wrong passphrase from
a "no wraps yet" state without first reading every EOA slot.

Crypto stack reused verbatim from `EoaStore` to keep one auditable
surface: same KDF (PBKDF2-HMAC-SHA-512, 100k iters), same AEAD
(ChaCha20-Poly1305, 12-byte nonce, AAD binds intent).
-/

namespace LeanCli.Keystore.MasterPassphrase

open LeanCli.Encoding.Json

/-- 32-byte KEK. Lives only in daemon-process memory; never persisted in
    the clear. -/
abbrev Kek := ByteArray

/-- Tag byte length of the master KEK. Bound so callers can't accidentally
    install an undersized key by reading garbage from disk. -/
def kekLength : Nat := 32

/-- PBKDF2 iterations for deriving the passphrase-derived key that wraps
    the KEK. Matches `EoaStore.defaultKdfIters` so re-using slot-side
    primitives keeps a single performance / brute-force-cost target. -/
def defaultKdfIters : Nat := 100000

/-- Fixed plaintext used by the manifest verifier. Picking a stable
    versioned string lets us evolve the manifest format later by bumping
    this byte sequence. -/
def verifierPlaintext : ByteArray :=
  "leancli-master-v1".toByteArray

/-! ## On-disk paths -/

private def dirMode : IO.FileRight :=
  { user := { read := true, write := true, execution := true } }

private def fileMode : IO.FileRight :=
  { user := { read := true, write := true } }

def storeDir : IO System.FilePath := do
  pure ((← LeanCli.Wallet.EoaStore.dataHome) / "leancli" / "wallet")

def manifestPath : IO System.FilePath := do
  pure ((← storeDir) / "master.json")

def ensureStoreDir : IO Unit := do
  let dir ← storeDir
  IO.FS.createDirAll dir
  IO.setAccessRights dir dirMode

def existsOnDisk : IO Bool := do
  (← manifestPath).pathExists

/-! ## Wrap shape -/

/-- A single envelope: 12-byte nonce + AEAD ciphertext-with-tag. The two
    fields are encoded separately in JSON so consumers don't have to know
    the nonce length. -/
structure Wrap where
  aeadNonce  : ByteArray
  ciphertext : ByteArray

/-! ## Manifest -/

structure Manifest where
  version        : Nat
  kdfSalt        : ByteArray
  kdfIters       : Nat
  passphraseWrap : Wrap
  /-- Optional TPM-sealed wrap of the same KEK. When present, the daemon
      can unlock the wallet without prompting for the master passphrase
      by first unsealing the TPM master key (PIN-gated) and decrypting
      `tpmWrap`. -/
  tpmWrap        : Option Wrap
  verifier       : Wrap
  /-- Auto-lock TTL in milliseconds. After this many ms of being loaded,
      `getMasterKek?` returns `none` and per-slot unlocks acquired through
      `wallet.unlock` likewise expire. Persisted so the lifetime survives
      daemon restarts. `0` disables auto-lock (slot lives until explicit
      `wallet.lock`). Default at init: 300_000 (5 minutes). -/
  ttlMs          : Nat
  createdAt      : Nat

/-! ## AAD helpers

  Each cryptographic context gets a distinct AAD prefix so an attacker
  who swaps ciphertexts between fields in the manifest finds nothing
  decrypts.
-/

private def passphraseAad : ByteArray :=
  "leancli-master-passphrase-wrap\n".toByteArray

private def tpmAad : ByteArray :=
  "leancli-master-tpm-wrap\n".toByteArray

private def verifierAad : ByteArray :=
  "leancli-master-verifier\n".toByteArray

/-! ## JSON serialization -/

private def hexJson (b : ByteArray) : Json :=
  .str (LeanCli.Crypto.Hex.encode b)

private def fieldBytes (obj : Json) (key : String) : Except String ByteArray :=
  match getField key obj >>= asBytes with
  | some v => .ok v
  | none => .error s!"missing hex field: {key}"

private def fieldNat (obj : Json) (key : String) : Except String Nat :=
  match getField key obj >>= asNat with
  | some v => .ok v
  | none => .error s!"missing natural-number field: {key}"

def Wrap.toJson (w : Wrap) : Json :=
  .obj #[
    ("aeadNonce", hexJson w.aeadNonce),
    ("ciphertext", hexJson w.ciphertext)
  ]

def Wrap.fromJson (j : Json) : Except String Wrap := do
  let nonce ← fieldBytes j "aeadNonce"
  let ct ← fieldBytes j "ciphertext"
  if nonce.size != 12 then .error "AEAD nonce must be 12 bytes"
  else .ok { aeadNonce := nonce, ciphertext := ct }

def Manifest.toJson (m : Manifest) : Json :=
  let base : Array (String × Json) := #[
    ("version", .num (Int.ofNat m.version)),
    ("kdfSalt", hexJson m.kdfSalt),
    ("kdfIters", .num (Int.ofNat m.kdfIters)),
    ("passphraseWrap", m.passphraseWrap.toJson),
    ("verifier", m.verifier.toJson),
    ("ttlMs", .num (Int.ofNat m.ttlMs)),
    ("createdAt", .num (Int.ofNat m.createdAt))
  ]
  match m.tpmWrap with
  | none => .obj base
  | some w => .obj (base.push ("tpmWrap", w.toJson))

def Manifest.fromJson (json : Json) : Except String Manifest := do
  let version ← fieldNat json "version"
  if version != 1 then
    .error s!"unsupported master manifest version: {version}"
  else
    let kdfSalt ← fieldBytes json "kdfSalt"
    let kdfIters ← fieldNat json "kdfIters"
    let passWrap ← match getField "passphraseWrap" json with
      | none => .error "missing passphraseWrap"
      | some j => Wrap.fromJson j
    let verifier ← match getField "verifier" json with
      | none => .error "missing verifier"
      | some j => Wrap.fromJson j
    let createdAt ← fieldNat json "createdAt"
    let tpmWrap : Option Wrap ← match getField "tpmWrap" json with
      | none => .ok none
      | some j =>
          match Wrap.fromJson j with
          | .error e => .error e
          | .ok w => .ok (some w)
    -- Why: legacy manifests written before the TTL field landed default to
    -- 300_000 ms (5 min). Reading None here keeps them working.
    let ttlMs : Nat := (getField "ttlMs" json >>= asNat).getD 300000
    if kdfSalt.size = 0 then .error "empty KDF salt"
    else .ok {
      version := version,
      kdfSalt := kdfSalt,
      kdfIters := kdfIters,
      passphraseWrap := passWrap,
      tpmWrap := tpmWrap,
      verifier := verifier,
      ttlMs := ttlMs,
      createdAt := createdAt
    }

/-! ## Crypto primitives -/

/-- Derive a 32-byte AEAD key from the master passphrase via PBKDF2-HMAC-SHA512.
    Same iteration count and digest as `EoaStore.deriveKey`. -/
private def deriveFromPassphrase (passphrase : String) (salt : ByteArray)
    (iters : Nat) : IO (Except String ByteArray) :=
  LeanCli.Crypto.Hacl.pbkdf2HmacSha512IO
    (LeanCli.Crypto.Hex.encode passphrase.toByteArray)
    (LeanCli.Crypto.Hex.encode salt)
    iters
    32

/-- Seal `plaintext` under `key` with the given AAD. Returns a `Wrap`. -/
private def sealWrap (key : ByteArray) (aad : ByteArray) (plaintext : ByteArray) :
    IO (Except String Wrap) := do
  let nonce ← LeanCli.Crypto.Random.getRandomBytes 12
  match ← LeanCli.Crypto.Hacl.chacha20Poly1305SealIO
      (LeanCli.Crypto.Hex.encode key)
      (LeanCli.Crypto.Hex.encode nonce)
      (LeanCli.Crypto.Hex.encode aad)
      (LeanCli.Crypto.Hex.encode plaintext) with
  | .error err => pure (.error err)
  | .ok ct => pure (.ok { aeadNonce := nonce, ciphertext := ct })

private def openWrap (key : ByteArray) (aad : ByteArray) (w : Wrap) :
    IO (Except String ByteArray) :=
  LeanCli.Crypto.Hacl.chacha20Poly1305OpenIO
    (LeanCli.Crypto.Hex.encode key)
    (LeanCli.Crypto.Hex.encode w.aeadNonce)
    (LeanCli.Crypto.Hex.encode aad)
    (LeanCli.Crypto.Hex.encode w.ciphertext)

/-! ## Manifest builders -/

/-- Generate a fresh 32-byte KEK, wrap it under the passphrase, optionally
    under the TPM-sealed master key, and produce a manifest with a
    verifier. The KEK is returned in memory so the caller can populate the
    daemon state with it for the rest of the session. -/
def buildManifest (passphrase : String) (tpmMasterKey? : Option ByteArray)
    (ttlMs : Nat) (now : Nat) : IO (Except String (Manifest × Kek)) := do
  let salt ← LeanCli.Crypto.Random.getRandomBytes 16
  let kek ← LeanCli.Crypto.Random.getRandomBytes kekLength
  match ← deriveFromPassphrase passphrase salt defaultKdfIters with
  | .error err => pure (.error err)
  | .ok passKey =>
      match ← sealWrap passKey passphraseAad kek with
      | .error err => pure (.error err)
      | .ok passWrap =>
          match ← sealWrap kek verifierAad verifierPlaintext with
          | .error err => pure (.error err)
          | .ok verifier =>
              let tpmWrap? : Option Wrap ←
                match tpmMasterKey? with
                | none => pure none
                | some tpmKey =>
                    match ← sealWrap tpmKey tpmAad kek with
                    | .error _ =>
                        -- Why: failing the TPM wrap must NOT fail manifest
                        -- creation. The passphrase wrap is the primary
                        -- credential; the TPM path is an optional UX shortcut.
                        pure none
                    | .ok w => pure (some w)
              pure <| .ok ({
                version := 1,
                kdfSalt := salt,
                kdfIters := defaultKdfIters,
                passphraseWrap := passWrap,
                tpmWrap := tpmWrap?,
                verifier := verifier,
                ttlMs := ttlMs,
                createdAt := now
              }, kek)

/-- Write a manifest to disk with mode 600. -/
def saveManifest (m : Manifest) : IO Unit := do
  ensureStoreDir
  let path ← manifestPath
  IO.FS.writeFile path (compact m.toJson ++ "\n")
  IO.setAccessRights path fileMode

/-- Read the manifest from disk. Returns `.error` when absent or
    malformed. -/
def loadManifest : IO (Except String Manifest) := do
  try
    let text ← IO.FS.readFile (← manifestPath)
    match parse text with
    | .error err => pure (.error err)
    | .ok json => pure (Manifest.fromJson json)
  catch e =>
    pure (.error e.toString)

/-! ## Unlock paths -/

private def verifyKek (m : Manifest) (kek : Kek) :
    IO (Except String Unit) := do
  if kek.size != kekLength then
    pure (.error s!"master KEK has unexpected size: {kek.size}")
  else
    match ← openWrap kek verifierAad m.verifier with
    | .error err => pure (.error s!"master KEK failed verifier check: {err}")
    | .ok plaintext =>
        if plaintext == verifierPlaintext then pure (.ok ())
        else pure (.error "master KEK verifier plaintext mismatch")

/-- Recover the master KEK from a typed passphrase. Verifies the KEK
    against `manifest.verifier` so callers can distinguish a wrong
    passphrase from a corrupted manifest. -/
def unlockWithPassphrase (m : Manifest) (passphrase : String) :
    IO (Except String Kek) := do
  match ← deriveFromPassphrase passphrase m.kdfSalt m.kdfIters with
  | .error err => pure (.error err)
  | .ok passKey =>
      match ← openWrap passKey passphraseAad m.passphraseWrap with
      | .error _ => pure (.error "wrong master passphrase")
      | .ok kek =>
          match ← verifyKek m kek with
          | .error err => pure (.error err)
          | .ok _ => pure (.ok kek)

/-- Recover the master KEK from a TPM-unsealed master key. Returns
    `.error` when this manifest has no `tpmWrap` or when the supplied key
    fails the verifier check. -/
def unlockWithTpmKey (m : Manifest) (tpmMasterKey : ByteArray) :
    IO (Except String Kek) := do
  match m.tpmWrap with
  | none => pure (.error "this wallet is not enrolled for TPM unlock")
  | some w =>
      match ← openWrap tpmMasterKey tpmAad w with
      | .error err => pure (.error s!"TPM wrap failed to open: {err}")
      | .ok kek =>
          match ← verifyKek m kek with
          | .error err => pure (.error err)
          | .ok _ => pure (.ok kek)

/-- Add a `tpmWrap` envelope to an existing manifest. The KEK plaintext is
    re-encrypted under the supplied TPM-sealed master key with the same
    AAD as `buildManifest` uses for the TPM path, so subsequent
    `unlockWithTpmKey` calls open it identically. Use this when the user
    initially ran `wallet master init` without `--with-tpm` and later
    wants TPM-tier protection without rotating the passphrase. -/
def addTpmWrap (m : Manifest) (kek : Kek) (tpmMasterKey : ByteArray) :
    IO (Except String Manifest) := do
  if kek.size != kekLength then
    pure (.error s!"master KEK has unexpected size: {kek.size}")
  else
    match ← sealWrap tpmMasterKey tpmAad kek with
    | .error err => pure (.error err)
    | .ok w => pure (.ok { m with tpmWrap := some w })

/-! ## Wrap helpers for slots

  These mirror `EoaStore.wrapWithMaster` / `unwrapWithMaster` but use the
  wallet-level KEK (not the TPM master key) and bind to a per-slot AAD
  derived from `name / derivationPath / address`, the same triple already
  used for the per-slot passphrase ciphertext.
-/

private def slotMasterAad (name derivationPath address : String) : ByteArray :=
  ("master-wrap\n" ++ name ++ "\n" ++ derivationPath ++ "\n" ++ address).toByteArray

/-- Encrypt `seed` for slot (`name`, `derivationPath`, `address`) under
    the KEK. Returns `nonce(12) || ciphertext+tag`, matching the on-disk
    shape used by `attestationWrap`. -/
def wrapSlot (kek : Kek) (name derivationPath address : String) (seed : ByteArray) :
    IO (Except String ByteArray) := do
  let nonce ← LeanCli.Crypto.Random.getRandomBytes 12
  match ← LeanCli.Crypto.Hacl.chacha20Poly1305SealIO
      (LeanCli.Crypto.Hex.encode kek)
      (LeanCli.Crypto.Hex.encode nonce)
      (LeanCli.Crypto.Hex.encode (slotMasterAad name derivationPath address))
      (LeanCli.Crypto.Hex.encode seed) with
  | .error err => pure (.error err)
  | .ok ct => pure (.ok (nonce ++ ct))

/-- Inverse of `wrapSlot`. Expects `nonce(12) || ciphertext+tag`. -/
def unwrapSlot (kek : Kek) (name derivationPath address : String) (wrap : ByteArray) :
    IO (Except String ByteArray) := do
  if wrap.size < 12 then
    pure (.error "masterWrap too short")
  else
    let nonce := wrap.extract 0 12
    let ct := wrap.extract 12 wrap.size
    LeanCli.Crypto.Hacl.chacha20Poly1305OpenIO
      (LeanCli.Crypto.Hex.encode kek)
      (LeanCli.Crypto.Hex.encode nonce)
      (LeanCli.Crypto.Hex.encode (slotMasterAad name derivationPath address))
      (LeanCli.Crypto.Hex.encode ct)

end LeanCli.Keystore.MasterPassphrase
