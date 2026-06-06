import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Hex
import LeanCli.Crypto.Random
import LeanCli.Crypto.Secp256k1Native
import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.State
import LeanCli.Keystore.MasterPassphrase
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Tx
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Wallet.Address
import LeanCli.Wallet.Bip44
import LeanCli.Wallet.EOA
import LeanCli.Wallet.EoaStore
import LeanCli.Wallet.ExecuteBatch
import LeanCli.Wallet.HDKey
import LeanCli.Wallet.Mnemonic
import LeanCli.Wallet.SphincsHybridStore

/-!
# Daemon server: format & path primitives

Pure (or near-pure) helpers hoisted out of `LeanCli/Daemon/Server.lean`.
No dependency on `Config`, no IO beyond `defaultAccountPathIO`'s env lookup.
Used by every RPC family for rendering, hex/quantity parsing, and
account-path resolution.
-/

namespace LeanCli.Daemon.Server

open LeanCli.Encoding.Json
open LeanCli.RPC.Server

def defaultDerivationPath : String := "m/44'/60'/0'/0/0"

/-- Resolve the default-account file path, owned by the daemon (CLI is a
    thin forwarder). Honors `XDG_CONFIG_HOME`, falls back to `~/.config`,
    finally `.` for testing without `HOME`. Same semantics the CLI used to
    implement directly. -/
def defaultAccountPathIO : IO System.FilePath := do
  let dir : System.FilePath ← match ← IO.getEnv "XDG_CONFIG_HOME" with
    | some d => pure (System.FilePath.mk d)
    | none =>
        match ← IO.getEnv "HOME" with
        | some h => pure (System.FilePath.mk h / ".config")
        | none => pure (System.FilePath.mk ".")
  pure (dir / "leancli" / "default-account.txt")

/-- Decode a `0x`-prefixed hex string into `Nat`. Returns `none` on any
    non-hex character. Used to humanize hex receipt fields for the text
    summary; the wire JSON keeps raw hex. -/
def hexNat? (s : String) : Option Nat :=
  let chars := s.toList
  let body :=
    match chars with
    | '0' :: 'x' :: rest => rest
    | '0' :: 'X' :: rest => rest
    | _ => chars
  if body.isEmpty then none
  else
    body.foldl (init := some 0) fun acc c =>
      match acc, LeanCli.Crypto.Hex.hexDigit? c with
      | some n, some d => some (n * 16 + d.toNat)
      | _, _ => none

def formatGweiNat (n : Nat) : String :=
  let whole := n / 1000000000
  let frac := n % 1000000000
  if frac = 0 then s!"{whole} gwei"
  else
    let str := toString frac
    let pad := String.ofList (List.replicate (9 - str.length) '0')
    let trimmed := ((pad ++ str).dropEndWhile (· = '0')).toString
    s!"{whole}.{trimmed} gwei"

def formatEthNat (n : Nat) : String :=
  let whole := n / 1000000000000000000
  let frac := n % 1000000000000000000
  if frac = 0 then s!"{whole} ETH"
  else
    let str := toString frac
    let pad := String.ofList (List.replicate (18 - str.length) '0')
    let trimmed := ((pad ++ str).dropEndWhile (· = '0')).toString
    s!"{whole}.{trimmed} ETH"

def humanEth (weiNat : Nat) : String :=
  s!"{formatEthNat weiNat}  ({weiNat} wei)"

/-- Render a hex-encoded wei amount as gwei, falling back to the raw hex
    if decode fails (so a malformed receipt never produces an empty field). -/
