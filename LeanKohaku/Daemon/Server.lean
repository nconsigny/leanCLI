import LeanKohaku.Basic
import LeanKohaku.Daemon.Log
import LeanKohaku.Daemon.State
import LeanKohaku.Daemon.TxJournal
import LeanKohaku.Daemon.Uds
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.Privacy.Bridge
import LeanKohaku.RPC.Outbound
import LeanKohaku.RPC.Server
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Eip712
import LeanKohaku.Ethereum.Ens
import LeanKohaku.Ethereum.Tx
import LeanKohaku.Keystore.Tpm2Runtime
import LeanKohaku.Keystore.MasterKey
import LeanKohaku.Wallet.Address
import LeanKohaku.Wallet.Bip44
import LeanKohaku.Wallet.EoaStore
import LeanKohaku.Wallet.Entropy
import LeanKohaku.Wallet.EOA
import LeanKohaku.Wallet.HDKey
import LeanKohaku.Wallet.Mnemonic
import LeanKohaku.Wallet.PpSecretStore

/-!
# Daemon server

Long-running process that exposes wallet operations over a local socket.
The daemon is the only component allowed to perform Ethereum node I/O, and
every attempted connection must pass `Privacy.NetworkPolicy`.
-/

namespace LeanKohaku.Daemon.Server

open LeanKohaku.Encoding.Json
open LeanKohaku.Keystore.Tpm2Runtime
open LeanKohaku.Wallet.Account
open LeanKohaku.Privacy.NetworkPolicy
open LeanKohaku.RPC.Server

def defaultDerivationPath : String := "m/44'/60'/0'/0/0"

/-- Decode a `0x`-prefixed hex string into `Nat`. Returns `none` on any
    non-hex character. Used to humanize hex receipt fields for the text
    summary; the wire JSON keeps raw hex. -/
private def hexNat? (s : String) : Option Nat :=
  let chars := s.toList
  let body :=
    match chars with
    | '0' :: 'x' :: rest => rest
    | '0' :: 'X' :: rest => rest
    | _ => chars
  if body.isEmpty then none
  else
    body.foldl (init := some 0) fun acc c =>
      match acc, LeanKohaku.Crypto.Hex.hexDigit? c with
      | some n, some d => some (n * 16 + d.toNat)
      | _, _ => none

private def formatGweiNat (n : Nat) : String :=
  let whole := n / 1000000000
  let frac := n % 1000000000
  if frac = 0 then s!"{whole} gwei"
  else
    let str := toString frac
    let pad := String.mk (List.replicate (9 - str.length) '0')
    let trimmed := (pad ++ str).dropRightWhile (· = '0')
    s!"{whole}.{trimmed} gwei"

/-- Render a hex-encoded wei amount as gwei, falling back to the raw hex
    if decode fails (so a malformed receipt never produces an empty field). -/
