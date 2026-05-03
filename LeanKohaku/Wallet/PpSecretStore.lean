import LeanKohaku.Encoding.Json
import LeanKohaku.Wallet.EoaStore

/-!
# Encrypted Privacy-Pools spending-secret store

Single-record, daemon-owned, on-disk store for the BIP-39 mnemonic that
the kohaku-bridge sidecar uses as the Privacy-Pools spending secret.

This is deliberately a sibling of `EoaStore`, not an EOA slot:
the PP secret is internal daemon state, not a user-managed account, so it
must not show up in `eoa list`, `eoa show`, etc. We reuse `EoaStore`'s
KDF + AEAD primitives via `makeRecord` / `unlockSeedIO` (passing fixed
sentinels for the EOA-only fields) rather than duplicating crypto.
-/

namespace LeanKohaku.Wallet.PpSecretStore

open LeanKohaku.Encoding.Json

/-- Sentinel name baked into the encrypted record's AAD. Pinning this
    means a record copied from the EOA store cannot be opened here, and
    vice versa, even if the passphrase matches. -/
def slotName : String := "pp-secret"

/-- Sentinel derivation-path slot in the AAD. The PP mnemonic is consumed
    by the bridge as a phrase; Lean does not derive from it. -/
def derivationPathSentinel : String := "privacy-pools/v1"

/-- Sentinel address slot in the AAD. -/
def addressSentinel : String := "pp-secret"

private def dirMode : IO.FileRight :=
  { user := { read := true, write := true, execution := true } }

private def fileMode : IO.FileRight :=
  { user := { read := true, write := true } }

def storeDir : IO System.FilePath := do
  pure ((← LeanKohaku.Wallet.EoaStore.dataHome) / "leankohaku" / "pp")

def secretPath : IO System.FilePath := do
  pure ((← storeDir) / "secret.json")

def ensureStoreDir : IO Unit := do
  let dir ← storeDir
  IO.FS.createDirAll dir
  IO.setAccessRights dir dirMode

/-- True iff a PP secret is currently stored on disk. -/
def existsOnDisk : IO Bool := do
  (← secretPath).pathExists

/-- Encrypt `mnemonic` with `passphrase` and write it to `secret.json`.
    Caller is responsible for ensuring no record exists yet (see `exists`)
    when the no-overwrite policy applies. -/
def save (passphrase mnemonic : String) : IO (Except String Unit) := do
  ensureStoreDir
  let seed := mnemonic.toByteArray
  match ← LeanKohaku.Wallet.EoaStore.makeRecord
            slotName passphrase seed derivationPathSentinel addressSentinel with
  | .error err => pure (.error err)
  | .ok record =>
      let path ← secretPath
      IO.FS.writeFile path (compact record.toJson ++ "\n")
      IO.setAccessRights path fileMode
      pure (.ok ())

private def loadRecord : IO (Except String LeanKohaku.Wallet.EoaStore.Record) := do
  try
    let text ← IO.FS.readFile (← secretPath)
    match parse text with
    | .error err => pure (.error err)
    | .ok json => pure (LeanKohaku.Wallet.EoaStore.Record.fromJson json)
  catch e =>
    pure (.error e.toString)

/-- Decrypt the stored PP mnemonic. Returns the original UTF-8 phrase. -/
def unlock (passphrase : String) : IO (Except String String) := do
  match ← loadRecord with
  | .error err => pure (.error err)
  | .ok record =>
      match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
      | .error err => pure (.error err)
      | .ok bytes =>
          match String.fromUTF8? bytes with
          | some s => pure (.ok s)
          | none => pure (.error "stored PP secret was not valid UTF-8")

/-- Remove the PP secret record. Idempotent: succeeds if the file is
    already gone. The caller is expected to authenticate the passphrase
    against the stored record before calling this. -/
def delete : IO Unit := do
  try
    IO.FS.removeFile (← secretPath)
  catch _ =>
    pure ()

end LeanKohaku.Wallet.PpSecretStore