def humanGwei (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{formatGweiNat n}  ({hex})"
  | none   => hex

/-- Render a hex-encoded gas count as decimal. -/
def humanGas (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{n}  ({hex})"
  | none   => hex

/-- Render a hex-encoded block number as decimal. -/
def humanBlock (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{n}  ({hex})"
  | none   => hex

/-- Big-endian byte-array → Nat. -/
def bytesToNat (bytes : ByteArray) : Nat :=
  bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

/-- Nibble → lowercase hex char. -/
def hexChar (n : Nat) : Char :=
  match n with
  | 0 => '0' | 1 => '1' | 2 => '2' | 3 => '3'
  | 4 => '4' | 5 => '5' | 6 => '6' | 7 => '7'
  | 8 => '8' | 9 => '9' | 10 => 'a' | 11 => 'b'
  | 12 => 'c' | 13 => 'd' | 14 => 'e' | _ => 'f'

/-- Lowercase or uppercase hex char → nibble. -/
def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then
    some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then
    some (10 + c.toNat - 'a'.toNat)
  else if 'A' ≤ c && c ≤ 'F' then
    some (10 + c.toNat - 'A'.toNat)
  else
    none

/-- Drop a leading `0x`/`0X` if present; otherwise return the input unchanged. -/
def stripHexPrefix (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then
    (s.drop 2).toString
  else
    s

partial def natHexDigits : Nat → List Char → List Char
  | 0, acc => acc
  | n, acc => natHexDigits (n / 16) (hexChar (n % 16) :: acc)

/-- Encode a `Nat` as an Ethereum JSON-RPC "quantity" (`0x`-prefixed minimal hex). -/
def natQuantityHex (n : Nat) : String :=
  match n with
  | 0 => "0x0"
  | _ => "0x" ++ String.ofList (natHexDigits n [])

partial def parseHexQuantityDigits : List Char → Nat → Option Nat
  | [], acc => some acc
  | c :: cs, acc => do
      let d ← hexDigit? c
      parseHexQuantityDigits cs (acc * 16 + d)

/-- Parse an Ethereum JSON-RPC "quantity" (with or without `0x` prefix) into a `Nat`. -/
def parseHexQuantity (s : String) : Option Nat :=
  let raw := stripHexPrefix s
  if raw.isEmpty then
    none
  else
    parseHexQuantityDigits raw.toList 0

/-- Extract a hex-quantity `Nat` from a JSON string, failing with `invalidParams`. -/
def jsonHexNat (json : Json) : Except RpcError Nat :=
  match asString json with
  | none => .error invalidParams
  | some s =>
      match parseHexQuantity s with
      | none => .error invalidParams
      | some n => .ok n

/-- IO-throwing variant of `jsonHexNat` — used inside `IO` blocks that already
    propagate failures via `IO.userError`. -/
def jsonHexNatIO (json : Json) (what : String) : IO Nat := do
  match jsonHexNat json with
  | .ok n => pure n
  | .error _ => throw <| IO.userError s!"invalid hex quantity for {what}"

/-- Resolve the `name` parameter from either `{"name": "..."}` (object form,
    preferred) or `["...", ...]` (positional, first-arg form). -/
def paramName (params : Json) : Except RpcError String :=
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

/-- Read a required `String` field from a JSON-RPC `params` object. -/
def paramString (params : Json) (key : String) : Except RpcError String :=
  match getField key params >>= asString with
  | some value => .ok value
  | none => .error invalidParams

/-- Read an optional `String` field; returns `default` when absent. -/
def paramStringD (params : Json) (key default : String) : String :=
  match getField key params >>= asString with
  | some value => value
  | none => default

/-- Read an optional `Nat` field; returns `default` when absent. -/
def paramNatD (params : Json) (key : String) (default : Nat) : Nat :=
  match getField key params >>= asNat with
  | some value => value
  | none => default

/-- Read a required `Nat` field. -/
def paramNat (params : Json) (key : String) : Except RpcError Nat :=
  match getField key params >>= asNat with
  | some value => .ok value
  | none => .error invalidParams

/-- Read a `Nat` parameter from either a JSON integer (preferred — bigint
    serialised as a bare numeric literal by `tui/src/daemon.ts`) or a
    `String` containing a `0x`-prefixed hex quantity or a plain decimal.
    Generic helper for callers that ship a hex `value`. -/
def paramNatOrHexStr (params : Json) (key : String) : Except RpcError Nat :=
  match getField key params with
  | none => .error invalidParams
  | some (.num n) =>
      if n ≥ 0 then .ok n.toNat else .error invalidParams
  | some (.str s) =>
      let trimmed := s.trimAscii.toString
      if trimmed.isEmpty then .error invalidParams
      else if trimmed.startsWith "0x" || trimmed.startsWith "0X" then
        match parseHexQuantity trimmed with
        | some n => .ok n
        | none   => .error invalidParams
      else
        match trimmed.toNat? with
        | some n => .ok n
        | none   => .error invalidParams
  | _ => .error invalidParams

/-- Canonical `{ text, exitCode }` JSON envelope returned by RPCs whose
    result is a human-readable text blob (script wrappers, status reports). -/
def textResultJson (text : String) (exitCode : UInt32) : Json :=
  .obj #[
    ("text", .str text),
    ("exitCode", .num (Int.ofNat exitCode.toNat))
  ]

/-- IO-promoting unwrap: `Except String α → IO α`. Throws `IO.userError`
    with the error string on `.error`. Used to thread `Except`-returning
    pure code into `IO` blocks without per-call boilerplate. -/
def expectExcept {α : Type} : Except String α → IO α
  | .ok value => pure value
  | .error err => throw <| IO.userError err

/-- ERC-20 `Transfer(address,address,uint256)` event signature. -/
def transferEventTopic : String :=
  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

/-- Walk a callTracer+withLog trace tree and pull every token address that
    appears as the emitter of a `Transfer` log. Used to prefetch ERC-20
    metadata so the TUI can render "100 USDC" instead of raw uint256.
    `partial` because the callTracer tree is recursive without a bounded
    measure; in practice depth is small. -/
partial def collectTransferTokens : Json → Array String
  | .obj fields =>
      let lookup (k : String) :=
        (fields.find? (fun (key, _) => key = k)).map Prod.snd
      let fromLogs : Array String :=
        match lookup "logs" with
        | some (.arr logArr) =>
            logArr.filterMap fun log =>
              match log with
              | .obj lf =>
                  let ll (k : String) : Option Json :=
                    (lf.find? (fun (key, _) => key = k)).map Prod.snd
                  let isTransfer : Bool :=
                    match ll "topics" with
                    | some (Json.arr topics) =>
                        match (topics[0]? : Option Json) with
                        | some (Json.str s) => s.toLower = transferEventTopic
                        | _ => false
                    | _ => false
                  if isTransfer then ll "address" >>= asString else (none : Option String)
              | _ => none
        | _ => #[]
      let fromCalls : Array String :=
        match lookup "calls" with
        | some (.arr children) =>
            children.foldl (fun acc c => acc ++ collectTransferTokens c) #[]
        | _ => #[]
      fromLogs ++ fromCalls
  | _ => #[]

/-- Scan ABI-encoded calldata for 32-byte words that look like addresses
    (12 leading zero bytes + 20 nonzero bytes). Returns lowercased
    0x-prefixed addresses, deduplicated, in first-seen order. -/
partial def scanCalldataAddrLoop
    (chars : List Char) (acc : Array String) : Array String :=
  let word := chars.take 64
  if word.length < 64 then acc
  else
    let lead := word.take 24
    let addrChars := word.drop 24
    let leadAllZero := lead.all (· == '0')
    let nonzeroCount := addrChars.foldl (fun n c => if c == '0' then n else n + 1) 0
    let acc' :=
      if leadAllZero && nonzeroCount ≥ 10 then
        let canonical := "0x" ++ (String.ofList addrChars).toLower
        if acc.contains canonical then acc else acc.push canonical
      else acc
    scanCalldataAddrLoop (chars.drop 8) acc'

/-- Scan calldata for embedded 20-byte addresses (multicall-style inner
    parameters). Skips the outer 4-byte selector; entropy guard rejects
    small uint256 values that happen to fit in 160 bits. -/
def scanCalldataAddresses (data : String) : Array String :=
  let chars := data.toList
  let chars := match chars with
    | '0' :: 'x' :: rest => rest
    | _ => chars
  scanCalldataAddrLoop (chars.drop 8) #[]

/-- ABI-encode an ERC-20 `balanceOf(address)` call (selector `0x70a08231`
    + 32-byte left-zero-padded owner). Used by chain.* and swap.* fan-outs. -/
def erc20BalanceOfData (owner : LeanCli.Ethereum.Address.Address) : String :=
  "0x70a08231" ++ String.ofList (List.replicate 24 '0') ++ stripHexPrefix (LeanCli.Crypto.Hex.encode owner.bytes)

/-- BIP-44 secp256k1 derivation: `seed → EIP-55 checksum address at `path``.
    Validates the path, derives the secp256k1 child key, recovers the
    uncompressed public key, and formats the address with the EIP-55
    mixed-case checksum. Used by chat.draft's freshAddress synth path and
    by every UI surface that materialises a derived address. -/
def deriveAddressFromSeed (seed : ByteArray) (path : String) :
    IO (Except String String) := do
  try
    discard <| expectExcept (LeanCli.Wallet.Bip44.validateEthereumPath path)
    let master ← expectExcept (← LeanCli.Wallet.HDKey.fromSeedIO seed)
    let child ← expectExcept (← LeanCli.Wallet.HDKey.derivePathIO master path)
    let pub ← expectExcept <| ← LeanCli.Crypto.Secp256k1Native.pubkeyIO
      (LeanCli.Crypto.Hex.encode (LeanCli.Wallet.HDKey.Nat.toFixedBytes 32 child.key))
      false
    let address ← expectExcept <| ← LeanCli.Wallet.Address.addressFromUncompressedPubkeyIO pub
    LeanCli.Wallet.Address.eip55Checksum address
  catch e =>
    pure (.error e.toString)

/-- Stable per-seed identifier used by the trusted-registry RPC. Defined
    as the lowercased 16-character hex prefix (first 8 bytes) of
    `keccak256(masterCompressedPubkey)`, where `masterCompressedPubkey`
    is BIP-32's compressed master public key. Leaks no secret. -/
def seedFingerprintFromSeed (seed : ByteArray) :
    IO (Except String String) := do
  try
    let master ← expectExcept (← LeanCli.Wallet.HDKey.fromSeedIO seed)
    let pub ← expectExcept <| ← LeanCli.Crypto.Secp256k1Native.pubkeyIO
      (LeanCli.Crypto.Hex.encode (LeanCli.Wallet.HDKey.Nat.toFixedBytes 32 master.key))
      true
    let digest ← expectExcept <| ← LeanCli.Crypto.Hacl.keccak256EthereumIO
      (LeanCli.Crypto.Hex.encode pub)
    -- `Hex.encode` is already `0x`-prefixed — no manual prefix (would double it).
    pure (.ok (LeanCli.Crypto.Hex.encode (LeanCli.Wallet.HDKey.take digest 0 8)))
  catch e =>
    pure (.error e.toString)

/-- BIP-44 secp256k1 derivation: `seed → 32-byte private key at `path``.
    Validates the path under `LeanCli.Wallet.Bip44.validateEthereumPath`
    before deriving. Used by every EOA signing path. -/
def derivePrivateKeyFromSeed (seed : ByteArray) (path : String) :
    IO (Except String ByteArray) := do
  try
    discard <| expectExcept (LeanCli.Wallet.Bip44.validateEthereumPath path)
    let master ← expectExcept (← LeanCli.Wallet.HDKey.fromSeedIO seed)
    let child ← expectExcept (← LeanCli.Wallet.HDKey.derivePathIO master path)
    pure (.ok (LeanCli.Wallet.HDKey.Nat.toFixedBytes 32 child.key))
  catch e =>
    pure (.error e.toString)

/-- Why: a freshly read record may carry a synthesized accounts list (when
    the on-disk JSON predates multi-account). Always returns a non-empty array
    with index 0 mirroring the primary path/address. -/
def recordAccounts (r : LeanCli.Wallet.EoaStore.Record) :
    Array LeanCli.Wallet.EoaStore.Account :=
  if r.accounts.isEmpty then
    #[{ index := 0, path := r.derivationPath, address := r.address, label := none }]
  else
    r.accounts

/-- Render an EOA account as JSON; thin wrapper over EoaStore. -/
def accountToJson (a : LeanCli.Wallet.EoaStore.Account) : Json :=
  LeanCli.Wallet.EoaStore.Account.toJson a

/-- Find an account on a record by index. -/
def findAccount (r : LeanCli.Wallet.EoaStore.Record) (idx : Nat) :
    Option LeanCli.Wallet.EoaStore.Account :=
  (recordAccounts r).find? (fun a => a.index = idx)

/-- Pick the smallest non-negative integer not already used as an account index. -/
def nextAccountIndex (r : LeanCli.Wallet.EoaStore.Record) : Nat :=
  let used := (recordAccounts r).map (fun a => a.index)
  let rec loop (n : Nat) (fuel : Nat) : Nat :=
    match fuel with
    | 0 => n
    | fuel + 1 => if used.contains n then loop (n + 1) fuel else n
  loop 0 (used.size + 1)

/-- Resolve the optional `account` parameter into a `(path, address)` pair.
    If absent, returns the slot's primary (mirrors `derivationPath`/`address`).
    If present, looks up the account on the loaded record. -/
def resolveAccount
    (r : LeanCli.Wallet.EoaStore.Record)
    (slot : LeanCli.Daemon.State.UnlockedSlot)
    (params : Json) : Except RpcError (String × String) :=
  match getField "account" params >>= asNat with
  | none => .ok (slot.derivationPath, slot.address)
  | some idx =>
      match findAccount r idx with
      | some a => .ok (a.path, a.address)
      | none =>
          .error { code := -32014, message := s!"account index {idx} not found in slot",
                   data := some (.str s!"slot has no account with index={idx}") }

/-- Load an EOA record by slot name; transparently retries on the base
    name (before any `/sub-account` suffix) so callers can pass display
    forms like `leanWallet/0` directly. -/
def loadRecord (name : String) :
    IO (Except RpcError LeanCli.Wallet.EoaStore.Record) := do
  match ← LeanCli.Wallet.EoaStore.load name with
  | .ok r => pure (.ok r)
  | .error _ =>
      let baseName := (name.splitOn "/").headD name
      if baseName.length == name.length then
        pure (.error { code := -32010, message := "EOA slot not found", data := some (.str name) })
      else
        match ← LeanCli.Wallet.EoaStore.load baseName with
        | .ok r => pure (.ok r)
        | .error err =>
            pure (.error { code := -32010, message := "EOA slot not found", data := some (.str err) })

/-- Format a Secp256k1 signature as `{r, s, v}` JSON. -/
def signatureJson (sig : LeanCli.Crypto.Secp256k1.Signature) : Json :=
  .obj #[
    ("r", .str (LeanCli.Crypto.Hex.encode (LeanCli.Wallet.HDKey.Nat.toFixedBytes 32 sig.r))),
    ("s", .str (LeanCli.Crypto.Hex.encode (LeanCli.Wallet.HDKey.Nat.toFixedBytes 32 sig.s))),
    ("v", .num (Int.ofNat sig.v.toNat))
  ]

/-- Build the JSON `eth_estimateGas` request payload for an unsigned tx. -/
def estimateTxJson (fromAddr to : String) (value : Nat) (data : ByteArray) : Json :=
  .obj #[
    ("from",  .str fromAddr),
    ("to",    .str to),
    ("value", .str (natQuantityHex value)),
    -- `Hex.encode` already emits a `0x`-prefixed string; do NOT prepend
    -- another `0x` or the node rejects `data` as an invalid hex string
    -- ("cannot unmarshal ... TransactionArgs.data") at eth_estimateGas.
    ("data",  .str (LeanCli.Crypto.Hex.encode data))
  ]

/-- Canonical `{to, value, raw, txHash, nonce, gasLimit, ..., signature}`
    JSON envelope returned by every EIP-1559 send RPC. -/
def sendResultJson (to value raw txHash : String)
    (nonce gasLimit maxPriorityFeePerGas maxFeePerGas : Nat)
    (sig : LeanCli.Crypto.Secp256k1.Signature) : Json :=
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

/-- Default broadcast-confirmation timeout (seconds). Overridable via
    `LEANCLI_BROADCAST_TIMEOUT_SECS`. -/
def defaultBroadcastTimeoutSecs : Nat := 90

/-- Read the broadcast-confirmation timeout from env, falling back to the default. -/
def broadcastTimeoutSecs : IO Nat := do
  match ← IO.getEnv "LEANCLI_BROADCAST_TIMEOUT_SECS" with
  | some s =>
      match s.toNat? with
      | some n => pure n
      | none => pure defaultBroadcastTimeoutSecs
  | none => pure defaultBroadcastTimeoutSecs

/-- Sepolia floor for `maxPriorityFeePerGas` — see comments in the original
    Server.lean def for the threshold rationale (1 gwei). -/
def minPriorityFeeWei : Nat := 1_000_000_000

/-- Poll `eth_getTransactionReceipt` until mined or the timeout elapses.
    Emits `tx-pending` notifications every poll while the receipt is null. -/
partial def waitForReceiptShared
    (cfg : Config) (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (txHash : String) (deadlineMs startMs : Nat)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia := none) :
    IO (Except String Json) := do
  let now ← IO.monoMsNow
  if now ≥ deadlineMs then
    pure (.error s!"timed out waiting for receipt after {(now - startMs) / 1000}s")
  else
    match ← LeanCli.RPC.Outbound.getTransactionReceipt cfg.policy cfg.rpcEndpoint txHash via? with
    | .error err => pure (.error err)
    | .ok json =>
        match json with
        | .null =>
            notify "tx-pending" (.obj #[
              ("txHash", .str txHash),
              ("elapsedSec", .num (Int.ofNat ((now - startMs) / 1000)))
            ])
            IO.sleep 5000
            waitForReceiptShared cfg notify txHash deadlineMs startMs via?
        | _ => pure (.ok json)

