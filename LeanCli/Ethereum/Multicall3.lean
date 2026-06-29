import LeanCli.Swap.UniV3

/-!
# Multicall3 `aggregate3` encoder / decoder

Batches many read-only `eth_call`s into a single call to the canonical
Multicall3 contract, so a fan-out of N `balanceOf` reads costs one RPC
round-trip instead of N. This matters on the consensus-verified provider
path (helios/colibri): each verified `eth_call` runs REVM against
sync-committee-verified state and is inherently several seconds, and the
single shared light-client connection is mutex-serialized
(`State.verifyLock`). N serial verified reads blow past the daemon
timeout; one batched read does not, while keeping every balance verified.

`aggregate3(Call3[])` with `allowFailure := true` per call preserves the
existing fail-soft rule: a token whose `balanceOf` reverts comes back as
`success = false` and is dropped, instead of failing the whole batch.

Trust model unchanged: this is a render-only read surface. It is gated by
`Outbound.*` like any other chain read and never feeds a signing
decision — `ConfirmGate` remains the trust anchor.

Reuses the ABI primitives in `LeanCli.Swap.UniV3` (`encodeAddress`,
`encodeUint256`, `encodeBytes`, `decodeWordAt`, `stripHex`) rather than
introducing a parallel set, mirroring `Ethereum.Erc20`.
-/

namespace LeanCli.Ethereum.Multicall3

open LeanCli.Swap.UniV3 (encodeAddress encodeUint256 encodeBytes decodeWordAt)

/-- Strip a leading `0x`/`0X` if present. (`Swap.UniV3.stripHex` is
`private`, so we keep a local copy rather than widen its visibility.) -/
private def stripHex (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then (s.drop 2).toString else s

/-- Canonical Multicall3 deployment. Deterministic CREATE2 address, the
same on mainnet and Sepolia (and every chain Multicall3 ships on). -/
def address : String := "0xcA11bde05977b3631167028862bE2a173976CA11"

/-- `aggregate3((address,bool,bytes)[])` selector (`keccak256(sig)[:4]`,
verified with `cast sig`). -/
def selAggregate3 : String := "82ad56cb"

/-- One `Call3` request: target contract, whether a revert is tolerated,
and the `0x`-prefixed inner calldata. -/
structure Call3 where
  target : String
  allowFailure : Bool
  callData : String
  deriving Repr

/-- Encode a single `Call3` tuple body (no `0x`). The tuple is dynamic
(it carries a `bytes`), so it is `address ++ bool ++ offset(0x60) ++
encodeBytes(callData)`, with the offset pointing past the three head
words to the inner bytes. -/
def encodeCall3 (c : Call3) : String :=
  encodeAddress c.target
    ++ encodeUint256 (if c.allowFailure then 1 else 0)
    ++ encodeUint256 96
    ++ encodeBytes c.callData

/-- Encode a full `aggregate3(Call3[])` call. Returns `0x`-prefixed
calldata. The `Call3[]` is a dynamic array of dynamic tuples, so it is a
length word, an N-entry head table of offsets (relative to the start of
the data region after the length word), then the concatenated tuple
bodies — the same offset-table shape as `Swap.UniV3.encodeBytesArray`. -/
def encodeAggregate3 (calls : List Call3) : String :=
  let n := calls.length
  let bodies : List String := calls.map encodeCall3
  let headsRev : List String × Nat :=
    bodies.foldl (init := ([], n * 32))
      (fun (acc : List String × Nat) body =>
        let (heads, off) := acc
        (encodeUint256 off :: heads, off + body.length / 2))
  let heads := headsRev.fst.reverse
  let arrayBody :=
    encodeUint256 n
      ++ String.intercalate "" heads
      ++ String.intercalate "" bodies
  "0x" ++ selAggregate3 ++ encodeUint256 32 ++ arrayBody

/-- Extract `lenBytes` bytes starting at byte offset `off` from a
`0x`-hex string, returning a `0x`-prefixed hex string. `none` if the
slice runs past the end. -/
def sliceHex (hex : String) (off lenBytes : Nat) : Option String :=
  let body := stripHex hex
  let start := off * 2
  let take := lenBytes * 2
  if body.length < start + take then none
  else some ("0x" ++ ((body.drop start).take take).toString)

/-- Decode the `Result[]` (`(bool success, bytes returnData)[]`) returned
by `aggregate3`. Each element is `(success, returnDataHex)` with
`returnDataHex` a `0x`-prefixed string. Order matches the input `Call3`
list. Returns `none` on a malformed / truncated payload. -/
def decodeAggregate3 (hex : String) : Option (List (Bool × String)) := do
  let arrOff ← decodeWordAt hex 0
  let n ← decodeWordAt hex arrOff
  let dataStart := arrOff + 32
  (List.range n).mapM fun i => do
    let tupleOff ← decodeWordAt hex (dataStart + i * 32)
    let tupleStart := dataStart + tupleOff
    let succWord ← decodeWordAt hex tupleStart
    let bytesOff ← decodeWordAt hex (tupleStart + 32)
    let bytesStart := tupleStart + bytesOff
    let bytesLen ← decodeWordAt hex bytesStart
    let data ← sliceHex hex (bytesStart + 32) bytesLen
    pure (succWord != 0, data)

end LeanCli.Ethereum.Multicall3
