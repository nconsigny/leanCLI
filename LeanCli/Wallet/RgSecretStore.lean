import LeanCli.Encoding.Json
import LeanCli.Wallet.EoaStore
import LeanCli.Keystore.MasterPassphrase

/-!
# Encrypted Railgun spending-secret store

Single-record, daemon-owned, on-disk store for the BIP-39 mnemonic that
the leancli-bridge sidecar uses as the Railgun spending secret.

Deliberately a *separate* store from `PpSecretStore` (Privacy Pools) and
from `EoaStore`: the Railgun spending secret must be cryptographically
isolated from both. The crypto primitives are reused via
`EoaStore.makeRecord` / `unlockSeedIO` but the sentinels baked into the
AAD (`slotName`, `derivationPathSentinel`, `addressSentinel`) and the
on-disk path are all distinct, so a record cannot be opened across
stores even if the same passphrase happens to unlock it.
-/

namespace LeanCli.Wallet.RgSecretStore

open LeanCli.Encoding.Json

/-- Sentinel name baked into the encrypted record's AAD. -/
def slotName : String := "rg-secret"

/-- Sentinel derivation-path slot in the AAD. -/
def derivationPathSentinel : String := "railgun/v1"

/-- Sentinel address slot in the AAD. -/
def addressSentinel : String := "rg-secret"

private def dirMode : IO.FileRight :=
  { user := { read := true, write := true, execution := true } }

private def fileMode : IO.FileRight :=
  { user := { read := true, write := true } }

def storeDir : IO System.FilePath := do
  pure ((← LeanCli.Wallet.EoaStore.dataHome) / "leancli" / "rg")

def secretPath : IO System.FilePath := do
  pure ((← storeDir) / "secret.json")

def ensureStoreDir : IO Unit := do
  let dir ← storeDir
  IO.FS.createDirAll dir
  IO.setAccessRights dir dirMode

/-- True iff a Railgun secret is currently stored on disk. -/
def existsOnDisk : IO Bool := do
  (← secretPath).pathExists

/-- Encrypt `mnemonic` with `passphrase` and write it to `secret.json`. -/
def save (passphrase mnemonic : String) : IO (Except String Unit) := do
  ensureStoreDir
  let seed := mnemonic.toByteArray
  match ← LeanCli.Wallet.EoaStore.makeRecord
            slotName passphrase seed derivationPathSentinel addressSentinel with
  | .error err => pure (.error err)
  | .ok record =>
      let path ← secretPath
      IO.FS.writeFile path (compact record.toJson ++ "\n")
      IO.setAccessRights path fileMode
      pure (.ok ())

private def loadRecord : IO (Except String LeanCli.Wallet.EoaStore.Record) := do
  try
    let text ← IO.FS.readFile (← secretPath)
    match parse text with
    | .error err => pure (.error err)
    | .ok json => pure (LeanCli.Wallet.EoaStore.Record.fromJson json)
  catch e =>
    pure (.error e.toString)

/-- Decrypt the stored Railgun mnemonic. Returns the original UTF-8 phrase. -/
def unlock (passphrase : String) : IO (Except String String) := do
  match ← loadRecord with
  | .error err => pure (.error err)
  | .ok record =>
      match ← LeanCli.Wallet.EoaStore.unlockSeedIO record passphrase with
      | .error err => pure (.error err)
      | .ok bytes =>
          match String.fromUTF8? bytes with
          | some s => pure (.ok s)
          | none => pure (.error "stored Railgun secret was not valid UTF-8")

/-- Master-KEK path: open the Railgun record's `masterWrap` field with the
    wallet KEK. The Railgun mnemonic is generated as a *distinct* BIP-39
    phrase (cryptographically isolated from EOA and PP seeds), but once
    enrolled it can be unlocked by the same master passphrase that
    unlocks the EOAs (single UX surface, no shared secret material). -/
def unlockWithMaster (kek : LeanCli.Keystore.MasterPassphrase.Kek) :
    IO (Except String String) := do
  match ← loadRecord with
  | .error err => pure (.error err)
  | .ok record =>
      match record.masterWrap with
      | none => pure (.error "Railgun secret not enrolled in wallet master")
      | some w =>
          match ← LeanCli.Keystore.MasterPassphrase.unwrapSlot
              kek record.name record.derivationPath record.address w with
          | .error err => pure (.error err)
          | .ok bytes =>
              match String.fromUTF8? bytes with
              | some s => pure (.ok s)
              | none => pure (.error "stored Railgun secret was not valid UTF-8")

/-- Add a `masterWrap` field to the on-disk Railgun record. -/
def attachMasterWrap (kek : LeanCli.Keystore.MasterPassphrase.Kek)
    (mnemonic : String) : IO (Except String Unit) := do
  match ← loadRecord with
  | .error err => pure (.error err)
  | .ok record =>
      match ← LeanCli.Keystore.MasterPassphrase.wrapSlot
          kek record.name record.derivationPath record.address mnemonic.toByteArray with
      | .error err => pure (.error err)
      | .ok wrap =>
          let updated := { record with masterWrap := some wrap }
          let path ← secretPath
          IO.FS.writeFile path (compact updated.toJson ++ "\n")
          IO.setAccessRights path fileMode
          pure (.ok ())

/-- Remove the Railgun secret record. Idempotent. -/
def delete : IO Unit := do
  try
    IO.FS.removeFile (← secretPath)
  catch _ =>
    pure ()

end LeanCli.Wallet.RgSecretStore