/-- Broadcast a signed raw EIP-1559 tx and await its receipt, streaming
    tx-broadcasted / tx-pending / tx-mined / tx-timeout notifications. -/
def broadcastAndAwait
    (cfg : Config) (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (rawTxHex from_ to : String) (valueWei : Nat)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia := none) :
    IO (Except RpcError Json) := do
  match ← LeanCli.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint rawTxHex with
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
          let timeoutSecs ← broadcastTimeoutSecs
          let startMs ← IO.monoMsNow
          let deadlineMs := startMs + timeoutSecs * 1000
          match ← waitForReceiptShared cfg notify txHash deadlineMs startMs via? with
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
    instead of querying `eth_getTransactionCount`. -/
def buildSignBroadcastTx
    (cfg : Config) (slot : LeanCli.Daemon.State.UnlockedSlot)
    (privateKey : ByteArray) (to : String) (toAddress : LeanCli.Ethereum.Address.Address)
    (value : Nat) (data : ByteArray) (nonceOverride? : Option Nat)
    (notify? : Option LeanCli.Keystore.Tpm2Runtime.Notifier := none)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia := none)
    (priorityFeeOverride? : Option Nat := none) :
    IO (Except RpcError Json) := do
  try
    let nonce ←
      match nonceOverride? with
      | some n => pure n
      | none =>
          let nonceJson ← expectExcept <| (← LeanCli.RPC.Outbound.getTransactionCount cfg.policy cfg.rpcEndpoint slot.address "pending" via?)
          jsonHexNatIO nonceJson "nonce"
    let priorityJson ← expectExcept <| (← LeanCli.RPC.Outbound.maxPriorityFeePerGas cfg.policy cfg.rpcEndpoint via?)
    let gasPriceJson ← expectExcept <| (← LeanCli.RPC.Outbound.gasPrice cfg.policy cfg.rpcEndpoint via?)
    let rpcPriorityFee ← jsonHexNatIO priorityJson "maxPriorityFeePerGas"
    let maxPriorityFeePerGas :=
      match priorityFeeOverride? with
      | some t => t
      | none   => Nat.max rpcPriorityFee minPriorityFeeWei
    let gasPrice ← jsonHexNatIO gasPriceJson "gasPrice"
    let maxFeePerGas := 2 * gasPrice + maxPriorityFeePerGas
    let estimateRequest := estimateTxJson slot.address to value data
    let gasJson ← expectExcept <| (← LeanCli.RPC.Outbound.estimateGas cfg.policy cfg.rpcEndpoint estimateRequest "latest" none)
    let gasLimit ← jsonHexNatIO gasJson "gasLimit"
    let tx : LeanCli.Ethereum.Tx.TxEip1559 := {
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
    match ← LeanCli.Wallet.EOA.signEip1559IO tx privateKey with
    | .error err =>
        pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
    | .ok signed =>
        let raw := LeanCli.Crypto.Hex.encode signed.encode
        match notify? with
        | none =>
            match ← LeanCli.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint raw with
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
            match ← broadcastAndAwait cfg notify raw slot.address to value via? with
            | .error err => pure (.error err)
            | .ok extras =>
                let txHash := (getField "txHash" extras >>= asString).getD ""
                let base := sendResultJson to (toString value) raw txHash
                  nonce gasLimit maxPriorityFeePerGas maxFeePerGas signed.sig
                match base, extras with
                | .obj baseFields, .obj extraFields =>
                    let merged := extraFields.foldl
                      (fun acc (k, v) =>
                        if k == "txHash" then acc else acc.push (k, v))
                      baseFields
                    pure (.ok (.obj merged))
                | _, _ => pure (.ok base)
  catch e =>
    pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str e.toString) }

