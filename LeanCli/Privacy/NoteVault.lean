import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Hex
import LeanCli.Crypto.Random
import LeanCli.Encoding.Json

/-!
# Password-gated privacy-note vault

A small, self-contained envelope for backing up shielded-note material to a
file the user controls. It exists because this Tornado Cash SDK derives note
secrets deterministically from the wallet seed — there is no classic "note
string" — so a user who wants a portable backup (or who wants to import a
backup taken on another machine and confirm which notes are theirs) needs a
place to keep the derived secrets safely.

The payload is opaque JSON produced by the untrusted sidecar
(`shielded.tornado.exportNotes`). This module never interprets it; it only
seals it under a **user-chosen password** so the plaintext secrets never touch
disk. The crypto stack is reused verbatim from
`LeanCli.Keystore.MasterPassphrase` to keep one auditable surface:
PBKDF2-HMAC-SHA-512 (100k iterations) → ChaCha20-Poly1305 (12-byte nonce, AAD
binding the vault kind + version).

Trust note: this password is independent of the wallet master passphrase /
KEK. The vault is a display/backup artifact, never a signing input — importing
a vault re-derives and re-verifies every note against the wallet seed through
the sidecar before anything is shown as "yours".
-/

namespace LeanCli.Privacy.NoteVault

open LeanCli.Encoding.Json

/-- Vault format version. Bumped if the envelope shape changes. -/
def version : Nat := 1

/-- PBKDF2 iterations for the password-derived key. Matches
    `MasterPassphrase.defaultKdfIters` so the brute-force-cost target is
    identical across the wallet's password surfaces. -/
def defaultKdfIters : Nat := 100000

/-- AAD binding the ciphertext to this envelope's purpose and version, so a
    ciphertext lifted from another context (or a future format) fails to open. -/
private def vaultAad : ByteArray :=
  "leancli-note-vault-v1\n".toByteArray

private def hexJson (b : ByteArray) : Json :=
  .str (LeanCli.Crypto.Hex.encode b)

/-- Derive the 32-byte AEAD key from the vault password. -/
private def deriveKey (password : String) (salt : ByteArray) (iters : Nat) :
    IO (Except String ByteArray) :=
  LeanCli.Crypto.Hacl.pbkdf2HmacSha512IO
    (LeanCli.Crypto.Hex.encode password.toByteArray)
    (LeanCli.Crypto.Hex.encode salt)
    iters
    32

/-- Seal an opaque JSON `payload` under `password`, returning the on-disk
    vault manifest as JSON. `kind` and `chainId` are stored in the clear as
    non-secret metadata (they help a UI label the file) and are NOT part of
    the confidential payload. -/
def sealVault (password : String) (kind : String) (chainId : Nat) (payload : Json) :
    IO (Except String Json) := do
  let salt ← LeanCli.Crypto.Random.getRandomBytes 16
  let nonce ← LeanCli.Crypto.Random.getRandomBytes 12
  match ← deriveKey password salt defaultKdfIters with
  | .error err => pure (.error err)
  | .ok key =>
      let plaintext := (compact payload).toByteArray
      match ← LeanCli.Crypto.Hacl.chacha20Poly1305SealIO
          (LeanCli.Crypto.Hex.encode key)
          (LeanCli.Crypto.Hex.encode nonce)
          (LeanCli.Crypto.Hex.encode vaultAad)
          (LeanCli.Crypto.Hex.encode plaintext) with
      | .error err => pure (.error err)
      | .ok ct =>
          pure <| .ok <| .obj #[
            ("version", .num (Int.ofNat version)),
            ("kind", .str kind),
            ("chainId", .num (Int.ofNat chainId)),
            ("kdfSalt", hexJson salt),
            ("kdfIters", .num (Int.ofNat defaultKdfIters)),
            ("aeadNonce", hexJson nonce),
            ("ciphertext", hexJson ct)
          ]

private def fieldBytes (obj : Json) (key : String) : Except String ByteArray :=
  match getField key obj >>= asBytes with
  | some v => .ok v
  | none => .error s!"vault: missing hex field '{key}'"

/-- Open a vault manifest with `password`, returning the decrypted payload
    JSON. A wrong password fails the AEAD tag and yields `.error`, so callers
    can distinguish it from a corrupt file only by message — both are refusals
    to hand back plaintext. -/
def openVault (password : String) (manifest : Json) : IO (Except String Json) := do
  match getField "version" manifest >>= asNat with
  | some v =>
      if v != version then
        pure (.error s!"unsupported note-vault version: {v}")
      else
        match fieldBytes manifest "kdfSalt", fieldBytes manifest "aeadNonce",
              fieldBytes manifest "ciphertext" with
        | .ok salt, .ok nonce, .ok ct =>
            let iters := (getField "kdfIters" manifest >>= asNat).getD defaultKdfIters
            match ← deriveKey password salt iters with
            | .error err => pure (.error err)
            | .ok key =>
                match ← LeanCli.Crypto.Hacl.chacha20Poly1305OpenIO
                    (LeanCli.Crypto.Hex.encode key)
                    (LeanCli.Crypto.Hex.encode nonce)
                    (LeanCli.Crypto.Hex.encode vaultAad)
                    (LeanCli.Crypto.Hex.encode ct) with
                | .error _ => pure (.error "wrong vault password or corrupt vault file")
                | .ok pt =>
                    match parse (String.fromUTF8! pt) with
                    | .error e => pure (.error s!"vault payload is not valid JSON: {e}")
                    | .ok j => pure (.ok j)
        | _, _, _ => pure (.error "vault: malformed manifest (missing salt/nonce/ciphertext)")
  | none => pure (.error "vault: manifest missing version field")

end LeanCli.Privacy.NoteVault
