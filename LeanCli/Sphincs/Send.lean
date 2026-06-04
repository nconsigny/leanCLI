import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Hex
import LeanCli.Encoding.Json
import LeanCli.RPC.JsonRpc
import LeanCli.Sphincs.UserOp

/-!
# SPHINCS- hybrid UserOperation send helpers

ABI + bundler glue used by `sphincs.account.send`. Kept out of
`Daemon/Server.lean` so the RPC handler stays a thin dispatch.

ERC-4337 v0.9. EntryPoint is the deterministic-deployment singleton at
`0x4337…` on every EVM chain (see `entryPointV09Address`); changing this
is a hardfork-class event for the userOp ecosystem, so we hardcode it
rather than ship a per-chain config item.

Each `bytesN` field is held as a `ByteArray` of length `N`; the helpers
left-pad/`hexToWord32?` only at boundaries that match the EVM ABI's
"static type → 32-byte word" rule.
-/

namespace LeanCli.Sphincs.Send

open LeanCli.Encoding.Json
open LeanCli.Crypto

/-- v0.9 EntryPoint singleton, per the eth-infinitism v0.9.0 release
    notes (https://github.com/eth-infinitism/account-abstraction/releases/tag/v0.9.0).
    NOTE: `lib/sphincs-minus/lib/account-abstraction/deployments/ethereum/EntryPoint.json`
    still lists the pre-v0.9 address `0x4337084D…F108` (which is v0.8) —
    that file is stale relative to the v0.9.0 tag. -/
def entryPointV09Address : String :=
  "0x433709009B8330FDa32311DF1C2AFA402eD8D009"

/-- 4-byte selector for the standard `execute(address,uint256,bytes)`
    BaseAccount entrypoint. Equals `keccak256[..4]`; pinned as a
    constant to skip one runtime keccak per send. -/
def executeSelector : String := "b61d27f6"

/-- 4-byte selector for `getNonce(address,uint192)` on the v0.9
    EntryPoint. Same rationale as `executeSelector`. -/
def entryPointGetNonceSelector : String := "35567e1a"

/-- 4-byte selector for `getDomainSeparatorV4()` (OZ EIP712).

    Note: kept for legacy callers / tests. v0.9 EntryPoint does NOT
    expose this method publicly (OZ EIP712 has only an internal
    `_domainSeparatorV4`), so calling it via `eth_call` reverts with
    "execution reverted, 0x". Compute the domain separator with
    `computeDomainSeparator` instead. -/
def domainSeparatorSelector : String := "20606b06"

/-- Encode a `Nat` as an even-length, lower-case hex string (no `0x`),
    suitable for `Hex.decode`. Single-digit values are zero-padded. -/
def natToEvenHex (n : Nat) : String :=
  let raw := String.ofList (Nat.toDigits 16 n)
  if raw.length % 2 = 0 then raw else "0" ++ raw

/-- `(Hex.decode (natToEvenHex n)).getD ByteArray.empty`, left-padded to
    32 bytes. Used for ABI uint256 fields. -/
def natToWord32 (n : Nat) : ByteArray :=
  UserOp.padLeft32 ((Hex.decode (natToEvenHex n)).getD ByteArray.empty)

/-- Compute the EntryPoint v0.9 EIP-712 domain separator locally,
    matching `EIP712("ERC4337", "1")` baked into the upstream
    constructor. Spec:
      DS = keccak256(abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("ERC4337"),
        keccak256("1"),
        uint256(chainId),
        address(entryPoint)
      ))
    Avoids an eth_call to a method that doesn't exist on v0.9.

    On the off chance that a future EntryPoint rev rotates the name
    or version string, this constant becomes wrong and signatures
    will be rejected on chain. We deliberately do NOT fall back to
    eth_call'ing OZ's `eip712Domain()` (the EIP-5267 multi-tuple
    return) because parsing that here would dwarf this helper.
    Refresh the constants in lockstep with EntryPoint upgrades. -/