/-- Extract the `tx` field from a JSON-RPC params object as a fresh JSON
    object. Used by `chain.estimateGas` / `chain.ethCall` / etc. -/
def paramTxRequest (params : Json) : Except RpcError Json :=
  match getField "tx" params with
  | some (.obj fields) => .ok (.obj fields)
  | some _ => .error invalidParams
  | none => .error invalidParams

/-- Resolve an unlocked-slot record for a slot name with sub-account-tolerant
    retry. The TUI's wallet objects carry display names like `leanWallet/0`;
    the unlocked-slot table is keyed by the base slot name (before `/`). -/
def unlockedSlot (state : LeanCli.Daemon.State.Shared) (name : String) :
    IO (Except RpcError LeanCli.Daemon.State.UnlockedSlot) := do
  match ← LeanCli.Daemon.State.getUnlocked? state name with
  | some slot => pure (.ok slot)
  | none =>
      let baseName := (name.splitOn "/").headD name
      if baseName.length == name.length then
        pure (.error { code := -32012, message := "EOA slot is locked" })
      else
        match ← LeanCli.Daemon.State.getUnlocked? state baseName with
        | some slot => pure (.ok slot)
        | none => pure (.error { code := -32012, message := "EOA slot is locked" })

/-- Resolve the account-kind hint for an address by scanning the daemon's
    local stores. Used by prepare-style RPCs to decide whether to collapse
    a multi-leg result into a single `executeBatch` call.

    Scan order — first hit wins:
    1. SPHINCs- hybrid records' `smartAccountAddress`
    2. (no EOA scan — `.eoa` is the default fall-through anyway)

    Address comparison is case-insensitive on the hex body. Empty / missing
    files are skipped without erroring; this is a best-effort hint, so any
    IO failure quietly falls through to `.eoa` rather than blocking the
    surrounding RPC.

    Caller note: when the JSON-RPC params already carry an explicit
    `accountKind` the caller wins — this helper is only invoked as the
    fallback. -/