private def humanGwei (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{formatGweiNat n}  ({hex})"
  | none   => hex

/-- Render a hex-encoded gas count as decimal. -/
private def humanGas (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{n}  ({hex})"
  | none   => hex

/-- Render a hex-encoded block number as decimal. -/
private def humanBlock (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{n}  ({hex})"
  | none   => hex

/-- Append one TxJournal entry for a tx the daemon just signed/broadcast.
    Best-effort: failures are logged but never raised. Why: keep journaling
    out of the success path so a write error can never fail the user's tx. -/
def journalRecord
    (slotName fromAddr toAddr txHash dataHex kind : String)
    (valueWei nonce chainId : Nat)
    (accountIndex? : Option Nat)
    (status? blockNumber? gasUsed? : Option String) : IO Unit := do
  let nowMs ← IO.monoMsNow
  let nowSec : Nat := nowMs / 1000
  let entry : LeanKohaku.Daemon.TxJournal.Entry :=
    { timestamp := nowSec, txHash := txHash, fromAddr := fromAddr,
      toAddr := toAddr, valueWei := valueWei, dataHex := dataHex,
      nonce := nonce, chainId := chainId, kind := kind,
      accountIndex? := accountIndex?, slotName := slotName,
      status? := status?, blockNumber? := blockNumber?, gasUsed? := gasUsed? }
  LeanKohaku.Daemon.TxJournal.append slotName entry

/-- A single configured indexer entry. URL is persisted to disk; the API
    key is supplied via env (e.g. `LEANKOHAKU_ETHERSCAN_KEY`) and never
    written to the config file. -/
structure IndexerEntry where
  name : String
  url  : String
  deriving Repr

structure Config where
  socketPath : String
  chainId    : Nat
  policy     : Policy
  rpcEndpoint : LeanKohaku.RPC.Outbound.Endpoint
  -- Why: ENS resolution targets mainnet regardless of the operating chain.
  -- Optional: if `none`, ENS requests fail with -32030 (no silent fallback).
  ensRpcEndpoint : Option LeanKohaku.RPC.Outbound.Endpoint := none
  -- Why: per-chain RPC endpoints picked at call time. Keys are user-supplied
  -- chain names ("mainnet", "sepolia", ...). When a request omits `chain`,
  -- `rpcEndpoint` is used. When `chain` is supplied and missing here, the
  -- handler must fail closed rather than fall back to a different chain.
  chainEndpoints : Array (String × LeanKohaku.RPC.Outbound.Endpoint) := #[]
  indexers   : Array IndexerEntry := #[]

instance : Repr Config where
  reprPrec cfg _ :=
    "Config(socketPath := " ++ repr cfg.socketPath ++
      ", chainId := " ++ repr cfg.chainId ++
      ", policy := <function>)"

/-- Resolve the RPC endpoint for an optional chain selector. Returns the
default `cfg.rpcEndpoint` when `chain?` is `none`, or the matching entry from
`cfg.chainEndpoints`. Fails closed (returns an error string) when the user
asks for a chain that is not configured — never silently uses a different
chain's endpoint. -/
def endpointForChain (cfg : Config) : Option String →
    Except String LeanKohaku.RPC.Outbound.Endpoint
  | none => .ok cfg.rpcEndpoint
  | some name =>
      match cfg.chainEndpoints.find? (fun (k, _) => k = name) with
      | some (_, ep) => .ok ep
      | none =>
          .error s!"no rpc_url configured for chain '{name}'; add it via `kohaku network set-rpc-chain {name} <url>`"

-- Why: no `defaultConfig` with a URL substitute. The daemon must refuse to
-- start without a user-configured `rpc_url` (env or daemon.json); see
-- `LeanKohaku.Daemon.Config.resolve`. Avoids any silent loopback dial.

private def slotMetadataJson (state : LeanKohaku.Daemon.State.Shared)
    (record : LeanKohaku.Wallet.EoaStore.Record) : IO Json := do
  let unlocked ← LeanKohaku.Daemon.State.isUnlocked state record.name
  pure <| .obj #[
    ("name", .str record.name),
    ("address", .str record.address),
    ("derivationPath", .str record.derivationPath),
    ("locked", .bool (!unlocked)),
    ("createdAt", .num (Int.ofNat record.createdAt))
  ]

private def textResultJson (text : String) (exitCode : UInt32) : Json :=
  .obj #[
    ("text", .str text),
    ("exitCode", .num (Int.ofNat exitCode.toNat))
  ]

private def tpm2CreateStatusText : CreateStatus → String
  | .created => "created"
  | .alreadyExists => "already exists"
  | .invalidKeyName => "invalid key name"
  | .missingTpmDevice => "missing TPM device"
  | .missingTool tool => s!"missing required tool: {tool}"
  | .biometricVerificationFailed stderr =>
      s!"biometric verification failed\n\n{stderr}"
  | .policyRejected => "Sepolia R1 account policy rejected"
  | .commandFailed cmd stderr =>
      s!"command failed: {cmd}\n\n{stderr}"

private def tpm2CreateReportText (report : CreateReport) : String :=
  "leanKohaku TPM2 R1 wallet creation\n\n\
   Requested wallet:\n\
     - account: r1-smart (chain-agnostic; deploy selects chain)\n\
     - backend: local Linux TPM2\n\
     - curve: P-256/R1\n\
     - custody: local only; no online keystore\n\n\
   Result:\n\
     - status: " ++ tpm2CreateStatusText report.status ++ "\n\
     - key directory: " ++ report.keyDir.toString ++ "\n\
     - public key: " ++ report.publicKey.toString ++ "\n\
     - manifest: " ++ report.manifest.toString ++ "\n\n\
   Security boundary:\n\
     - created through local tpm2-tools only\n\
     - new key creation requires local fprintd biometric verification\n\
     - no seed or raw private key is generated by Lean\n\
     - TPM private blob remains wrapped for the local TPM\n\
     - biometric verification is a local gate, not yet a TPM policy session\n"

private def signStatusText : SignStatus → String
  | .signed => "signed"
  | .invalidKeyName => "invalid key name"
  | .invalidDigest => "invalid digest: expected 32-byte hex"
  | .missingKey => "missing key"
  | .missingTpmDevice => "missing TPM device"
  | .missingTool tool => s!"missing required tool: {tool}"
  | .biometricVerificationFailed stderr =>
      s!"biometric verification failed\n\n{stderr}"
  | .commandFailed cmd stderr =>
      s!"command failed: {cmd}\n\n{stderr}"

private def tpm2SignReportText (report : SignReport) : String :=
  let sigLine :=
    match report.signatureHex with
    | none => ""
    | some sig => "     - signature hex: " ++ sig ++ "\n"
  "leanKohaku TPM2 R1 signing\n\n\
   Requested signer:\n\
     - key name: " ++ report.keyName ++ "\n\
     - backend: local Linux TPM2\n\n\
   Result:\n\
     - status: " ++ signStatusText report.status ++ "\n\
     - key directory: " ++ report.keyDir.toString ++ "\n\
     - digest file: " ++ report.digest.toString ++ "\n\
     - signature file: " ++ report.signature.toString ++ "\n" ++ sigLine ++
  "\n\
   Security boundary:\n\
     - signing requires local fprintd biometric verification\n\
     - digest and signature stay under the local .leankohaku state directory\n\
     - TPM private blob remains wrapped for the local TPM\n"

private def formatKeyList : List String → String
  | [] => "No local Sepolia TPM2 keys found.\n"
  | names =>
      "Local Sepolia TPM2 keys:\n" ++
        String.join (names.map (fun name => "- " ++ name ++ "\n"))

private def runScript (args : Array String) (env : Array (String × Option String) := #[]) :
    IO (UInt32 × String) := do
  try
    let out ← IO.Process.output
      { cmd := "./script/r1_sepolia.sh",
        args := args,
        env := env }
    pure (out.exitCode, out.stdout ++ out.stderr)
  catch e =>
    pure (1, e.toString ++ "\n")

/-- Like `runScript` but returns stdout and stderr separately, so the
    daemon can parse a structured first token from stdout (e.g. the
    digest hex) without having to disentangle script status chatter. -/
private def runScriptSplit (args : Array String) (env : Array (String × Option String) := #[]) :
    IO (UInt32 × String × String) := do
  try
    let out ← IO.Process.output
      { cmd := "./script/r1_sepolia.sh",
        args := args,
        env := env }
    pure (out.exitCode, out.stdout, out.stderr)
  catch e =>
    pure (1, "", e.toString ++ "\n")

private def paramName (params : Json) : Except RpcError String :=
  match params with
  | .obj _ =>
      match getField "name" params >>= asString with
      | some name => .ok name
      | none => .error invalidParams
  | .arr values =>
      match values.toList with
      | first :: _ =>
          match asString first with
          | some name => .ok name
          | none => .error invalidParams
      | [] => .error invalidParams
  | _ => .error invalidParams

private def paramString (params : Json) (key : String) : Except RpcError String :=
  match getField key params >>= asString with
  | some value => .ok value
  | none => .error invalidParams

private def paramStringD (params : Json) (key default : String) : String :=
  match getField key params >>= asString with
  | some value => value
  | none => default

private def paramNatD (params : Json) (key : String) (default : Nat) : Nat :=
  match getField key params >>= asNat with
  | some value => value
  | none => default

private def mnemonicFromPhrase (phrase : String) : LeanKohaku.Wallet.Mnemonic.Mnemonic :=
  { words := phrase.splitOn " " |>.filter (fun word => word != "") }

private def expectExcept {α : Type} : Except String α → IO α
  | .ok value => pure value
  | .error err => throw <| IO.userError err

private def deriveAddressFromSeed (seed : ByteArray) (path : String) :
    IO (Except String String) := do
  try
    discard <| expectExcept (LeanKohaku.Wallet.Bip44.validateEthereumPath path)
    let master ← expectExcept (← LeanKohaku.Wallet.HDKey.fromSeedIO seed)
    let child ← expectExcept (← LeanKohaku.Wallet.HDKey.derivePathIO master path)
    let pub ← expectExcept <| ← LeanKohaku.Crypto.Secp256k1Native.pubkeyIO
      (LeanKohaku.Crypto.Hex.encode (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 child.key))
      false
    let address ← expectExcept <| ← LeanKohaku.Wallet.Address.addressFromUncompressedPubkeyIO pub
    LeanKohaku.Wallet.Address.eip55Checksum address
  catch e =>
    pure (.error e.toString)

private def derivePrivateKeyFromSeed (seed : ByteArray) (path : String) :
    IO (Except String ByteArray) := do
  try
    discard <| expectExcept (LeanKohaku.Wallet.Bip44.validateEthereumPath path)
    let master ← expectExcept (← LeanKohaku.Wallet.HDKey.fromSeedIO seed)
    let child ← expectExcept (← LeanKohaku.Wallet.HDKey.derivePathIO master path)
    pure (.ok (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 child.key))
  catch e =>
    pure (.error e.toString)

private def unlockedSlot (state : LeanKohaku.Daemon.State.Shared) (name : String) :
    IO (Except RpcError LeanKohaku.Daemon.State.UnlockedSlot) := do
  match ← LeanKohaku.Daemon.State.getUnlocked? state name with
  | some slot => pure (.ok slot)
  | none => pure (.error { code := -32012, message := "EOA slot is locked" })

/-- Why: a freshly read record may carry a synthesized accounts list (when
    the on-disk JSON predates multi-account). Always returns a non-empty array
    with index 0 mirroring the primary path/address. -/
private def recordAccounts (r : LeanKohaku.Wallet.EoaStore.Record) :
    Array LeanKohaku.Wallet.EoaStore.Account :=
  if r.accounts.isEmpty then
    #[{ index := 0, path := r.derivationPath, address := r.address, label := none }]
  else
    r.accounts

private def accountToJson (a : LeanKohaku.Wallet.EoaStore.Account) : Json :=
  LeanKohaku.Wallet.EoaStore.Account.toJson a

private def findAccount (r : LeanKohaku.Wallet.EoaStore.Record) (idx : Nat) :
    Option LeanKohaku.Wallet.EoaStore.Account :=
  (recordAccounts r).find? (fun a => a.index = idx)

/-- Pick the smallest non-negative integer not already used as an account index. -/
private def nextAccountIndex (r : LeanKohaku.Wallet.EoaStore.Record) : Nat :=
  let used := (recordAccounts r).map (fun a => a.index)
  let rec loop (n : Nat) (fuel : Nat) : Nat :=
    match fuel with
    | 0 => n
    | fuel + 1 => if used.contains n then loop (n + 1) fuel else n
  loop 0 (used.size + 1)

/-- Resolve the optional `account` parameter into a `(path, address)` pair.
    If absent, returns the slot's primary (mirrors `derivationPath`/`address`).
    If present, looks up the account on the loaded record. -/
private def resolveAccount
    (r : LeanKohaku.Wallet.EoaStore.Record)
    (slot : LeanKohaku.Daemon.State.UnlockedSlot)
    (params : Json) : Except RpcError (String × String) :=
  match getField "account" params >>= asNat with
  | none => .ok (slot.derivationPath, slot.address)
  | some idx =>
      match findAccount r idx with
      | some a => .ok (a.path, a.address)
      | none =>
          .error { code := -32014, message := s!"account index {idx} not found in slot",
                   data := some (.str s!"slot has no account with index={idx}") }

private def loadRecord (name : String) :
    IO (Except RpcError LeanKohaku.Wallet.EoaStore.Record) := do
  match ← LeanKohaku.Wallet.EoaStore.load name with
  | .ok r => pure (.ok r)
  | .error err =>
      pure (.error { code := -32010, message := "EOA slot not found", data := some (.str err) })

/-- Resolve `(path, address)` for a sign/send operation, considering both
    legacy explicit `path` and new `account` params. `account` takes priority;
    if absent and `path` provided, only path is overridden (address stays
    primary — matches legacy behavior). If neither provided, returns slot
    primary `(derivationPath, address)`. -/
private def resolveSigningTarget
    (name : String)
    (slot : LeanKohaku.Daemon.State.UnlockedSlot) (params : Json) :
    IO (Except RpcError (String × String)) := do
  match getField "account" params >>= asNat with
  | some _ =>
      match ← loadRecord name with
      | .error err => pure (.error err)
      | .ok r => pure (resolveAccount r slot params)
  | none =>
      let path := paramStringD params "path" slot.derivationPath
      pure (.ok (path, slot.address))

private def signatureJson (sig : LeanKohaku.Crypto.Secp256k1.Signature) : Json :=
  .obj #[
    ("r", .str (LeanKohaku.Crypto.Hex.encode (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 sig.r))),
    ("s", .str (LeanKohaku.Crypto.Hex.encode (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 sig.s))),
    ("v", .num (Int.ofNat sig.v.toNat))
  ]

private def bytesToNat (bytes : ByteArray) : Nat :=
  bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

private def hexChar (n : Nat) : Char :=
  match n with
  | 0 => '0' | 1 => '1' | 2 => '2' | 3 => '3'
  | 4 => '4' | 5 => '5' | 6 => '6' | 7 => '7'
  | 8 => '8' | 9 => '9' | 10 => 'a' | 11 => 'b'
  | 12 => 'c' | 13 => 'd' | 14 => 'e' | _ => 'f'

private def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then
    some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then
    some (10 + c.toNat - 'a'.toNat)
  else if 'A' ≤ c && c ≤ 'F' then
    some (10 + c.toNat - 'A'.toNat)
  else
    none

private def stripHexPrefix (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then
    (s.drop 2).toString
  else
    s

partial def natHexDigits : Nat → List Char → List Char
  | 0, acc => acc
  | n, acc => natHexDigits (n / 16) (hexChar (n % 16) :: acc)

private def natQuantityHex (n : Nat) : String :=
  match n with
  | 0 => "0x0"
  | _ => "0x" ++ String.ofList (natHexDigits n [])

private def parseHexQuantityDigits : List Char → Nat → Option Nat
  | [], acc => some acc
  | c :: cs, acc => do
      let d ← hexDigit? c
      parseHexQuantityDigits cs (acc * 16 + d)

private def parseHexQuantity (s : String) : Option Nat :=
  let raw := stripHexPrefix s
  if raw.isEmpty then
    none
  else
    parseHexQuantityDigits raw.toList 0

private def jsonHexNat (json : Json) : Except RpcError Nat :=
  match asString json with
  | none => .error invalidParams
  | some s =>
      match parseHexQuantity s with
      | none => .error invalidParams
      | some n => .ok n

private def jsonHexNatIO (json : Json) (what : String) : IO Nat := do
  match jsonHexNat json with
  | .ok n => pure n
  | .error _ => throw <| IO.userError s!"invalid hex quantity for {what}"

private def txNatField (tx : Json) (key : String) : Except RpcError Nat :=
  match getField key tx >>= asNat with
  | some value => .ok value
  | none => .error invalidParams

private def paramNat (params : Json) (key : String) : Except RpcError Nat :=
  match getField key params >>= asNat with
  | some value => .ok value
  | none => .error invalidParams

private def txBytesFieldD (tx : Json) (key : String) (default : ByteArray := ByteArray.empty) :
    Except RpcError ByteArray :=
  match getField key tx with
  | none => .ok default
  | some json =>
      match asBytes json with
      | some bytes => .ok bytes
      | none => .error invalidParams

private def txToField (tx : Json) : Except RpcError (Option LeanKohaku.Ethereum.Address.Address) :=
  match getField "to" tx with
  | none => .ok none
  | some .null => .ok none
  | some (.str s) =>
      match LeanKohaku.Ethereum.Address.fromHex s with
      | some address => .ok (some address)
      | none => .error invalidParams
  | some _ => .error invalidParams

private def erc20BalanceOfData (owner : LeanKohaku.Ethereum.Address.Address) : String :=
  "0x70a08231" ++ String.ofList (List.replicate 24 '0') ++ stripHexPrefix (LeanKohaku.Crypto.Hex.encode owner.bytes)

private def paramTxRequest (params : Json) : Except RpcError Json :=
  match getField "tx" params with
  | some (.obj fields) => .ok (.obj fields)
  | some _ => .error invalidParams
  | none => .error invalidParams

private def txFromJson (tx : Json) : Except RpcError LeanKohaku.Ethereum.Tx.TxEip1559 := do
  let chainId ← txNatField tx "chainId"
  let nonce ← txNatField tx "nonce"
  let maxPriorityFeePerGas ← txNatField tx "maxPriorityFeePerGas"
  let maxFeePerGas ← txNatField tx "maxFeePerGas"
  let gasLimit ← txNatField tx "gasLimit"
  let to ← txToField tx
  let value ← txNatField tx "value"
  let data ← txBytesFieldD tx "data"
  .ok {
    chainId := chainId,
    nonce := nonce,
    maxPriorityFeePerGas := maxPriorityFeePerGas,
    maxFeePerGas := maxFeePerGas,
    gasLimit := gasLimit,
    to := to,
    value := value,
    data := data,
    accessList := []
  }

private def paramTx (params : Json) : Except RpcError LeanKohaku.Ethereum.Tx.TxEip1559 :=
  match getField "tx" params with
  | some tx => txFromJson tx
  | none => txFromJson params

private def estimateTxJson (fromAddr to : String) (value : Nat) (data : ByteArray) : Json :=
  .obj #[
    ("from", .str fromAddr),
    ("to", .str to),
    ("value", .str (natQuantityHex value)),
    ("data", .str (LeanKohaku.Crypto.Hex.encode data))
  ]

private def sendResultJson (to value raw txHash : String)
    (nonce gasLimit maxPriorityFeePerGas maxFeePerGas : Nat)
    (sig : LeanKohaku.Crypto.Secp256k1.Signature) : Json :=
  .obj #[
    ("to", .str to),
    ("value", .str value),
    ("nonce", .str (natQuantityHex nonce)),
    ("gasLimit", .str (natQuantityHex gasLimit)),
    ("maxPriorityFeePerGas", .str (natQuantityHex maxPriorityFeePerGas)),
    ("maxFeePerGas", .str (natQuantityHex maxFeePerGas)),
    ("raw", .str raw),
    ("txHash", .str txHash),
    ("signature", signatureJson sig)
  ]

private def saveMnemonicSlot (params : Json) (generated : Option LeanKohaku.Wallet.Mnemonic.Mnemonic := none) :
    IO (Except RpcError (LeanKohaku.Wallet.EoaStore.Record × Option LeanKohaku.Wallet.Mnemonic.Mnemonic)) := do
  try
    let name ← expectExcept <| paramString params "name" |>.mapError (fun _ => "missing name")
    let passphrase ← expectExcept <| paramString params "passphrase" |>.mapError (fun _ => "missing passphrase")
    let derivationPath := paramStringD params "derivationPath" defaultDerivationPath
    let mnemonic ←
      match generated with
      | some m => pure m
      | none =>
          let phrase ← expectExcept <| paramString params "mnemonic" |>.mapError (fun _ => "missing mnemonic")
          pure (mnemonicFromPhrase phrase)
    let seed ← expectExcept <| ← LeanKohaku.Wallet.Mnemonic.mnemonicToSeedIO mnemonic ""
    let address ← expectExcept <| ← deriveAddressFromSeed seed derivationPath
    let record ← expectExcept <| ← LeanKohaku.Wallet.EoaStore.saveEncryptedSeed
      name passphrase seed derivationPath address
    pure (.ok (record, generated))
  catch e =>
    pure <| .error { invalidParams with data := some (.str e.toString) }

private def importResultJson (state : LeanKohaku.Daemon.State.Shared)
    (record : LeanKohaku.Wallet.EoaStore.Record)
    (mnemonic? : Option LeanKohaku.Wallet.Mnemonic.Mnemonic := none) : IO Json := do
  let base ← slotMetadataJson state record
  match base with
  | .obj fields =>
      match mnemonic? with
      | none => pure (.obj fields)
      | some m => pure (.obj (fields.push ("mnemonic", .arr (m.words.toArray.map Json.str))))
  | other => pure other

private def removeSocketFile (socketPath : String) : IO Unit := do
  try
    IO.FS.removeFile socketPath
  catch _ =>
    pure ()

private def socketActivated : IO Bool := do
  match ← IO.getEnv "LISTEN_FDS" with
  | some "1" => pure true
  | _ => pure false

private def exitSoon (socketPath : String) : IO Unit := do
  IO.sleep 50
  unless (← socketActivated) do
    removeSocketFile socketPath
  IO.Process.exit 0

/-- JSON-RPC error code returned when a shielded handler that requires the
    Privacy-Pools spending secret is invoked but no encrypted secret is
    stored on disk. The CLI surfaces this as a friendly hint. -/
private def ppSecretMissing : RpcError :=
  { code := -32021
    message := "no Privacy Pools secret stored — run 'kohaku shield <wallet> <eth>' to create one or 'kohaku shield import <mnemonic>' to restore"
    data := none }

/-- Forward a shielded RPC to the kohaku-bridge sidecar. The Lean side
    classifies the bridge method through `Privacy.Bridge.policyAllows` against
    the daemon's network policy, then injects the rpc URL, chain id, and the
    privacy-pools spending mnemonic via env vars (never argv). The mnemonic
    is supplied by the caller (after decrypting the on-disk secret slot);
    the env var fallback that used to live here has been removed. -/
private def shieldedBridgeCall (cfg : Config) (method : String) (params : Json)
    (mnemonic : String) (_req : Request) : IO (Except RpcError Json) := do
  let bridgeReq : LeanKohaku.Privacy.Bridge.Request :=
    { method := method, params := params, id := 0 }
  -- Why: gate egress through the same policy that classifies all outbound
  -- network requests; the bridge is treated as configured-node access.
  let allowed := LeanKohaku.Privacy.Bridge.policyAllows cfg.policy
    .configuredNode .direct bridgeReq
  if !allowed then
    pure <| .error
      { code := -32030
        message := "shielded surface denied by policy"
        data := some (.str ("policy denies " ++ method)) }
  else
    let ppDir ← LeanKohaku.Wallet.PpSecretStore.storeDir
    try IO.FS.createDirAll ppDir catch _ => pure ()
    let statePath := (ppDir / "state.json").toString
    let storagePath := (ppDir / "storage.json").toString
    let env : Array (String × Option String) := #[
      ("LEANKOHAKU_RPC_URL", some cfg.rpcEndpoint.url),
      ("LEANKOHAKU_CHAIN_ID", some (toString cfg.chainId)),
      ("LEANKOHAKU_PP_MNEMONIC", some mnemonic),
      ("LEANKOHAKU_PP_STATE_PATH", some statePath),
      ("LEANKOHAKU_PP_STORAGE_PATH", some storagePath)
    ]
    let resp ← LeanKohaku.Privacy.Bridge.callWithEnv bridgeReq env
    pure <| .ok <| LeanKohaku.Privacy.Bridge.responseToJson resp

