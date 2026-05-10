import LeanKohaku.Crypto.Hex
import LeanKohaku.Crypto.Hacl

/-!
# ERC-4337 v0.9 `PackedUserOperation` and EIP-712 `userOpHash`

This module is the load-bearing finding from the Phase 3 Step-1 on-chain
verification: EntryPoint **v0.9** computes `userOpHash` as

  `userOpHash = MessageHashUtils.toTypedDataHash(domainSeparator, structHash)`

where `structHash` is the EIP-712 struct-hash of the
`PackedUserOperation` typed-data record:

  ```
  bytes32 PACKED_USEROP_TYPEHASH = keccak256(
    "PackedUserOperation(address sender,uint256 nonce,bytes initCode,"
    "bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,"
    "bytes32 gasFees,bytes paymasterAndData)"
  );
  structHash = keccak256(abi.encode(
    PACKED_USEROP_TYPEHASH,
    op.sender, op.nonce,
    keccak256(op.initCode), keccak256(op.callData),
    op.accountGasLimits, op.preVerificationGas, op.gasFees,
    keccak256(op.paymasterAndData)
  ));
  userOpHash = keccak256(0x1901 || domainSeparator || structHash);
  ```

This **differs from EntryPoint v0.7/v0.8**, which used the simpler

  `userOpHash = keccak256(abi.encode(keccak256(packedUserOp), entryPoint, chainId))`.

A v0.7 hash construction will silently produce a digest that **the
deployed v0.9 verifier accepts**, but the SPHINCS- account at
`0xA941...2978` rejects (because its `_validateSignature` calls
`getUserOpHash` on the EntryPoint, which uses the EIP-712 path). Using
the wrong rule would mean every signature we produce is unchain-able.

The correctness of this module is anchored by Phase 3 Step 1: feeding
`(pkSeed, pkRoot, userOpHash, sphincsSig)` from a real Sepolia tx
`0x83665...50f` (decoded via `cast tx`) to the local C9 verifier shim
returned `{"ok": true}`, with `userOpHash` reproduced exactly by the
formula above and cross-checked against the deployed EntryPoint's
`getUserOpHash` view call.

The `PACKED_USEROP_TYPEHASH` constant is fixed by the v0.9 source. The
`domainSeparator` is **runtime per-chain**: it depends on the EntryPoint
address and chainId, so the daemon must read it via
`getDomainSeparatorV4()` once per chain at startup and cache. We do not
recompute it from `(name, version, chainId, verifyingContract)` here
because OZ's `EIP712` constructor includes a salt-shape detail we'd
have to mirror exactly; calling the chain getter is both shorter and
self-validating.

This module is **pure / IO-light by design**: it produces the hash
given a domain separator. Network IO (reading the domain separator,
nonce, and gas fees) belongs in the daemon, not here. -/

namespace LeanKohaku.Sphincs.UserOp

open LeanKohaku.Crypto

/-- ERC-4337 v0.9 packed user-operation, mirroring the on-chain struct
    `PackedUserOperation` in `eth-infinitism/account-abstraction@v0.9.0`.

    All "32-byte word" fields are stored as 32-byte `ByteArray`. `initCode`,
    `callData`, `paymasterAndData` are arbitrary-length blobs. The
    signature is *not* part of `structHash`, so it lives outside this
    record where the hash is computed; we keep a `signature` field on
    the runtime record for convenience but it is not consumed here. -/
structure PackedUserOperation where
  sender             : ByteArray  -- 20 bytes (address)
  nonce              : ByteArray  -- 32 bytes (uint256)
  initCode           : ByteArray
  callData           : ByteArray
  accountGasLimits   : ByteArray  -- 32 bytes
  preVerificationGas : ByteArray  -- 32 bytes (uint256)
  gasFees            : ByteArray  -- 32 bytes
  paymasterAndData   : ByteArray
  deriving Inhabited

/-- v0.9 PACKED_USEROP_TYPEHASH = keccak256 of the type string.

    Pinned via the on-chain getter `getPackedUserOpTypeHash()`; reproduced
    here as a constant to avoid an extra RPC per send. If a future
    EntryPoint upgrade rotates the typehash, the daemon's cached
    domain-separator read MUST be invalidated and this constant
    refreshed. -/
def packedUserOpTypeHashHex : String :=
  "0x29a0bca4af4be3421398da00295e58e6d7de38cb492214754cb6a47507dd6f8e"

/-- 0x1901 EIP-712 prefix as a two-byte array. -/
def eip712Prefix : ByteArray :=
  ByteArray.empty.push 0x19 |>.push 0x01

/-- Concatenate two byte arrays. The standard library has `ByteArray.append`
    via `++`; we keep a named helper so the call sites read like the spec. -/