def discoverAccountKind (addr : String) :
    IO LeanCli.Wallet.ExecuteBatch.AccountKindHint := do
  let target := addr.toLower
  try
    let sphincsNames ← LeanCli.Wallet.SphincsHybridStore.listSlotNames
    for n in sphincsNames do
      match ← LeanCli.Wallet.SphincsHybridStore.readRecord n with
      | .error _ => pure ()
      | .ok r =>
          match r.smartAccountAddress with
          | some a =>
              if a.toLower = target then
                return LeanCli.Wallet.ExecuteBatch.AccountKindHint.sphincsHybrid
          | none => pure ()
  catch _ => pure ()
  return LeanCli.Wallet.ExecuteBatch.AccountKindHint.eoa

/-- Render slot metadata as a JSON object — name, address, derivation path,
    locked status, creation time. Used by `eoa.show`, `eoa.list`, and the
    import result envelope. -/
def slotMetadataJson (state : LeanCli.Daemon.State.Shared)
    (record : LeanCli.Wallet.EoaStore.Record) : IO Json := do
  let unlocked ← LeanCli.Daemon.State.isUnlocked state record.name
  pure <| .obj #[
    ("name", .str record.name),
    ("address", .str record.address),
    ("derivationPath", .str record.derivationPath),
    ("locked", .bool (!unlocked)),
    ("createdAt", .num (Int.ofNat record.createdAt))
  ]