def computeDomainSeparator (chainId : Nat) : IO (Except String ByteArray) := do
  let typeStr := "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
  match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
      (LeanCli.Crypto.Hex.encode typeStr.toByteArray) with
  | .error e => pure (.error s!"typehash keccak: {e}")
  | .ok typehash =>
      match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
          (LeanCli.Crypto.Hex.encode "ERC4337".toByteArray) with
      | .error e => pure (.error s!"name keccak: {e}")
      | .ok nameHash =>
          match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
              (LeanCli.Crypto.Hex.encode "1".toByteArray) with
          | .error e => pure (.error s!"version keccak: {e}")
          | .ok versionHash =>
              let chainIdW := natToWord32 chainId
              let epBytes := (LeanCli.Crypto.Hex.decode entryPointV09Address).getD ByteArray.empty
              let epW := UserOp.padLeft32 epBytes
              let payload := typehash ++ nameHash ++ versionHash ++ chainIdW ++ epW
              LeanCli.Crypto.Hacl.keccak256EthereumIO (LeanCli.Crypto.Hex.encode payload)

/-- Build the `callData` field of a PackedUserOperation that targets
    `BaseAccount.execute(to, value, data)`. ABI encoding for the
    `(address,uint256,bytes)` triple:
      selector ‖ pad32(to) ‖ pad32(value) ‖ 0x60 (offset to bytes head)
                ‖ pad32(len(data)) ‖ pad(data, ⌈len/32⌉·32) -/
def buildExecuteCalldata (to : String) (valueWei : Nat) (data : ByteArray) : ByteArray :=
  let sel    := (Hex.decode executeSelector).getD ByteArray.empty
  let toBs   := (UserOp.hexToWord32? to).getD ByteArray.empty
  let valBs  := natToWord32 valueWei
  let offBs  := natToWord32 0x60
  let lenBs  := natToWord32 data.size
  let rem    := data.size % 32
  let padded :=
    if rem = 0 then data
    else data ++ ByteArray.mk (Array.replicate (32 - rem) (0 : UInt8))
  sel ++ toBs ++ valBs ++ offBs ++ lenBs ++ padded

/-- ABI-encode `(bytes ecdsa, bytes sphincs)` as a single dynamic blob.
    Layout:
      head: 32B offset to first (always 0x40) ‖ 32B offset to second
      tail: 32B len(a) ‖ pad(a) ‖ 32B len(b) ‖ pad(b)
    where each pad is to a 32-byte boundary. The result becomes the
    `signature` field of the PackedUserOperation. -/
def abiEncodeBytesPair (a b : ByteArray) : ByteArray :=
  let padR (bs : ByteArray) : ByteArray :=
    let r := bs.size % 32
    if r = 0 then bs
    else bs ++ ByteArray.mk (Array.replicate (32 - r) (0 : UInt8))
  let off0 : ByteArray := natToWord32 0x40
  let aPadded := padR a
  -- offset to second blob = 0x40 + 0x20 (len-of-a) + |aPadded|
  let off1Val := 0x40 + 0x20 + aPadded.size
  let off1 : ByteArray := natToWord32 off1Val
  off0 ++ off1
    ++ natToWord32 a.size ++ aPadded
    ++ natToWord32 b.size ++ padR b

/-- Render a byte array as a `0x`-prefixed hex string. NOTE:
    `LeanCli.Crypto.Hex.encode` already prepends `"0x"`; do NOT
    concatenate another `"0x"` here or the bundler sees `"0x0x…"` and
    rejects the userOp with "Invalid address value" / "Invalid hex". -/
def hex0x (bs : ByteArray) : String := Hex.encode bs

/-- Render a 32-byte big-endian word as a `0x`-prefixed hex string with
    leading zeros stripped (matching `eth_getTransactionCount`-style
    quantity encoding the JSON-RPC spec requires for `uint256` fields).
    A truly-zero word becomes `"0x0"` — bundlers reject `"0x"`. -/