def cat (a b : ByteArray) : ByteArray := a ++ b

/-- Left-pad a byte array to 32 bytes (big-endian word). Truncates from
    the *left* if `bs.size > 32`, which is wrong by ABI rules — callers
    must supply ≤ 32-byte values, but we don't error here because this
    helper is used only on already-validated inputs. -/
def padLeft32 (bs : ByteArray) : ByteArray :=
  let n := bs.size
  if n >= 32 then
    -- Take the rightmost 32 bytes (matches ABI uint256 left-padding for
    -- inputs that happen to already be 32 bytes; truncation case is
    -- undefined but we won't emit garbage of unbounded size).
    let off := n - 32
    bs.extract off n
  else
    let pad := ByteArray.mk (Array.replicate (32 - n) (0 : UInt8))
    pad ++ bs

/-- Decode a hex string (with optional `0x` prefix) and left-pad to 32
    bytes. Returns `none` on non-hex input. -/
def hexToWord32? (s : String) : Option ByteArray :=
  (Hex.decode s).map padLeft32

/-- Compute the EIP-712 struct-hash of a `PackedUserOperation` per
    UserOperationLib.PACKED_USEROP_TYPEHASH (v0.9).

    Spec:
      ```
      structHash = keccak256(abi.encode(
        PACKED_USEROP_TYPEHASH,
        sender, nonce,
        keccak256(initCode), keccak256(callData),
        accountGasLimits, preVerificationGas, gasFees,
        keccak256(paymasterAndData)
      ))
      ```

    abi.encode of fixed-size words is just concatenation of 32-byte
    big-endian words (no length prefix), since every field here is a
    static type. -/
def structHash (op : PackedUserOperation) : IO (Except String ByteArray) := do
  let typeHash := match hexToWord32? packedUserOpTypeHashHex with
    | some w => w
    | none   => ByteArray.mk (Array.replicate 32 (0 : UInt8))  -- unreachable; constant is valid hex
  -- Hash the variable-length fields first.
  match ← Hacl.keccak256EthereumIO (Hex.encode op.initCode) with
  | .error e => pure (.error s!"keccak(initCode) failed: {e}")
  | .ok hashInitCode =>
  match ← Hacl.keccak256EthereumIO (Hex.encode op.callData) with
  | .error e => pure (.error s!"keccak(callData) failed: {e}")
  | .ok hashCallData =>
  match ← Hacl.keccak256EthereumIO (Hex.encode op.paymasterAndData) with
  | .error e => pure (.error s!"keccak(paymasterAndData) failed: {e}")
  | .ok hashPmd =>
    let abiEncoded :=
      typeHash
        |> cat (padLeft32 op.sender)
        |> cat (padLeft32 op.nonce)
        |> cat hashInitCode
        |> cat hashCallData
        |> cat (padLeft32 op.accountGasLimits)
        |> cat (padLeft32 op.preVerificationGas)
        |> cat (padLeft32 op.gasFees)
        |> cat hashPmd
    match ← Hacl.keccak256EthereumIO (Hex.encode abiEncoded) with
    | .error e => pure (.error s!"keccak(structHash) failed: {e}")
    | .ok h => pure (.ok h)

/-- Compute `userOpHash` per EntryPoint v0.9: EIP-712 typed-data hash
    over the `PackedUserOperation` struct.

    `domainSeparator` is the bytes32 returned by the deployed
    EntryPoint's `getDomainSeparatorV4()`; the caller is responsible for
    fetching and caching it (it depends on EntryPoint address + chainId
    + the OZ EIP712 constructor inputs `(DOMAIN_NAME, DOMAIN_VERSION)`).

    Output is a 32-byte ByteArray. -/
def userOpHash (op : PackedUserOperation) (domainSeparator : ByteArray) :
    IO (Except String ByteArray) := do
  match ← structHash op with
  | .error e => pure (.error e)
  | .ok sh =>
    let preimage := eip712Prefix |> cat (padLeft32 domainSeparator) |> cat sh
    match ← Hacl.keccak256EthereumIO (Hex.encode preimage) with
    | .error e => pure (.error s!"keccak(userOpHash) failed: {e}")
    | .ok h => pure (.ok h)

/-- Convenience: compute `userOpHash` returning a hex string for direct
    feed into the SPHINCS- shim's `digest` field. -/
def userOpHashHex (op : PackedUserOperation) (domainSeparator : ByteArray) :
    IO (Except String String) := do
  match ← userOpHash op domainSeparator with
  | .error e => pure (.error e)
  | .ok bs  => pure (.ok (Hex.encode bs))

end LeanKohaku.Sphincs.UserOp