/-- Load the on-disk PP secret if present, decrypt it with the supplied
    passphrase, and return the plaintext mnemonic. Returns `-32021` when
    no record exists, and `-32011` when decryption fails. -/
private def unlockPpSecret (passphrase : String) : IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
    pure (.error ppSecretMissing)
  else
    match ← LeanKohaku.Wallet.PpSecretStore.unlock passphrase with
    | .ok phrase => pure (.ok phrase)
    | .error err =>
        pure <| .error
          { code := -32011, message := "PP secret unlock failed", data := some (.str err) }

/-- Default broadcast-confirmation timeout. Overridable per-call via the
    `LEANKOHAKU_BROADCAST_TIMEOUT_SECS` env var so the user can wait
    longer on congested networks without a rebuild. -/
private def defaultBroadcastTimeoutSecs' : Nat := 90

private def broadcastTimeoutSecs' : IO Nat := do
  match ← IO.getEnv "LEANKOHAKU_BROADCAST_TIMEOUT_SECS" with
  | some s =>
      match s.toNat? with
      | some n => pure n
      | none => pure defaultBroadcastTimeoutSecs'
  | none => pure defaultBroadcastTimeoutSecs'

/-- Poll `eth_getTransactionReceipt` until mined or the timeout elapses.
    Mirrors `waitForReceipt` but keeps a forward declaration so it can
    be reused by `broadcastAndAwait` without re-shuffling the file. -/
private partial def waitForReceiptShared
    (cfg : Config) (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (txHash : String) (deadlineMs startMs : Nat) :
    IO (Except String Json) := do
  let now ← IO.monoMsNow
  if now ≥ deadlineMs then
    pure (.error s!"timed out waiting for receipt after {(now - startMs) / 1000}s")
  else
    match ← LeanKohaku.RPC.Outbound.getTransactionReceipt cfg.policy cfg.rpcEndpoint txHash with
    | .error err => pure (.error err)
    | .ok json =>
        match json with
        | .null =>
            notify "tx-pending" (.obj #[
              ("txHash", .str txHash),
              ("elapsedSec", .num (Int.ofNat ((now - startMs) / 1000)))
            ])
            IO.sleep 5000
            waitForReceiptShared cfg notify txHash deadlineMs startMs
        | _ => pure (.ok json)

/-- Broadcast a signed raw EIP-1559 tx and await its receipt, streaming
    `tx-broadcasted`, `tx-pending`, and `tx-mined` (or `tx-timeout`)
    notifications on the supplied notifier.

    Returns an extras JSON object with the broadcast/receipt fields
    that callers merge into their result payload:
      - `txHash`        : tx hash from `eth_sendRawTransaction`
      - `status`        : `"success" | "revert" | "pending"`
      - `blockNumber`   : 0x-hex block number (when mined)
      - `gasUsed`       : 0x-hex gas used (when mined)
      - `effectiveGasPrice` : 0x-hex effective gas price (when mined)
      - `receipt`       : raw receipt object (when mined)
      - `error`         : timeout/RPC error string (when pending)
    Existing callers are responsible for adding their own fields
    (e.g. `raw`, `signature`, `nonce`, ...). -/
private def broadcastAndAwait
    (cfg : Config) (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (rawTxHex from_ to : String) (valueWei : Nat) :
    IO (Except RpcError Json) := do
  match ← LeanKohaku.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint rawTxHex with
  | .error err =>
      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | .ok txHashJson =>
      match txHashJson with
      | .str txHash =>
          notify "tx-broadcasted" (.obj #[
            ("txHash", .str txHash),
            ("from", .str from_),
            ("to", .str to),
            ("valueWei", .str (toString valueWei))
          ])
          let timeoutSecs ← broadcastTimeoutSecs'
          let startMs ← IO.monoMsNow
          let deadlineMs := startMs + timeoutSecs * 1000
          match ← waitForReceiptShared cfg notify txHash deadlineMs startMs with
          | .error err =>
              notify "tx-timeout" (.obj #[
                ("txHash", .str txHash),
                ("error", .str err)
              ])
              pure <| .ok <| .obj #[
                ("txHash", .str txHash),
                ("status", .str "pending"),
                ("error", .str err)
              ]
          | .ok receipt =>
              let blockNumber := (getField "blockNumber" receipt >>= asString).getD ""
              let gasUsed := (getField "gasUsed" receipt >>= asString).getD ""
              let effectiveGasPrice :=
                (getField "effectiveGasPrice" receipt >>= asString).getD ""
              let statusHex := (getField "status" receipt >>= asString).getD "0x0"
              let success := statusHex == "0x1"
              notify "tx-mined" (.obj #[
                ("txHash", .str txHash),
                ("blockNumber", .str blockNumber),
                ("gasUsed", .str gasUsed),
                ("effectiveGasPrice", .str effectiveGasPrice),
                ("status", .str (if success then "success" else "revert"))
              ])
              pure <| .ok <| .obj #[
                ("txHash", .str txHash),
                ("status", .str (if success then "success" else "revert")),
                ("blockNumber", .str blockNumber),
                ("gasUsed", .str gasUsed),
                ("effectiveGasPrice", .str effectiveGasPrice),
                ("receipt", receipt)
              ]
      | _ =>
          pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str "eth_sendRawTransaction returned non-string result") }

/-- Build, sign, and broadcast a single EIP-1559 transaction from an
    unlocked slot. If `nonceOverride?` is `some n`, that nonce is used
    instead of querying `eth_getTransactionCount` — needed when
    broadcasting a sequence of txns from one prepare call.

    The `notify?` argument, when provided, enables receipt-await with
    streamed `tx-broadcasted`/`tx-pending`/`tx-mined` notifications and
    augments the result JSON with `status`, `blockNumber`, `gasUsed`,
    `effectiveGasPrice`, and `receipt`. When `none`, the legacy
    fire-and-forget broadcast path is used (no waiting). -/