private def quantity0x (bs : ByteArray) : String :=
  let raw := Hex.encode bs
  let body := if raw.startsWith "0x" then (raw.drop 2).toString else raw
  -- Drop leading zero nibbles, but keep at least one digit.
  let trimmed := body.dropWhile (· = '0') |>.toString
  if trimmed.isEmpty then "0x0" else "0x" ++ trimmed

/-- Extract the high or low 16 bytes from a packed 32-byte word.
    `accountGasLimits` and `gasFees` are stored packed for the on-chain
    struct but the bundler JSON-RPC v3 API wants the two halves as
    separate uint128 quantity fields. -/
private def hiHalf16 (bs : ByteArray) : ByteArray :=
  if bs.size ≥ 32 then bs.extract 0 16 else bs.extract 0 (min bs.size 16)

private def loHalf16 (bs : ByteArray) : ByteArray :=
  if bs.size ≥ 32 then bs.extract 16 32 else bs

/-- JSON shape of a PackedUserOperation as ERC-4337 v3 bundlers expect
    it. The on-chain struct is PACKED (`accountGasLimits` is one bytes32
    holding verificationGasLimit‖callGasLimit) but every spec-compliant
    bundler — including Candide on `/public/v3/...` — wants the
    UNPACKED JSON form with separate quantity fields. Sending the packed
    shape returns `{"code":-32602,"message":"UserOperation missing
    callGasLimit field"}`.

    Split rules (PackedUserOperation v0.7+):
      accountGasLimits[ 0..16] → verificationGasLimit
      accountGasLimits[16..32] → callGasLimit
      gasFees       [ 0..16] → maxPriorityFeePerGas
      gasFees       [16..32] → maxFeePerGas
      initCode[ 0..20]       → factory      (when initCode non-empty)
      initCode[20..]         → factoryData  (when initCode non-empty)
      paymasterAndData[…]    → paymaster + paymaster*GasLimit + paymasterData
        (we don't support paymasters yet — `paymasterAndData` is always
         empty and the optional paymaster fields are omitted)

    Empty `initCode` → omit factory/factoryData so the bundler doesn't
    think the account needs deploying. Otherwise the first 20 bytes are
    the factory address and the remainder is the factory calldata. -/
def packedUserOpToJson (op : UserOp.PackedUserOperation) (signature : ByteArray) : Json :=
  let baseFields : Array (String × Json) := #[
    ("sender",                .str (hex0x op.sender)),
    ("nonce",                 .str (quantity0x op.nonce)),
    ("callData",              .str (hex0x op.callData)),
    ("callGasLimit",          .str (quantity0x (loHalf16 op.accountGasLimits))),
    ("verificationGasLimit",  .str (quantity0x (hiHalf16 op.accountGasLimits))),
    ("preVerificationGas",    .str (quantity0x op.preVerificationGas)),
    ("maxFeePerGas",          .str (quantity0x (loHalf16 op.gasFees))),
    ("maxPriorityFeePerGas",  .str (quantity0x (hiHalf16 op.gasFees))),
    ("signature",             .str (hex0x signature))
  ]
  let withFactory : Array (String × Json) :=
    if op.initCode.size ≥ 20 then
      let factoryBs := op.initCode.extract 0 20
      let factoryData := op.initCode.extract 20 op.initCode.size
      baseFields
        |>.push ("factory",     .str (hex0x factoryBs))
        |>.push ("factoryData", .str (hex0x factoryData))
    else baseFields
  .obj withFactory

/-- Pack two 16-byte halves into one 32-byte word (high half ‖ low half).
    Used for `accountGasLimits` (verificationGasLimit‖callGasLimit) and
    `gasFees` (maxPriorityFeePerGas‖maxFeePerGas) per v0.9. -/
def packTwoHalves (hi lo : Nat) : ByteArray :=
  let toBytes16 (n : Nat) : ByteArray :=
    let raw := (Hex.decode (natToEvenHex n)).getD ByteArray.empty
    let r := raw.size
    if r >= 16 then raw.extract (r - 16) r
    else ByteArray.mk (Array.replicate (16 - r) (0 : UInt8)) ++ raw
  toBytes16 hi ++ toBytes16 lo