/-- Parse a BIP-39 mnemonic phrase string into a `Mnemonic`. -/
def mnemonicFromPhrase (phrase : String) : LeanCli.Wallet.Mnemonic.Mnemonic :=
  { words := phrase.splitOn " " |>.filter (fun word => word != "") }

/-- Resolve `(path, address)` for a sign/send operation, considering both
    legacy explicit `path` and new `account` params. `account` takes priority;
    if absent and `path` provided, only path is overridden (address stays
    primary — matches legacy behavior). If neither provided, returns slot
    primary `(derivationPath, address)`. -/
def resolveSigningTarget
    (name : String)
    (slot : LeanCli.Daemon.State.UnlockedSlot) (params : Json) :
    IO (Except RpcError (String × String)) := do
  match getField "account" params >>= asNat with
  | some _ =>
      match ← loadRecord name with
      | .error err => pure (.error err)
      | .ok r => pure (resolveAccount r slot params)
  | none =>
      let path := paramStringD params "path" slot.derivationPath
      pure (.ok (path, slot.address))

/-- Read a required `Nat` field from a JSON tx object. -/
def txNatField (tx : Json) (key : String) : Except RpcError Nat :=
  match getField key tx >>= asNat with
  | some value => .ok value
  | none => .error invalidParams

/-- Read an optional `ByteArray` field from a JSON tx object. -/
def txBytesFieldD (tx : Json) (key : String) (default : ByteArray := ByteArray.empty) :
    Except RpcError ByteArray :=
  match getField key tx with
  | none => .ok default
  | some json =>
      match asBytes json with
      | some bytes => .ok bytes
      | none => .error invalidParams