private def buildSignBroadcastTx
    (cfg : Config) (slot : LeanKohaku.Daemon.State.UnlockedSlot)
    (privateKey : ByteArray) (to : String) (toAddress : LeanKohaku.Ethereum.Address.Address)
    (value : Nat) (data : ByteArray) (nonceOverride? : Option Nat)
    (notify? : Option LeanKohaku.Keystore.Tpm2Runtime.Notifier := none) :
    IO (Except RpcError Json) := do
  try
    let nonce ←
      match nonceOverride? with
      | some n => pure n
      | none =>
          let nonceJson ← expectExcept <| (← LeanKohaku.RPC.Outbound.getTransactionCount cfg.policy cfg.rpcEndpoint slot.address "pending")
          jsonHexNatIO nonceJson "nonce"
    let priorityJson ← expectExcept <| (← LeanKohaku.RPC.Outbound.maxPriorityFeePerGas cfg.policy cfg.rpcEndpoint)
    let gasPriceJson ← expectExcept <| (← LeanKohaku.RPC.Outbound.gasPrice cfg.policy cfg.rpcEndpoint)
    let maxPriorityFeePerGas ← jsonHexNatIO priorityJson "maxPriorityFeePerGas"
    let gasPrice ← jsonHexNatIO gasPriceJson "gasPrice"
    let maxFeePerGas := gasPrice + maxPriorityFeePerGas
    let estimateRequest := estimateTxJson slot.address to value data
    let gasJson ← expectExcept <| (← LeanKohaku.RPC.Outbound.estimateGas cfg.policy cfg.rpcEndpoint estimateRequest "latest")
    let gasLimit ← jsonHexNatIO gasJson "gasLimit"
    let tx : LeanKohaku.Ethereum.Tx.TxEip1559 := {
      chainId := cfg.chainId,
      nonce := nonce,
      maxPriorityFeePerGas := maxPriorityFeePerGas,
      maxFeePerGas := maxFeePerGas,
      gasLimit := gasLimit,
      to := some toAddress,
      value := value,
      data := data,
      accessList := []
    }
    match ← LeanKohaku.Wallet.EOA.signEip1559IO tx privateKey with
    | .error err =>
        pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
    | .ok signed =>
        let raw := LeanKohaku.Crypto.Hex.encode signed.encode
        match notify? with
        | none =>
            -- Legacy path: fire-and-forget broadcast, no receipt wait.
            match ← LeanKohaku.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint raw with
            | .error err =>
                pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
            | .ok txHashJson =>
                match txHashJson with
                | .str txHash =>
                    pure <| .ok <| sendResultJson to (toString value) raw txHash
                      nonce gasLimit maxPriorityFeePerGas maxFeePerGas signed.sig
                | _ =>
                    pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str "eth_sendRawTransaction returned non-string result") }
        | some notify =>
            -- Notifier-aware path: broadcast, stream notifications, await receipt.
            match ← broadcastAndAwait cfg notify raw slot.address to value with
            | .error err => pure (.error err)
            | .ok extras =>
                let txHash := (getField "txHash" extras >>= asString).getD ""
                let base := sendResultJson to (toString value) raw txHash
                  nonce gasLimit maxPriorityFeePerGas maxFeePerGas signed.sig
                -- Merge extras (status, blockNumber, gasUsed, effectiveGasPrice, receipt, [error]).
                match base, extras with
                | .obj baseFields, .obj extraFields =>
                    -- Drop duplicate `txHash` from extras (already in base).
                    let merged := extraFields.foldl
                      (fun acc (k, v) =>
                        if k == "txHash" then acc else acc.push (k, v))
                      baseFields
                    pure (.ok (.obj merged))
                | _, _ => pure (.ok base)
  catch e =>
    pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str e.toString) }

/-- Decode a single bridge-returned tx object `{to, data, value}`. The
    bridge serialises bigints as 0x-hex strings; `value` may be missing
    for zero-value calls. -/
private def parseBridgeTx (json : Json) :
    Except RpcError (String × LeanKohaku.Ethereum.Address.Address × Nat × ByteArray) := do
  let toStr ← match getField "to" json >>= asString with
    | some s => .ok s
    | none => .error invalidParams
  let toAddr ← match LeanKohaku.Ethereum.Address.fromHex toStr with
    | some a => .ok a
    | none => .error invalidParams
  let dataStr ← match getField "data" json >>= asString with
    | some s => .ok s
    | none => .error invalidParams
  let data ← match LeanKohaku.Crypto.Hex.decode dataStr with
    | some b => .ok b
    | none => .error invalidParams
  let value ← match getField "value" json with
    | none => .ok 0
    | some .null => .ok 0
    | some j =>
        match asString j with
        | some s =>
            match parseHexQuantity s with
            | some n => .ok n
            | none => .error invalidParams
        | none =>
            match asNat j with
            | some n => .ok n
            | none => .error invalidParams
  .ok (toStr, toAddr, value, data)

/-- Loop signing and broadcasting prepared bridge txns sequentially,
    incrementing the nonce locally. Returns an array of per-tx send
    results, or the first error. -/
private def signAndBroadcastBridgeTxns
    (cfg : Config) (slot : LeanKohaku.Daemon.State.UnlockedSlot)
    (privateKey : ByteArray) (txns : Array Json)
    (notify? : Option LeanKohaku.Keystore.Tpm2Runtime.Notifier := none) :
    IO (Except RpcError (Array Json)) := do
  let baseNonceJson ← LeanKohaku.RPC.Outbound.getTransactionCount cfg.policy cfg.rpcEndpoint slot.address "pending"
  match baseNonceJson with
  | .error err =>
      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | .ok nj =>
      match jsonHexNat nj with
      | .error err => pure (.error err)
      | .ok baseNonce =>
          let mut results : Array Json := #[]
          let mut idx : Nat := 0
          for raw in txns do
            match parseBridgeTx raw with
            | .error err => return .error err
            | .ok (toStr, toAddr, value, data) =>
                match ← buildSignBroadcastTx cfg slot privateKey toStr toAddr value data (some (baseNonce + idx)) notify? with
                | .error err => return .error err
                | .ok j =>
                    -- Why: best-effort shielded.deposit journal entry per broadcast tx.
                    let getStr (k : String) : String :=
                      (getField k j >>= asString).getD ""
                    let txHash := getStr "txHash"
                    let dataHex := LeanKohaku.Crypto.Hex.encode data
                    let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                    let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                    let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                    if !txHash.isEmpty then
                      journalRecord slot.name slot.address toStr txHash dataHex "shielded.deposit"
                        value (baseNonce + idx) cfg.chainId none status? block? gas?
                    results := results.push j
                    idx := idx + 1
          pure (.ok results)

/-- Default broadcast-confirmation timeout. Overridable per-call via the
    `LEANKOHAKU_BROADCAST_TIMEOUT_SECS` env var so the user can wait
    longer on congested networks without a rebuild. -/
private def defaultBroadcastTimeoutSecs : Nat := 90

private def broadcastTimeoutSecs : IO Nat := do
  match ← IO.getEnv "LEANKOHAKU_BROADCAST_TIMEOUT_SECS" with
  | some s =>
      match s.toNat? with
      | some n => pure n
      | none => pure defaultBroadcastTimeoutSecs
  | none => pure defaultBroadcastTimeoutSecs

/-- Parse a `0x`-prefixed transaction hash printed by cast's --async
    output. cast prints the hex on a line by itself. -/
private def extractTxHash (stdout : String) : Option String := do
  let lines := (stdout.splitOn "\n").map String.trim
  lines.find? (fun line =>
    line.startsWith "0x" && line.length == 66 &&
      ((line.toList.drop 2).all (fun c =>
        ('0' ≤ c ∧ c ≤ '9') || ('a' ≤ c ∧ c ≤ 'f') || ('A' ≤ c ∧ c ≤ 'F'))))

/-- Poll `eth_getTransactionReceipt` until the tx is mined or the
    timeout elapses. Emits `tx-pending` notifications every poll while
    the receipt is still null. Returns the receipt JSON on success, or
    a string error on timeout / RPC failure. -/
private partial def waitForReceipt
    (cfg : Config) (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (txHash : String) (deadlineMs startMs : Nat) :
    IO (Except String Json) := do
  let now ← IO.monoMsNow
  if now ≥ deadlineMs then
    pure (.error s!"timed out waiting for receipt after {(now - startMs) / 1000}s")
  else
    match ← LeanKohaku.RPC.Outbound.getTransactionReceipt cfg.policy cfg.rpcEndpoint txHash with
    | .error err => pure (.error err)
    | .ok json =>
        match json with
        | .null =>
            notify "tx-pending" (.obj #[
              ("txHash", .str txHash),
              ("elapsedSec", .num (Int.ofNat ((now - startMs) / 1000)))
            ])
            IO.sleep 5000
            waitForReceipt cfg notify txHash deadlineMs startMs
        | _ => pure (.ok json)

/-- End-to-end R1 send flow:
    1. shell out to `prepare-digest(-eth)` to compute the digest;
    2. natively run `signSepoliaDigest` so biometric notifications stream live;
    3. shell out to `broadcast-signed` (which uses `cast send --async`);
    4. poll `eth_getTransactionReceipt` until mined or timeout, with
       `tx-broadcasted`, `tx-pending`, `tx-mined` notifications.
    The script-side calls are still captured via `IO.Process.output`,
    but biometric prompts are now in-process Lean and reach the CLI in
    real time over the existing UDS notification channel. -/
private def r1SendFlow (cfg : Config) (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (keyName to : String) (amount : String) (mode : String) :
    IO (Except RpcError Json) := do
  let scriptEnv : Array (String × Option String) := #[("LEAN_KOHAKU_TPM_KEY", some keyName)]
  -- Step 1: digest preparation. The script prints `<digest> <account> <wei>`
  -- on stdout and any `cast`/setup chatter on stderr.
  let prepArgs : Array String :=
    if mode == "eth" then #["prepare-digest-eth", to, amount]
    else #["prepare-digest", to, amount]
  let (prepCode, prepOut, prepErr) ← runScriptSplit prepArgs scriptEnv
  if prepCode != 0 then
    return .error
      { code := -32040,
        message := "r1 digest preparation failed",
        data := some (.str (prepOut ++ prepErr)) }
  let tokens := prepOut.trim.splitOn " " |>.filter (fun t => t.trim != "")
  match tokens with
  | digest :: account :: wei :: _ =>
      -- Step 2: native biometric+TPM2 sign with live notifications.
      let report ← signSepoliaDigest digest { keyName := keyName } notify
      match report.status with
      | .signed =>
          let some sigHex := report.signatureHex
            | pure (.error
                { code := -32041,
                  message := "tpm sign returned no signature hex",
                  data := none })
          -- Step 3: broadcast.
          let (bcCode, bcOut, bcErr) ← runScriptSplit
            #["broadcast-signed", sigHex, to, wei] scriptEnv
          if bcCode != 0 then
            return .error
              { code := -32042,
                message := "r1 broadcast failed",
                data := some (.str (bcOut ++ bcErr)) }
          match extractTxHash bcOut with
          | none =>
              pure <| .error
                { code := -32042,
                  message := "could not parse txHash from broadcast output",
                  data := some (.str (bcOut ++ bcErr)) }
          | some txHash =>
              notify "tx-broadcasted" (.obj #[
                ("txHash", .str txHash),
                ("from", .str account),
                ("to", .str to),
                ("valueWei", .str wei)
              ])
              -- Step 4: wait for receipt with periodic notifications.
              let timeoutSecs ← broadcastTimeoutSecs
              let startMs ← IO.monoMsNow
              let deadlineMs := startMs + timeoutSecs * 1000
              match ← waitForReceipt cfg notify txHash deadlineMs startMs with
              | .error err =>
                  let weiN := wei.toNat?.getD 0
                  journalRecord keyName account to txHash "" "r1.send"
                    weiN 0 cfg.chainId none (some "pending") none none
                  pure <| .ok <| .obj #[
                    ("text", .str s!"R1 send broadcast {txHash} but receipt wait failed: {err}\n"),
                    ("exitCode", .num 1),
                    ("status", .str "pending"),
                    ("txHash", .str txHash),
                    ("from", .str account),
                    ("to", .str to),
                    ("valueWei", .str wei),
                    ("error", .str err)
                  ]
              | .ok receipt =>
                  let blockNumber := (getField "blockNumber" receipt >>= asString).getD ""
                  let gasUsed := (getField "gasUsed" receipt >>= asString).getD ""
                  let effectiveGasPrice :=
                    (getField "effectiveGasPrice" receipt >>= asString).getD ""
                  let statusHex := (getField "status" receipt >>= asString).getD "0x0"
                  let success := statusHex == "0x1"
                  notify "tx-mined" (.obj #[
                    ("txHash", .str txHash),
                    ("blockNumber", .str blockNumber),
                    ("gasUsed", .str gasUsed),
                    ("effectiveGasPrice", .str effectiveGasPrice),
                    ("status", .str (if success then "success" else "revert"))
                  ])
                  let weiN := wei.toNat?.getD 0
                  journalRecord keyName account to txHash "" "r1.send"
                    weiN 0 cfg.chainId none
                    (some (if success then "success" else "revert"))
                    (some blockNumber) (some gasUsed)
                  let summary :=
                    s!"R1 send {txHash}\n  from: {account}\n  to: {to}\n  valueWei: {wei}\n  block: {humanBlock blockNumber}\n  gasUsed: {humanGas gasUsed}\n  effectiveGasPrice: {humanGwei effectiveGasPrice}\n  status: {if success then "success" else "revert"}\n"
                  pure <| .ok <| .obj #[
                    ("text", .str summary),
                    ("exitCode", .num (Int.ofNat (if success then 0 else 1))),
                    ("status", .str (if success then "success" else "revert")),
                    ("txHash", .str txHash),
                    ("from", .str account),
                    ("to", .str to),
                    ("valueWei", .str wei),
                    ("blockNumber", .str blockNumber),
                    ("gasUsed", .str gasUsed),
                    ("effectiveGasPrice", .str effectiveGasPrice),
                    ("receipt", receipt)
                  ]
      | other =>
          pure <| .error
            { code := -32043,
              message := "tpm sign failed: " ++ signStatusText other,
              data := none }
  | _ =>
      pure <| .error
        { code := -32040,
          message := "r1 digest preparation produced unexpected output",
          data := some (.str prepOut) }

