import LeanCli.Swap.UniV3

/-!
# Smart-wallet executeBatch ABI encoder

Encodes the standard ERC-4337 BaseAccount `executeBatch(Call[])` calldata,
where `Call = (address target, uint256 value, bytes data)`. This is the
canonical entry the SPHINCs- BaseAccount in
`lib/sphincs-minus/lib/account-abstraction/contracts/core/BaseAccount.sol`
exposes for atomic multi-call execution from a single UserOperation.

## Why this lives in `Wallet/`, not per-protocol

Batching is an account-abstraction concern, not a DeFi-protocol concern.
Every protocol's `Prepare.lean` ends up with the same shape — a list of
`(to, value, data)` legs — and the rules for collapsing them into a
single `executeBatch` call depend only on the user's account kind. Co-locating
this with the wallet code keeps the per-protocol modules free of
account-kind branches.

## Selectors

* `execute(address,uint256,bytes)`              = `0xb61d27f6`  (single-call entry, already used by `LeanCli/Sphincs/Send.lean`)
* `executeBatch((address,uint256,bytes)[])`     = `0x34fcd5be`  (verified with `cast sig 'executeBatch((address,uint256,bytes)[])'`)

The struct-of-arrays variant (`executeBatch(address[],uint256[],bytes[])`)
that older SimpleAccount forks use has a different selector and is NOT what
this project's BaseAccount exposes.

## Trust model

Pure encoding. No IO. The resulting calldata still flows through the
unchanged pre-sign pipeline (`decodeIntent → simulate → ConfirmGate`)
before any signature; batching changes WHAT is signed but not the gate.

`autoImplicit := false` clean.
-/

namespace LeanCli.Wallet.ExecuteBatch

open LeanCli.Swap.UniV3 (encodeAddress encodeUint256 encodeBytes padLeft32)

/-- Selector for the standard BaseAccount.executeBatch on this project's
    deployments. Pinned as a constant; recompute via
    `cast sig 'executeBatch((address,uint256,bytes)[])'` if porting. -/
def selExecuteBatch : String := "34fcd5be"

/-- A single leg of a batched call. Mirrors
    `struct Call { address target; uint256 value; bytes data; }` from
    `BaseAccount.sol`. `data` is `0x`-prefixed hex (the bare calldata for
    the inner call, no outer `execute` wrap). -/
structure Call where
  target : String
  value  : Nat
  data   : String
  deriving Repr

/-- Hint passed from the caller about the wallet's account kind. Drives
    the batched-vs-sequential decision in `maybeBatchTxs`. -/
inductive AccountKindHint where
  /-- Plain EOA (BIP-39/k1). Multi-tx flows are emitted as a sequential
      list; the LLM proposes them one-by-one through `propose_send`. -/
  | eoa
  /-- SPHINCs- hybrid 4337 account. Multi-tx flows are collapsed into a
      single `executeBatch` callData inside one UserOp; the on-chain
      account exposes the standard `BaseAccount.executeBatch` entry. -/
  | sphincsHybrid
  deriving DecidableEq, Repr

/-- Is this hint a smart wallet that supports `executeBatch`? -/
def AccountKindHint.isSmartWallet : AccountKindHint → Bool
  | .eoa           => false
  | .sphincsHybrid => true

/-- Display string for `summaryForConfirm`. -/
def AccountKindHint.label : AccountKindHint → String
  | .eoa           => "EOA"
  | .sphincsHybrid => "SPHINCS- hybrid account"

/-- Parse `"eoa"` / `"sphincsHybrid"` (case-insensitive). Returns `none`
    for an unknown kind so the caller can surface a stable error rather
    than silently defaulting. -/
def AccountKindHint.parse? (s : String) : Option AccountKindHint :=
  match s.toLower with
  | "eoa"            => some .eoa
  | "eoak1"          => some .eoa
  | "sphincshybrid"  => some .sphincsHybrid
  | "sphincs"        => some .sphincsHybrid
  | _                => none

/-! ## Encoders -/

/-- Strip a leading `0x` / `0X` from a hex string, returning the body.
    Lowercased for hash-friendly equality. -/
private def stripHex (s : String) : String :=
  let l := s.toLower
  if l.startsWith "0x" then (l.drop 2).toString else l

/-- Encode one Call as the dynamic-tuple body `(address, uint256, bytes)`
    (no `0x` prefix). The tuple is dynamic because its `bytes` field is
    dynamic, so the layout is heads-then-tail with the bytes head pointing
    to offset `0x60` (three head words in).

    Layout (each `[..]` is a 32-byte word):
      [target] [value] [0x60] [data_len] [data padded to 32] -/
def encodeCallBody (c : Call) : String :=
  let dataBody := stripHex c.data
  let dataBytesLen := dataBody.length / 2
  let bytesHead := encodeUint256 0x60
  let bytesTail := encodeUint256 dataBytesLen ++
    let body := dataBody
    let pad := (64 - body.length % 64) % 64
    body ++ String.ofList (List.replicate pad '0')
  encodeAddress c.target
    ++ encodeUint256 c.value
    ++ bytesHead
    ++ bytesTail

/-- Total encoded size of one Call body in bytes. -/
private def encodedCallSize (c : Call) : Nat :=
  -- 3 head words + 1 length word = 4 * 32 bytes; then padded data.
  let dataBody := stripHex c.data
  let dataLen := dataBody.length / 2
  let padded := dataLen + ((32 - dataLen % 32) % 32)
  4 * 32 + padded

/-- Encode the body of `Call[]` (no `0x` prefix and no outer function
    selector). Layout:
      [N]
      [offset_0] ... [offset_{N-1}]
      [call_0_body] ... [call_{N-1}_body]

    Where `offset_i = N*32 + Σ_{j<i} size(call_j_body)` — the offset is
    measured from the *start of the tuple encoding*, i.e. after the
    length word. -/
def encodeCallArrayBody (calls : List Call) : String :=
  let n := calls.length
  let lenWord := encodeUint256 n
  let bodies := calls.map encodeCallBody
  let sizes  := calls.map encodedCallSize
  -- Compute offsets in a single forward pass.
  let offs : List Nat :=
    (sizes.foldl (init := ([], n * 32))
      (fun (acc : List Nat × Nat) sz =>
        let (rev, cur) := acc
        (cur :: rev, cur + sz))).fst.reverse
  let heads := String.intercalate "" (offs.map encodeUint256)
  let tails := String.intercalate "" bodies
  lenWord ++ heads ++ tails

/-- `executeBatch(Call[] calls)` full calldata (with `0x` prefix). The
    outer function has a single dynamic argument, so the head section
    contains one offset pointing to the array body (always `0x20`). -/
def encodeExecuteBatch (calls : List Call) : String :=
  let offsetWord := encodeUint256 0x20
  "0x" ++ selExecuteBatch ++ offsetWord ++ encodeCallArrayBody calls

end LeanCli.Wallet.ExecuteBatch