/-- Build the v0.9 `initCode` field for first-send-also-deploy:
    factoryAddrBytes (20) ‖ selector(createAccount) (4)
                          ‖ pad32(owner) ‖ pkSeed (32) ‖ pkRoot (32).
    The bundler treats a non-empty initCode as the account's CREATE2
    bootstrap; we never call the factory separately in this case. -/
def buildInitCode (factoryHex ownerHex pkSeedHex pkRootHex : String) :
    IO (Except String ByteArray) := do
  match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
      (Hex.encode "createAccount(address,bytes32,bytes32)".toByteArray) with
  | .error e => pure (.error e)
  | .ok kh =>
      let sel := kh.extract 0 4
      let factoryBs := (Hex.decode factoryHex).getD ByteArray.empty
      let ownerW := (UserOp.hexToWord32? ownerHex).getD ByteArray.empty
      let pkSeedW := (UserOp.hexToWord32? pkSeedHex).getD ByteArray.empty
      let pkRootW := (UserOp.hexToWord32? pkRootHex).getD ByteArray.empty
      pure (.ok (factoryBs ++ sel ++ ownerW ++ pkSeedW ++ pkRootW))

/-- Parse a hex-encoded `eth_getCode` result and return `true` iff the
    contract has any deployed bytecode (i.e. response is more than just
    `"0x"`). Used by the send path to decide whether to populate
    `initCode` for a first-send-also-deploy. -/
def hasCodeAt (ret : String) : Bool :=
  let stripped := if ret.startsWith "0x" then (ret.drop 2).toString else ret
  ! stripped.trimAscii.toString.isEmpty

/-- Build the calldata for `SphincsAccount.rotateOwner(address)`. The
    selector is `keccak256("rotateOwner(address)")[0:4]`, computed at
    runtime so we don't need a magic constant. Returned bytes are
    `selector ‖ pad32(newOwner)` — 36 bytes total. -/
def buildRotateOwnerCalldata (newOwner : String) : IO (Except String ByteArray) := do
  match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
      (Hex.encode "rotateOwner(address)".toByteArray) with
  | .error e => pure (.error e)
  | .ok kh =>
      let sel := kh.extract 0 4
      let ownerW := (UserOp.hexToWord32? newOwner).getD ByteArray.empty
      pure (.ok (sel ++ ownerW))

/-- Build the calldata for `SphincsAccount.rotateKeys(bytes32,bytes32)`.
    Exposed for the advanced "raw send" path; the daemon currently does
    not provide an atomic rotateKeys RPC because the new SPHINCS sk
    must be preserved on disk even when the on-chain rotation reverts —
    see the design notes in `INVARIANTS.md` (TODO). -/
def buildRotateKeysCalldata (newPkSeed newPkRoot : String) :
    IO (Except String ByteArray) := do
  match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
      (Hex.encode "rotateKeys(bytes32,bytes32)".toByteArray) with
  | .error e => pure (.error e)
  | .ok kh =>
      let sel := kh.extract 0 4
      let seedW := (UserOp.hexToWord32? newPkSeed).getD ByteArray.empty
      let rootW := (UserOp.hexToWord32? newPkRoot).getD ByteArray.empty
      pure (.ok (sel ++ seedW ++ rootW))

/-- POST a JSON-RPC request to a bundler URL via the shared curl shim. -/
def bundlerCall (url method : String) (params : Json) : IO (Except String Json) := do
  let req : RPC.JsonRpc.Request := { method := method, params := params, id := 1 }
  try
    let body ← RPC.JsonRpc.callRaw url req
    match parse body with
    | .error e => pure (.error s!"bundler response parse: {e}")
    | .ok j =>
        match getField "error" j with
        | some err => pure (.error s!"bundler error: {compact err}")
        | none =>
            match getField "result" j with
            | some r => pure (.ok r)
            | none => pure (.error "bundler response missing result")
  catch e =>
    pure (.error s!"bundler transport: {e.toString}")

end LeanCli.Sphincs.Send