def methodHandler (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "daemon.ping" =>
      let shuttingDown ← LeanKohaku.Daemon.State.isShuttingDown state
      pure <| .ok <| .obj #[
        ("ok", .bool true),
        ("version", .str LeanKohaku.version),
        ("uptime", .num 0),
        ("locked", .arr ((← LeanKohaku.Daemon.State.unlockedNames state).toArray.map Json.str)),
        ("chainId", .num (Int.ofNat cfg.chainId)),
        ("shuttingDown", .bool shuttingDown)
      ]
  | "daemon.version" =>
      pure <| .ok <| .obj #[
        ("version", .str LeanKohaku.version),
        ("rpcSchemaMajor", .num 1)
      ]
  | "daemon.shutdown" =>
      LeanKohaku.Daemon.State.requestShutdown state
      discard <| IO.asTask (exitSoon cfg.socketPath)
      pure <| .ok <| .obj #[("ok", .bool true)]
  | "tpm.create" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          let report ← createR1Key { keyName := keyName } notify
          pure <| .ok <| textResultJson (tpm2CreateReportText report) report.status.exitCode
  -- Back-compat alias kept for one release; delegates to tpm.create.
  | "tpm.createSepolia" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          let report ← createR1Key { keyName := keyName } notify
          pure <| .ok <| textResultJson (tpm2CreateReportText report) report.status.exitCode
  | "tpm.deploy" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "chain" with
          | .error err => pure (.error err)
          | .ok chain =>
              match chain with
              | "sepolia" =>
                  if accepted sepoliaR1Smart then
                    let (exitCode, text) ← runScript #["deploy"]
                      #[("LEAN_KOHAKU_TPM_KEY", some keyName)]
                    pure <| .ok <| textResultJson text exitCode
                  else
                    pure <| .ok <| textResultJson
                      "Sepolia R1 account policy rejected\n" 1
              | "mainnet" =>
                  pure <| .ok <| textResultJson
                    "mainnet R1 deploy is not enabled yet; deploy and verify the account path on Sepolia first\n" 2
              | other =>
                  pure <| .ok <| textResultJson
                    s!"unsupported chain: {other} (expected sepolia or mainnet)\n" 2
  | "tpm.listSepolia" =>
      let names ← listSepoliaKeys
      pure <| .ok <| textResultJson (formatKeyList names) 0
  | "tpm.listSepoliaAddresses" =>
      let names ← listSepoliaKeys
      let stateDir : System.FilePath := ".leankohaku/keystore/tpm2"
      let mut entries : Array Json := #[]
      for name in names do
        let addrFile := stateDir / name / "r1-account-address.txt"
        let address ←
          if ← addrFile.pathExists then
            let raw ← IO.FS.readFile addrFile
            pure raw.trim
          else pure ""
        entries := entries.push <| .obj #[
          ("name", .str name),
          ("address", .str address)
        ]
      pure (.ok (.arr entries))
  | "tpm.signSepolia" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "digest" with
          | .error err => pure (.error err)
          | .ok digest =>
              let report ← signSepoliaDigest digest { keyName := keyName } notify
              pure <| .ok <| textResultJson (tpm2SignReportText report) report.status.exitCode
  | "r1.sendSepolia" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "to", paramString req.params "amountWei" with
          | .ok to, .ok amountWei =>
              r1SendFlow cfg notify keyName to amountWei "wei"
          | _, _ => pure (.error invalidParams)
  | "r1.sendEthSepolia" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "to", paramString req.params "amountEth" with
          | .ok to, .ok amountEth =>
              r1SendFlow cfg notify keyName to amountEth "eth"
          | _, _ => pure (.error invalidParams)
  | "chain.balance" =>
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanKohaku.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let block := paramStringD req.params "block" "latest"
              match ← LeanKohaku.RPC.Outbound.getBalance cfg.policy cfg.rpcEndpoint address block with
              | .ok balance =>
                  pure <| .ok <| .obj #[
                    ("address", .str address),
                    ("block", .str block),
                    ("balance", balance)
                  ]
              | .error err =>
                  pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.nonce" =>
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanKohaku.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let block := paramStringD req.params "block" "pending"
              match ← LeanKohaku.RPC.Outbound.getTransactionCount cfg.policy cfg.rpcEndpoint address block with
              | .ok nonce =>
                  pure <| .ok <| .obj #[
                    ("address", .str address),
                    ("block", .str block),
                    ("nonce", nonce)
                  ]
              | .error err =>
                  pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.gasPrice" =>
      match ← LeanKohaku.RPC.Outbound.gasPrice cfg.policy cfg.rpcEndpoint with
      | .ok gasPrice =>
          pure <| .ok <| .obj #[("gasPrice", gasPrice)]
      | .error err =>
          pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.maxPriorityFeePerGas" =>
      match ← LeanKohaku.RPC.Outbound.maxPriorityFeePerGas cfg.policy cfg.rpcEndpoint with
      | .ok maxPriorityFeePerGas =>
          pure <| .ok <| .obj #[("maxPriorityFeePerGas", maxPriorityFeePerGas)]
      | .error err =>
          pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.estimateGas" =>
      match paramTxRequest req.params with
      | .error err => pure (.error err)
      | .ok tx =>
          let block := paramStringD req.params "block" "latest"
          match ← LeanKohaku.RPC.Outbound.estimateGas cfg.policy cfg.rpcEndpoint tx block with
          | .ok gas =>
              pure <| .ok <| .obj #[
                ("tx", tx),
                ("block", .str block),
                ("gas", gas)
              ]
          | .error err =>
              pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.tokenBalance" =>
      match paramString req.params "token", paramString req.params "owner" with
      | .ok token, .ok owner =>
          match LeanKohaku.Ethereum.Address.fromHex token, LeanKohaku.Ethereum.Address.fromHex owner with
          | some _, some ownerAddr =>
              let block := paramStringD req.params "block" "latest"
              let data := erc20BalanceOfData ownerAddr
              match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy cfg.rpcEndpoint token data block with
              | .ok balance =>
                  pure <| .ok <| .obj #[
                    ("token", .str token),
                    ("owner", .str owner),
                    ("block", .str block),
                    ("balance", balance)
                  ]
              | .error err =>
                  pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
          | _, _ => pure (.error invalidParams)
      | _, _ => pure (.error invalidParams)
  | "chain.sendRawTransaction" =>
      match paramString req.params "raw" with
      | .error err => pure (.error err)
      | .ok raw =>
          match LeanKohaku.Crypto.Hex.decode raw with
          | none => pure (.error invalidParams)
          | some bytes =>
              if bytes.isEmpty then
                pure (.error invalidParams)
              else
                match ← LeanKohaku.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint raw with
                | .ok txHash =>
                    pure <| .ok <| .obj #[
                      ("raw", .str raw),
                      ("txHash", txHash)
                    ]
                | .error err =>
                    pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.resolveName" =>
      match paramString req.params "name" with
      | .error err => pure (.error err)
      | .ok name =>
          -- Why: ENS names are canonical on mainnet; the wallet's operating
          -- chainId is irrelevant for resolution. Always query mainnet (chainId 1)
          -- against the user-configured ENS RPC; no fallback to cfg.rpcEndpoint.
          match cfg.ensRpcEndpoint with
          | none =>
              pure <| .error {
                code := -32030,
                message :=
                  "no ENS RPC configured: set LEANKOHAKU_ENS_RPC_URL or 'ens_rpc_url' in daemon.json (mainnet RPC required for ENS resolution)",
                data := none }
          | some ensEndpoint =>
              match ← LeanKohaku.Ethereum.Ens.resolveIO cfg.policy ensEndpoint 1 name with
              | .ok r =>
                  pure <| .ok <| .obj #[
                    ("name", .str r.name),
                    ("address", .str r.address),
                    ("chainId", .num (Int.ofNat r.chainId)),
                    ("resolver", .str r.resolver)
                  ]
              | .error (code, msg) =>
                  pure <| .error { code := code, message := msg, data := none }
  | "eoa.list" =>
      let names ← LeanKohaku.Wallet.EoaStore.list
      let records ← names.foldlM
        (fun acc name => do
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .ok record => pure (acc.push (← slotMetadataJson state record))
          | .error _ => pure acc)
        #[]
      pure (.ok (.arr records))
  | "eoa.show" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .ok record => pure (.ok (← slotMetadataJson state record))
          | .error err =>
              pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
  | "eoa.address" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .ok record => pure (.ok (.str record.address))
          | .error err =>
              pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
  | "eoa.import" =>
      match ← saveMnemonicSlot req.params none with
      | .error err => pure (.error err)
      | .ok (record, _) => pure (.ok (← importResultJson state record))
  | "eoa.create" =>
      try
        let wordCount := paramNatD req.params "wordCount" 12
        let mnemonic ← LeanKohaku.Wallet.Entropy.generateMnemonic wordCount
        match ← saveMnemonicSlot req.params (some mnemonic) with
        | .error err => pure (.error err)
        | .ok (record, mnemonic?) => pure (.ok (← importResultJson state record mnemonic?))
      catch e =>
        pure <| .error { invalidParams with data := some (.str e.toString) }
  | "eoa.unlock" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match ← LeanKohaku.Wallet.EoaStore.load name with
              | .error err =>
                  pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
              | .ok record =>
                  match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
                  | .error err =>
                      pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                  | .ok seed =>
                      LeanKohaku.Daemon.State.unlock state {
                        name := record.name,
                        seed := seed,
                        address := record.address,
                        derivationPath := record.derivationPath,
                        unlockedAtMs := ← IO.monoMsNow,
                        ttlMs := 300000
                      }
                      pure (.ok (← slotMetadataJson state record))
  | "eoa.lock" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          LeanKohaku.Daemon.State.lock state name
          pure (.ok (.obj #[("ok", .bool true)]))
  | "eoa.derive" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              let path := paramStringD req.params "path" slot.derivationPath
              match ← deriveAddressFromSeed slot.seed path with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok address =>
                  pure <| .ok <| .obj #[
                    ("name", .str name),
                    ("path", .str path),
                    ("address", .str address)
                  ]
  | "eoa.signDigest" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "digest" req.params >>= asBytes with
              | none => pure (.error invalidParams)
              | some digest =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanKohaku.Wallet.EOA.signDigestIO privateKey digest with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok sig => pure (.ok (signatureJson sig))
  | "eoa.signMessage" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "message" req.params >>= asBytes with
              | none => pure (.error invalidParams)
              | some msg =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanKohaku.Wallet.EOA.signPersonalMessageIO msg privateKey with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok sig => pure (.ok (signatureJson sig))
  | "eoa.signTx" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match paramTx req.params with
              | .error err => pure (.error err)
              | .ok tx =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanKohaku.Wallet.EOA.signEip1559IO tx privateKey with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok signed =>
                          pure <| .ok <| .obj #[
                            ("raw", .str (LeanKohaku.Crypto.Hex.encode signed.encode)),
                            ("signature", signatureJson signed.sig)
                          ]
  | "eoa.signTypedData" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "typedData" req.params with
              | none => pure (.error invalidParams)
              | some typedData =>
                  match ← LeanKohaku.Ethereum.Eip712.computeDigestIO typedData with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok d =>
                      match ← resolveSigningTarget name slot req.params with
                      | .error err => pure (.error err)
                      | .ok (path, addr) =>
                      match ← derivePrivateKeyFromSeed slot.seed path with
                      | .error err =>
                          pure <| .error { invalidParams with data := some (.str err) }
                      | .ok privateKey =>
                          match ← LeanKohaku.Wallet.EOA.signDigestIO privateKey d.digest with
                          | .error err =>
                              pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                          | .ok sig =>
                              -- Why: pack r||s||v into a 65-byte 0x... compact signature
                              let r := LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 sig.r
                              let s := LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 sig.s
                              let v := ByteArray.empty.push sig.v
                              let compactSig := r ++ s ++ v
                              pure <| .ok <| .obj #[
                                ("signature", .str (LeanKohaku.Crypto.Hex.encode compactSig)),
                                ("digest", .str (LeanKohaku.Crypto.Hex.encode d.digest)),
                                ("domainSeparator", .str (LeanKohaku.Crypto.Hex.encode d.domainSeparator)),
                                ("messageHash", .str (LeanKohaku.Crypto.Hex.encode d.messageHash)),
                                ("primaryType", .str d.primaryType),
                                ("recoveredAddress", .str addr),
                                ("rsv", signatureJson sig)
                              ]
  | "eoa.send" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match paramString req.params "to", paramNat req.params "value" with
              | .ok to, .ok value =>
                  match LeanKohaku.Ethereum.Address.fromHex to with
                  | none => pure (.error invalidParams)
                  | some toAddress =>
                      match txBytesFieldD req.params "data" with
                      | .error err => pure (.error err)
                      | .ok data =>
                          match ← resolveSigningTarget name slot req.params with
                          | .error err => pure (.error err)
                          | .ok (path, fromAddr) =>
                          match ← derivePrivateKeyFromSeed slot.seed path with
                          | .error err =>
                              pure <| .error { invalidParams with data := some (.str err) }
                          | .ok privateKey =>
                              -- Why: re-target slot at the resolved account so nonce/from come from the right address.
                              let slot' := { slot with address := fromAddr, derivationPath := path }
                              let r ← buildSignBroadcastTx cfg slot' privateKey to toAddress value data none (some notify)
                              -- Why: best-effort journal write; never fails the tx.
                              match r with
                              | .ok j =>
                                  let getStr (k : String) : String :=
                                    (getField k j >>= asString).getD ""
                                  let txHash := getStr "txHash"
                                  let nonceN := (parseHexQuantity (getStr "nonce")).getD 0
                                  let dataHex := LeanKohaku.Crypto.Hex.encode data
                                  let acc? := getField "account" req.params >>= asNat
                                  let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                                  let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                                  let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                                  if !txHash.isEmpty then
                                    journalRecord slot.name fromAddr to txHash dataHex "eoa.send"
                                      value nonceN cfg.chainId acc? status? block? gas?
                              | .error _ => pure ()
                              pure r
              | _, _ => pure (.error invalidParams)
  | "eoa.delete" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match ← LeanKohaku.Wallet.EoaStore.load name with
              | .error err =>
                  pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
              | .ok record =>
                  match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
                  | .error err =>
                      pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                  | .ok _ =>
                      LeanKohaku.Daemon.State.lock state name
                      LeanKohaku.Wallet.EoaStore.delete name
                      pure (.ok (.obj #[("ok", .bool true)]))
  | "eoa.account.list" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← loadRecord name with
          | .error err => pure (.error err)
          | .ok record =>
              let arr := (recordAccounts record).map accountToJson
              pure <| .ok <| .obj #[("accounts", .arr arr)]
  | "eoa.account.add" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match ← loadRecord name with
              | .error err => pure (.error err)
              | .ok record =>
                  let existing := recordAccounts record
                  let idx := nextAccountIndex record
                  -- Why: caller may pass an explicit BIP-44 path; otherwise auto-pick m/44'/60'/0'/0/<idx>.
                  let pathE : Except String String :=
                    match getField "path" req.params >>= asString with
                    | some p => .ok p
                    | none => LeanKohaku.Wallet.Bip44.canonicalEthereumPath 0 0 idx
                  match pathE with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok path =>
                      -- Reject duplicate path (would create two accounts at the same address).
                      if existing.any (fun a => a.path = path) then
                        pure <| .error { code := -32015, message := "account path already exists",
                                         data := some (.str s!"path {path} already present") }
                      else
                        match ← deriveAddressFromSeed slot.seed path with
                        | .error err =>
                            pure <| .error { invalidParams with data := some (.str err) }
                        | .ok address =>
                            let label : Option String := getField "label" req.params >>= asString
                            let newAcc : LeanKohaku.Wallet.EoaStore.Account :=
                              { index := idx, path := path, address := address, label := label }
                            let updated : LeanKohaku.Wallet.EoaStore.Record :=
                              { record with accounts := existing.push newAcc }
                            LeanKohaku.Wallet.EoaStore.save updated
                            pure <| .ok (accountToJson newAcc)
  | "eoa.account.rm" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match paramNat req.params "index" with
              | .error err => pure (.error err)
              | .ok idx =>
                  if idx = 0 then
                    pure <| .error { code := -32016,
                                     message := "cannot remove account index 0 (primary)",
                                     data := none }
                  else
                    match ← loadRecord name with
                    | .error err => pure (.error err)
                    | .ok record =>
                        match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
                        | .error err =>
                            pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                        | .ok _ =>
                            let existing := recordAccounts record
                            match existing.find? (fun a => a.index = idx) with
                            | none =>
                                pure <| .error { code := -32014,
                                                 message := s!"account index {idx} not found in slot",
                                                 data := none }
                            | some removed =>
                                let kept := existing.filter (fun a => a.index != idx)
                                let updated : LeanKohaku.Wallet.EoaStore.Record :=
                                  { record with accounts := kept }
                                LeanKohaku.Wallet.EoaStore.save updated
                                pure <| .ok <| .obj #[
                                  ("ok", .bool true),
                                  ("removed", accountToJson removed)
                                ]
  | "shielded.ping" =>
      let resp ← LeanKohaku.Privacy.Bridge.ping
      pure <| .ok <| LeanKohaku.Privacy.Bridge.responseToJson resp
  | "shielded.balance" =>
      match paramString req.params "passphrase" with
      | .error err => pure (.error err)
      | .ok passphrase =>
          match ← unlockPpSecret passphrase with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.balance" (.obj #[]) mnemonic req
  | "shielded.prepareDeposit" =>
      match paramString req.params "amountEth", paramString req.params "passphrase" with
      | .ok amountEth, .ok passphrase =>
          match ← unlockPpSecret passphrase with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.prepareDeposit"
                (.obj #[("amountEth", .str amountEth)]) mnemonic req
      | _, _ => pure (.error invalidParams)
  | "shielded.deposit" =>
      match paramName req.params, paramString req.params "amountEth", paramString req.params "passphrase" with
      | .ok name, .ok amountEth, .ok passphrase =>
          IO.eprintln s!"[shield] deposit: wallet={name} amountEth={amountEth}"
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              IO.eprintln s!"[shield] unlocked slot {name} address={slot.address}"
              match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok privateKey =>
                  let mnemonicE ← do
                    if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
                      IO.eprintln "[shield] no PP secret on disk; generating fresh 12-word mnemonic"
                      try
                        let m ← LeanKohaku.Wallet.Entropy.generateMnemonic 12
                        let phrase := LeanKohaku.Wallet.Mnemonic.phrase m
                        match ← LeanKohaku.Wallet.PpSecretStore.save passphrase phrase with
                        | .error err =>
                            pure (.error
                              ({ code := -32022,
                                 message := "failed to persist generated PP secret",
                                 data := some (.str err) } : RpcError))
                        | .ok _ =>
                            IO.eprintln "[shield] PP secret generated and persisted"
                            pure (.ok phrase)
                      catch e =>
                        pure (.error
                          ({ code := -32022,
                             message := "failed to generate PP secret",
                             data := some (.str e.toString) } : RpcError))
                    else
                      IO.eprintln "[shield] decrypting stored PP secret"
                      unlockPpSecret passphrase
                  match mnemonicE with
                  | .error err => pure (.error err)
                  | .ok mnemonic =>
                      IO.eprintln "[shield] calling bridge shielded.prepareDeposit (this loads the SDK and syncs PP state from chain; may take 30-60s on first run)"
                      match ← shieldedBridgeCall cfg "shielded.prepareDeposit"
                                (.obj #[("amountEth", .str amountEth)]) mnemonic req with
                      | .error err =>
                          IO.eprintln s!"[shield] bridge prepare failed: {err.message}"
                          pure (.error err)
                      | .ok prepared =>
                          IO.eprintln "[shield] bridge returned prepared deposit; decoding txns"
                          let resultField :=
                            match getField "result" prepared with
                            | some r => r
                            | none => prepared
                          let txnsArr := getField "txns" resultField >>= asArray
                          match txnsArr with
                          | none =>
                              IO.eprintln "[shield] bridge returned no txns array"
                              pure <| .error
                                { code := -32020,
                                  message := "bridge returned no txns",
                                  data := some prepared }
                          | some txns =>
                              IO.eprintln s!"[shield] signing and broadcasting {txns.size} tx(s)"
                              match ← signAndBroadcastBridgeTxns cfg slot privateKey txns (some notify) with
                              | .error err =>
                                  IO.eprintln s!"[shield] broadcast failed: {err.message}"
                                  pure (.error err)
                              | .ok sent =>
                                  IO.eprintln s!"[shield] broadcast complete: {sent.size} tx(s) sent"
                                  pure <| .ok <| .obj #[
                                    ("prepared", prepared),
                                    ("sent", .arr sent)
                                  ]
      | _, _, _ => pure (.error invalidParams)
  | "shielded.prepareWithdraw" =>
      match paramString req.params "recipient", paramString req.params "amountEth", paramString req.params "passphrase" with
      | .ok recipient, .ok amountEth, .ok passphrase =>
          match ← unlockPpSecret passphrase with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.prepareWithdraw"
                (.obj #[("recipient", .str recipient), ("amountEth", .str amountEth)]) mnemonic req
      | _, _, _ => pure (.error invalidParams)
  | "shielded.unshieldDrain" =>
      match paramString req.params "recipient", paramString req.params "amountEth", paramString req.params "passphrase" with
      | .ok recipient, .ok amountEth, .ok passphrase =>
          match ← unlockPpSecret passphrase with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.unshieldDrain"
                (.obj #[("recipient", .str recipient), ("amountEth", .str amountEth)]) mnemonic req
      | _, _, _ => pure (.error invalidParams)
  | "shielded.reveal" =>
      match paramString req.params "passphrase" with
      | .error err => pure (.error err)
      | .ok passphrase =>
          match ← unlockPpSecret passphrase with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              pure <| .ok <| .obj #[("mnemonic", .str mnemonic)]
  | "shielded.import" =>
      match paramString req.params "passphrase", paramString req.params "mnemonic" with
      | .ok passphrase, .ok mnemonic =>
          if (← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
            pure <| .error
              { code := -32023,
                message := "PP secret already stored — run 'kohaku shield delete' first",
                data := none }
          else
            match ← LeanKohaku.Wallet.PpSecretStore.save passphrase mnemonic with
            | .error err =>
                pure <| .error
                  { code := -32022, message := "failed to persist PP secret",
                    data := some (.str err) }
            | .ok _ =>
                pure <| .ok <| .obj #[("ok", .bool true)]
      | _, _ => pure (.error invalidParams)
  | "chain.history" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          let limit? : Option Nat := getField "limit" req.params >>= asNat
          let entries ← LeanKohaku.Daemon.TxJournal.read name limit?
          pure (.ok (.arr entries))
  | "chain.scanTransfers" =>
      -- Why: chunked eth_getLogs. The 32-byte-padded address goes in topic1
      -- (out) and topic2 (in); two queries per chunk merged & deduped.
      match getField "addresses" req.params >>= asArray with
      | none => pure (.error invalidParams)
      | some arr =>
          -- Why: pick endpoint at call time so users can scan history on a
          -- chain other than the one the daemon's default RPC points at.
          -- Fail closed when the requested chain has no configured endpoint.
          let chain? := getField "chain" req.params >>= asString
          match endpointForChain cfg chain? with
          | .error msg =>
              pure (.error { code := -32602, message := msg, data := none })
          | .ok scanEndpoint =>
              let addresses := arr.filterMap asString
              let chunkSize ← do
                match getField "chunkSize" req.params >>= asNat with
                | some n => pure n
                | none =>
                    match ← IO.getEnv "KOHAKU_GETLOGS_MAX_BLOCK_SPAN" with
                    | some s => pure (s.toNat?.getD 5000)
                    | none => pure 5000
              -- Resolve fromBlock/toBlock.
              let fromBlock ← do
                match getField "fromBlock" req.params >>= asNat with
                | some n => pure n
                | none => pure 0
              let toBlock ← do
                match getField "toBlock" req.params >>= asNat with
                | some n => pure n
                | none =>
                    match ← LeanKohaku.RPC.Outbound.blockNumber cfg.policy scanEndpoint with
                    | .ok j =>
                        pure ((asString j >>= parseHexQuantity).getD 0)
                    | .error _ => pure 0
              let topic0 := "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
              let padAddr (a : String) : String :=
                let raw := stripHexPrefix a |>.toLower
                "0x" ++ String.mk (List.replicate (64 - raw.length) '0') ++ raw
              -- Reset cancellation flag for this scan. Why: `chain.cancel`
              -- sets it to `true`; if a previous run set it and was never
              -- consumed, we'd abort before doing any work.
              LeanKohaku.Daemon.State.beginScan state
              -- Wall-clock cap: timeout is orthogonal to user-initiated cancel.
              -- Default 5 min; overridable via env or per-call `maxMs` param.
              -- Reject 0/negative — fall back to default to avoid an instantly
              -- expiring scan or a non-terminating loop on a parse error.
              let defaultMaxMs : Nat := 300000
              let envMaxMs : Nat ← do
                match ← IO.getEnv "KOHAKU_SCAN_MAX_MS" with
                | some s =>
                    match s.toNat? with
                    | some n => if n = 0 then pure defaultMaxMs else pure n
                    | none => pure defaultMaxMs
                | none => pure defaultMaxMs
              let maxMs : Nat :=
                match getField "maxMs" req.params >>= asNat with
                | some n => if n = 0 then envMaxMs else n
                | none => envMaxMs
              let started ← IO.monoMsNow
              let mut events : Array Json := #[]
              let mut seen : Array String := #[]
              let mut errAcc : Option String := none
              let mut cancelled : Bool := false
              let mut timedOut : Bool := false
              let mut lastScanned : Nat := fromBlock
              for addr in addresses do
                if cancelled || timedOut then pure ()
                else
                  let topicAddr := padAddr addr
                  let mut cur := fromBlock
                  -- Bound the chunk loop; chunkSize=0 would loop forever.
                  let span := if chunkSize = 0 then 5000 else chunkSize
                  let mut fuel := 5000
                  while cur ≤ toBlock && fuel > 0 && !cancelled && !timedOut do
                    let chunkTo := if cur + span > toBlock then toBlock else cur + span
                    let fromHex := natQuantityHex cur
                    let toHex := natQuantityHex chunkTo
                    -- Outbound (from = topic1)
                    let topicsOut : Array Json :=
                      #[.str topic0, .str topicAddr, .null]
                    -- Inbound (to = topic2)
                    let topicsIn : Array Json :=
                      #[.str topic0, .null, .str topicAddr]
                    for topicsArr in [topicsOut, topicsIn] do
                      if cancelled || timedOut then pure ()
                      else
                        -- Check cancel flag before each outbound call so the
                        -- second of the two queries can be skipped too.
                        if (← LeanKohaku.Daemon.State.isScanCancelled state) then
                          cancelled := true
                        else
                          match ← LeanKohaku.RPC.Outbound.call cfg.policy scanEndpoint
                              .getLogs (.arr #[.obj #[
                                ("fromBlock", .str fromHex),
                                ("toBlock", .str toHex),
                                ("topics", .arr topicsArr)
                              ]]) with
                          | .error e => errAcc := some e
                          | .ok logsJson =>
                              match asArray logsJson with
                              | none => pure ()
                              | some logs =>
                                  for log in logs do
                                    let txHash := (getField "transactionHash" log >>= asString).getD ""
                                    let logIdx := (getField "logIndex" log >>= asString).getD ""
                                    let key := txHash ++ "#" ++ logIdx
                                    if seen.contains key then pure ()
                                    else
                                      seen := seen.push key
                                      events := events.push log
                    lastScanned := chunkTo
                    cur := chunkTo + 1
                    fuel := fuel - 1
                    -- Re-check after the chunk so the next chunk is skipped
                    -- promptly when cancellation arrives.
                    if !cancelled && (← LeanKohaku.Daemon.State.isScanCancelled state) then
                      cancelled := true
                    -- Wall-clock check: orthogonal to cancel; surfaces as
                    -- `timedOut` in the result so the CLI can prompt resume.
                    if !timedOut then
                      let nowMs ← IO.monoMsNow
                      if nowMs - started ≥ maxMs then
                        timedOut := true
              -- Persist last-scanned-block for at least one address (the first).
              -- If we cancelled mid-scan, persist the last fully-attempted
              -- chunk boundary so the next run can resume.
              let persistedTo :=
                if cancelled || timedOut then lastScanned else toBlock
              if let some firstSlot := getField "slotName" req.params >>= asString then
                LeanKohaku.Daemon.TxJournal.writeScanState firstSlot persistedTo
              let resultJson : Json := .obj #[
                ("events", .arr events),
                ("fromBlock", .num (Int.ofNat fromBlock)),
                ("toBlock", .num (Int.ofNat toBlock)),
                ("cancelled", .bool cancelled),
                ("timedOut", .bool timedOut),
                ("maxMs", .num (Int.ofNat maxMs)),
                ("lastScannedBlock", .num (Int.ofNat persistedTo))
              ]
              match errAcc with
              | none => pure (.ok resultJson)
              | some _ => pure (.ok resultJson)
  | "chain.cancel" =>
      -- Idempotent: signal any in-flight `chain.scanTransfers` to abort at
      -- the next chunk boundary. Safe to call when no scan is running.
      LeanKohaku.Daemon.State.cancelScan state
      pure <| .ok <| .obj #[("ok", .bool true)]
  | "chain.indexerHistory" =>
      -- Why: opt-in third-party history lookup. The daemon refuses unless
      -- the indexer is allow-listed in daemon.json, *and* the network
      -- policy permits indexerLookup. Strict mode rejects.
      match paramString req.params "address", paramString req.params "indexer" with
      | .ok address, .ok indexerName =>
          match cfg.indexers.find? (fun e => e.name = indexerName) with
          | none =>
              pure <| .error
                { code := -32030,
                  message := s!"indexer '{indexerName}' not enabled — run 'kohaku network allow-indexer {indexerName}'",
                  data := none }
          | some entry =>
              let polReq : NetworkRequest :=
                { peer := .thirdPartyApi, purpose := .indexerLookup,
                  transport := .direct }
              if !(cfg.policy polReq) then
                pure <| .error
                  { code := -32031,
                    message := "network policy denies indexer lookup (strict mode)",
                    data := none }
              else
                let envKey := "LEANKOHAKU_" ++ indexerName.toUpper ++ "_KEY"
                let apiKey ← IO.getEnv envKey
                let key := apiKey.getD ""
                let url1 := s!"{entry.url}?chainid={cfg.chainId}&module=account&action=txlist&address={address}&apikey={key}"
                let url2 := s!"{entry.url}?chainid={cfg.chainId}&module=account&action=tokentx&address={address}&apikey={key}"
                let fetch (u : String) : IO Json := do
                  try
                    let out ← IO.Process.output
                      { cmd := "curl", args := #["-sS", u] }
                    if out.exitCode != 0 then pure .null
                    else
                      match parse out.stdout with
                      | .ok j => pure j
                      | .error _ => pure .null
                  catch _ => pure .null
                let txList ← fetch url1
                let tokenTx ← fetch url2
                pure <| .ok <| .obj #[
                  ("indexer", .str indexerName),
                  ("address", .str address),
                  ("txlist", txList),
                  ("tokentx", tokenTx)
                ]
      | _, _ => pure (.error invalidParams)
  | "shielded.delete" =>
      match paramString req.params "passphrase" with
      | .error err => pure (.error err)
      | .ok passphrase =>
          if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
            pure (.error ppSecretMissing)
          else
            match ← LeanKohaku.Wallet.PpSecretStore.unlock passphrase with
            | .error err =>
                pure <| .error
                  { code := -32011, message := "PP secret unlock failed",
                    data := some (.str err) }
            | .ok _ =>
                LeanKohaku.Wallet.PpSecretStore.delete
                pure <| .ok <| .obj #[("ok", .bool true)]
  | "eoa.attestation.status" =>
      let initialized ← LeanKohaku.Keystore.MasterKey.existsOnDisk
      let names ← LeanKohaku.Wallet.EoaStore.list
      let entries ← names.foldlM
        (fun acc name => do
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .ok r =>
              pure <| acc.push <| .obj #[
                ("name", .str r.name),
                ("attestationWrapped", .bool r.attestationWrap.isSome)
              ]
          | .error _ => pure acc)
        (#[] : Array Json)
      pure <| .ok <| .obj #[
        ("initialized", .bool initialized),
        ("slots", .arr entries)
      ]
  | "eoa.attestation.bootstrap" =>
      match getField "slots" req.params >>= asArray with
      | none => pure (.error invalidParams)
      | some slotsArr =>
          -- Why: get/derive the master key once. If absent, bootstrap a new
          -- one (biometric inside). Both paths require a single biometric.
          let masterRes ← do
            if ← LeanKohaku.Keystore.MasterKey.existsOnDisk then
              LeanKohaku.Keystore.MasterKey.unsealWithBiometric notify
            else
              match ← LeanKohaku.Keystore.MasterKey.bootstrap notify with
              | .error err => pure (.error err)
              | .ok _ => LeanKohaku.Keystore.MasterKey.unsealWithBiometric notify
          match masterRes with
          | .error err =>
              pure <| .error
                { code := -32020, message := "master attestation key unavailable",
                  data := some (.str err) }
          | .ok masterKey =>
              let mut results : Array Json := #[]
              for entry in slotsArr do
                let nameOpt := getField "name" entry >>= asString
                let passOpt := getField "passphrase" entry >>= asString
                match nameOpt, passOpt with
                | some name, some passphrase =>
                    match ← LeanKohaku.Wallet.EoaStore.load name with
                    | .error err =>
                        results := results.push <| .obj #[
                          ("name", .str name), ("ok", .bool false),
                          ("error", .str err)]
                    | .ok record =>
                        match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
                        | .error err =>
                            results := results.push <| .obj #[
                              ("name", .str name), ("ok", .bool false),
                              ("error", .str s!"unlock failed: {err}")]
                        | .ok seed =>
                            match ← LeanKohaku.Wallet.EoaStore.wrapWithMaster masterKey name seed with
                            | .error err =>
                                results := results.push <| .obj #[
                                  ("name", .str name), ("ok", .bool false),
                                  ("error", .str s!"wrap failed: {err}")]
                            | .ok wrap =>
                                let updated := { record with attestationWrap := some wrap }
                                LeanKohaku.Wallet.EoaStore.save updated
                                results := results.push <| .obj #[
                                  ("name", .str name), ("ok", .bool true)]
                | _, _ =>
                    results := results.push <| .obj #[
                      ("name", .str (nameOpt.getD "")), ("ok", .bool false),
                      ("error", .str "missing name or passphrase")]
              pure <| .ok <| .obj #[("results", .arr results)]
  | "eoa.attestation.unlockAll" =>
      match ← LeanKohaku.Keystore.MasterKey.unsealWithBiometric notify with
      | .error err =>
          pure <| .error
            { code := -32020, message := "master attestation key unavailable",
              data := some (.str err) }
      | .ok masterKey =>
          let names ← LeanKohaku.Wallet.EoaStore.list
          let mut unlocked : Array Json := #[]
          let mut skipped : Array Json := #[]
          for name in names do
            match ← LeanKohaku.Wallet.EoaStore.load name with
            | .error err =>
                skipped := skipped.push <| .obj #[
                  ("name", .str name), ("reason", .str err)]
            | .ok record =>
                match record.attestationWrap with
                | none =>
                    skipped := skipped.push <| .obj #[
                      ("name", .str name), ("reason", .str "no-wrap")]
                | some wrap =>
                    match ← LeanKohaku.Wallet.EoaStore.unwrapWithMaster masterKey name wrap with
                    | .error err =>
                        skipped := skipped.push <| .obj #[
                          ("name", .str name), ("reason", .str err)]
                    | .ok seed =>
                        LeanKohaku.Daemon.State.unlock state {
                          name := record.name,
                          seed := seed,
                          address := record.address,
                          derivationPath := record.derivationPath,
                          unlockedAtMs := ← IO.monoMsNow,
                          ttlMs := 300000
                        }
                        unlocked := unlocked.push (.str name)
          pure <| .ok <| .obj #[
            ("unlocked", .arr unlocked),
            ("skipped", .arr skipped)
          ]
  | _ =>
      pure (.error methodNotFound)