/-- Read the optional `to` field from a JSON tx object as an `Address`. -/
def txToField (tx : Json) : Except RpcError (Option LeanCli.Ethereum.Address.Address) :=
  match getField "to" tx with
  | none => .ok none
  | some .null => .ok none
  | some (.str s) =>
      match LeanCli.Ethereum.Address.fromHex s with
      | some address => .ok (some address)
      | none => .error invalidParams
  | some _ => .error invalidParams

/-- Parse a full JSON tx object into a structured EIP-1559 tx. -/
def txFromJson (tx : Json) : Except RpcError LeanCli.Ethereum.Tx.TxEip1559 := do
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

/-- Extract an EIP-1559 tx from a params object, accepting either the
    `{tx: {...}}` wrapper form or a bare tx object at top level. -/
def paramTx (params : Json) : Except RpcError LeanCli.Ethereum.Tx.TxEip1559 :=
  match getField "tx" params with
  | some tx => txFromJson tx
  | none => txFromJson params

/-- Save an EOA slot from either a user-supplied or freshly-generated
    mnemonic. Handles the master-KEK fast path (ephemeral per-slot
    passphrase + immediate enrollment) versus the explicit-passphrase
    path. Returns the persisted record + the original mnemonic if one
    was generated (so the caller can surface it). -/