private def ensureParentDir (socketPath : String) : IO Unit := do
  let path : System.FilePath := socketPath
  match path.parent with
  | some parent => IO.FS.createDirAll parent
  | none => pure ()

private def listenerFromSocketActivation? : IO (Option LeanKohaku.Daemon.Uds.Listener) := do
  if ← socketActivated then
    pure (some { fd := 3 })
  else
    pure none

private def decodeRequestBytes (bytes : ByteArray) : Except String String :=
  match String.fromUTF8? bytes with
  | some s => .ok s.trimAscii.toString
  | none => .error "request was not valid UTF-8"

def handleConn (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (conn : LeanKohaku.Daemon.Uds.Conn) : IO Unit := do
  try
    let started ← IO.monoMsNow
    let sameUid ← LeanKohaku.Daemon.Uds.peerUidMatchesCurrent conn
    if !sameUid then
      let response := compact <| errorResponse .null
        { code := -32001, message := "peer uid rejected" }
      discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
      LeanKohaku.Daemon.Log.write .warn "<peer>" ((← IO.monoMsNow) - started) false
        (some "peer uid rejected")
    else
      let bytes ← LeanKohaku.Daemon.Uds.read conn
      match decodeRequestBytes bytes with
      | .error err =>
          let response := compact <| errorResponse .null
            { parseError with data := some (.str err) }
          discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
          LeanKohaku.Daemon.Log.write .warn "<parse>" ((← IO.monoMsNow) - started) false
            (some err)
      | .ok line =>
          let parsed := LeanKohaku.RPC.Server.parseRequest line
          let method :=
            match parsed with
            | .ok req => req.method
            | .error _ => "<parse>"
          -- UDS-backed notifier: emit JSON-RPC notification frames
          -- (no `id`, no `result`/`error`) on the same connection
          -- before the final response. The CLI client buffers and
          -- splits on `\n`, rendering each notification before
          -- returning the response.
          let notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier :=
            fun event params => do
              let frame : Json := .obj #[
                ("jsonrpc", .str "2.0"),
                ("method", .str "notify"),
                ("params", .obj #[
                  ("event", .str event),
                  ("data", params)
                ])
              ]
              try
                discard <| LeanKohaku.Daemon.Uds.write conn (compact frame ++ "\n").toByteArray
              catch _ => pure ()
          let response ←
            match parsed with
            | .error err => pure (compact <| errorResponse .null err)
            | .ok req => do
                let json ← LeanKohaku.RPC.Server.dispatch (methodHandler cfg state notify) req
                pure (compact json)
          discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
          LeanKohaku.Daemon.Log.write .info method ((← IO.monoMsNow) - started) true
  finally
    LeanKohaku.Daemon.Uds.close conn