def saveMnemonicSlot
    (state : LeanCli.Daemon.State.Shared)
    (params : Json) (generated : Option LeanCli.Wallet.Mnemonic.Mnemonic := none) :
    IO (Except RpcError (LeanCli.Wallet.EoaStore.Record × Option LeanCli.Wallet.Mnemonic.Mnemonic)) := do
  try
    let name ← expectExcept <| paramString params "name" |>.mapError (fun _ => "missing name")
    let masterSlot? ← LeanCli.Daemon.State.getMasterKek? state
    let userSuppliedPassphrase : Bool :=
      match paramString params "passphrase" with
      | .ok p => p.length > 0
      | .error _ => false
    let passphrase ← match paramString params "passphrase" with
      | .ok p =>
          if p.length > 0 then pure p
          else if masterSlot?.isSome then
            let bytes ← LeanCli.Crypto.Random.getRandomBytes 32
            pure (LeanCli.Crypto.Hex.encode bytes)
          else
            throw <| IO.userError "missing passphrase (no master KEK loaded — set one with `wallet master init` or pick a per-slot passphrase)"
      | .error _ =>
          if masterSlot?.isSome then
            let bytes ← LeanCli.Crypto.Random.getRandomBytes 32
            pure (LeanCli.Crypto.Hex.encode bytes)
          else
            throw <| IO.userError "missing passphrase (no master KEK loaded — set one with `wallet master init` or pick a per-slot passphrase)"
    let derivationPath := paramStringD params "derivationPath" defaultDerivationPath
    let mnemonic ←
      match generated with
      | some m => pure m
      | none =>
          let phrase ← expectExcept <| paramString params "mnemonic" |>.mapError (fun _ => "missing mnemonic")
          pure (mnemonicFromPhrase phrase)
    let seed ← expectExcept <| ← LeanCli.Wallet.Mnemonic.mnemonicToSeedIO mnemonic ""
    let address ← expectExcept <| ← deriveAddressFromSeed seed derivationPath
    let phrase :=
      String.intercalate " " mnemonic.words.toArray.toList
    let baseRecord ← expectExcept <| ← LeanCli.Wallet.EoaStore.saveEncryptedSeed
      name passphrase seed derivationPath address (some phrase)
    let record ←
      if userSuppliedPassphrase && !baseRecord.customPassphrase then
        let updated := { baseRecord with customPassphrase := true }
        try LeanCli.Wallet.EoaStore.save updated
        catch _ => pure ()
        pure updated
      else
        pure baseRecord
    let record ← match masterSlot? with
      | none => pure record
      | some slot =>
          if record.customPassphrase then pure record
          else
            match ← LeanCli.Keystore.MasterPassphrase.wrapSlot
                slot.kek record.name record.derivationPath record.address seed with
            | .error _ => pure record
            | .ok wrap =>
                let updated := { record with masterWrap := some wrap }
                try LeanCli.Wallet.EoaStore.save updated
                catch _ => pure ()
                pure updated
    pure (.ok (record, generated))
  catch e =>
    pure <| .error { invalidParams with data := some (.str e.toString) }

/-- Canonical import-result JSON envelope: slot metadata + (optional)
    revealed mnemonic words for a freshly-created slot. -/
def importResultJson (state : LeanCli.Daemon.State.Shared)
    (record : LeanCli.Wallet.EoaStore.Record)
    (mnemonic? : Option LeanCli.Wallet.Mnemonic.Mnemonic := none) : IO Json := do
  let base ← slotMetadataJson state record
  match base with
  | .obj fields =>
      match mnemonic? with
      | none => pure (.obj fields)
      | some m => pure (.obj (fields.push ("mnemonic", .arr (m.words.toArray.map Json.str))))
  | other => pure other

end LeanCli.Daemon.Server