partial def acceptLoop (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (listener : LeanKohaku.Daemon.Uds.Listener) : IO Unit := do
  let conn ← LeanKohaku.Daemon.Uds.accept listener
  discard <| IO.asTask (handleConn cfg state conn)
  if !(← LeanKohaku.Daemon.State.isShuttingDown state) then
    acceptLoop cfg state listener

/-- Probe the configured socket to detect whether another daemon is already
    listening on it.

    Returns:
    * `some "already running"` — connect succeeded and a `daemon.ping` round-trip
      either completed within the timeout, or the read window elapsed without
      the peer hanging up. Either way, *something* owns the socket and is
      accepting connections, so we must not start a second instance.
    * `none` — no live daemon (no socket file, or stale socket file removed).

    The probe is bounded to ~250 ms so a half-dead peer cannot stall startup.
    Stale socket files (connect fails with ENOENT or ECONNREFUSED but the path
    still exists / does not exist) are handled by inspecting `pathExists` after
    a connect failure: if the path exists, the file is stale and we remove it. -/
private def detectExistingDaemon (path : String) : IO (Option String) := do
  -- Try to connect. A successful connect means *some* listener is bound.
  let connAttempt ← IO.asTask (LeanKohaku.Daemon.Uds.connect path)
  -- We don't want to block forever on a wedged accept(); 250 ms cap.
  let connResult ← (do
    let mut waited : Nat := 0
    let step : Nat := 25
    let cap : Nat := 250
    let mut done : Option (Except IO.Error LeanKohaku.Daemon.Uds.Conn) := none
    while waited < cap && done.isNone do
      match ← IO.getTaskState connAttempt with
      | .finished =>
          done := some connAttempt.get
      | _ =>
          IO.sleep step.toUInt32
          waited := waited + step
    pure done)
  match connResult with
  | none =>
      -- connect() still pending after 250 ms — assume something is bound but
      -- wedged; refuse to start a second instance rather than racing.
      pure (some "already running (probe timed out)")
  | some (.error _) =>
      -- ECONNREFUSED / ENOENT both surface as IO errors here. Distinguish via
      -- the filesystem: if the path exists, the file is a stale leftover.
      let fp : System.FilePath := path
      if ← fp.pathExists then
        IO.eprintln s!"leankohaku-daemon: removed stale socket {path}"
        try IO.FS.removeFile path catch _ => pure ()
      pure none
  | some (.ok conn) =>
      -- Live listener accepted us. Send a daemon.ping and look for any reply,
      -- but don't block startup if the peer is slow — receiving the connect()
      -- alone is already proof of a competing daemon.
      let pingFrame :=
        "{\"jsonrpc\":\"2.0\",\"method\":\"daemon.ping\",\"params\":[],\"id\":1}\n"
      try
        discard <| LeanKohaku.Daemon.Uds.write conn pingFrame.toByteArray
      catch _ => pure ()
      let readTask ← IO.asTask (LeanKohaku.Daemon.Uds.read conn)
      let mut waited : Nat := 0
      let step : Nat := 25
      let cap : Nat := 250
      while waited < cap do
        match ← IO.getTaskState readTask with
        | .finished => waited := cap
        | _ =>
            IO.sleep step.toUInt32
            waited := waited + step
      try LeanKohaku.Daemon.Uds.close conn catch _ => pure ()
      pure (some "already running")

def run (cfg : Config) : IO Unit := do
  let ownsSocket := !(← socketActivated)
  -- Single-instance guard: if we are NOT socket-activated and another daemon
  -- already owns the configured socket, refuse to start a second instance
  -- rather than splitting auto-spawn / network-log state across processes.
  -- Socket activation is skipped because systemd guarantees uniqueness on its
  -- side and there is no path to probe (the fd comes via LISTEN_FDS).
  if !(← socketActivated) then
    match ← detectExistingDaemon cfg.socketPath with
    | some _ =>
        IO.eprintln s!"leankohaku-daemon: another instance is already listening on {cfg.socketPath} (pid unknown); refusing to start a second instance"
        IO.Process.exit 0
    | none => pure ()
  let listener ←
    match ← listenerFromSocketActivation? with
    | some listener => pure listener
    | none =>
        ensureParentDir cfg.socketPath
        LeanKohaku.Daemon.Uds.bind cfg.socketPath
  let state ← LeanKohaku.Daemon.State.new
  IO.eprintln s!"leankohaku-daemon: listening on {cfg.socketPath}"
  try
    acceptLoop cfg state listener
  finally
    LeanKohaku.Daemon.Uds.closeListener listener
    if ownsSocket then
      removeSocketFile cfg.socketPath

end LeanKohaku.Daemon.Server
