import LeanKohaku.Crypto.Hex
import LeanKohaku.Encoding.Json
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Intent

/-!
# Wire-shape JSON ↔ Intent

Mechanical JSON object ↔ `Intent` conversion. **No** security
hard-rejects here — that's the job of `LeanKohaku/LlmAgent/IntentParser.lean`,
which layers checks (v/r/s/RLP rejection, wrong-chain, dead-testnet
names, non-checksummed addresses) on top of this structural parse.

This module just does the field-by-field mapping. Its callers:

* `tx.encodeIntent` daemon RPC — takes JSON over the wire, encodes via
  `Ethereum.IntentEncode.encode`. Trusted caller; no hard-rejects
  needed (caller already produced the Intent).
* The future `LlmAgent.IntentParser` — uses this to do the structural
  parse, then runs its security checks on the resulting `Intent`.

## Wire shape

```json
{
  "action": "nativeTransfer" | "erc20Transfer" | "erc20Approve"
          | "uniswapV3SwapSingle" | "aaveV3Supply" | "aaveV3Withdraw"
          | "rawCall",
  "chainId": <int>,
  ...action-specific fields...
}
```

Field names match the constructor argument names so the mapping is
mechanical and reviewable.
-/

namespace LeanKohaku.Ethereum.IntentJson

open LeanKohaku.Encoding.Json
open LeanKohaku.Ethereum.Intent
open LeanKohaku.Ethereum.Address (Address)

/-- Try to parse an `Address` from a JSON string field — accepts the
common `0x…40-hex…` form. -/
def addressFromJson (j : Json) : Except String Address :=
  match asString j with
  | none   => .error "expected JSON string for address"
  | some s =>
      match LeanKohaku.Ethereum.Address.fromHex s with
      | some a => .ok a
      | none   => .error s!"invalid address: {s}"

/-- Parse a required JSON field of an object, returning a typed error
naming the missing key. -/
def field (obj : Json) (key : String) : Except String Json :=
  match getField key obj with
  | some v => .ok v
  | none   => .error s!"missing required field: {key}"

/-- Parse an integer field as a `Nat`, rejecting negatives. -/
def natField (obj : Json) (key : String) : Except String Nat := do
  match asNat (← field obj key) with
  | some n => .ok n
  | none   => .error s!"field {key}: expected non-negative integer"

/-- Parse a string field. -/
def strField (obj : Json) (key : String) : Except String String := do
  match asString (← field obj key) with
  | some s => .ok s
  | none   => .error s!"field {key}: expected string"

/-- Parse an `Address`-shaped field. -/
def addrField (obj : Json) (key : String) : Except String Address := do
  addressFromJson (← field obj key)

/-- Parse `ApproveAmount`: `{"exact": <int>}` or `{"unlimited": true}` or
the bare string `"unlimited"`. -/
def parseApproveAmount (j : Json) : Except String ApproveAmount :=
  match j with
  | .str "unlimited" => .ok .unlimited
  | .obj _ =>
      match getField "unlimited" j with
      | some (.bool true) => .ok .unlimited
      | _ =>
          match getField "exact" j with
          | some v =>
              match asNat v with
              | some n => .ok (.exact n)
              | none   => .error "approveAmount.exact: expected non-negative integer"
          | none => .error "approveAmount: expected {exact:n} or {unlimited:true}"
  | _ => .error "approveAmount: expected object or \"unlimited\""

/-- Parse the canonical action tag string. -/
def parseActionTag (s : String) : Except String String :=
  match s with
  | "nativeTransfer"
  | "erc20Transfer"
  | "erc20Approve"
  | "uniswapV3SwapSingle"
  | "aaveV3Supply"
  | "aaveV3Withdraw"
  | "rawCall" => .ok s
  | _ => .error s!"unknown intent action tag: {s}"

/-- Parse a `bytes` field: a `0x`-prefixed hex string → `ByteArray`. -/
def bytesField (obj : Json) (key : String) : Except String ByteArray := do
  let s ← strField obj key
  match LeanKohaku.Crypto.Hex.decode s with
  | some b => .ok b
  | none   => .error s!"field {key}: expected 0x-hex bytes"

/-- Parse a JSON-shaped Intent. Returns `.error` on missing/malformed
fields; does NOT run security hard-rejects (that's IntentParser's job).
-/
def parseIntent (j : Json) : Except String Intent := do
  let actionRaw ← strField j "action"
  let _ ← parseActionTag actionRaw   -- whitelist gate
  let chainId ← natField j "chainId"
  match actionRaw with
  | "nativeTransfer" =>
      let to ← addrField j "to"
      let amountWei ← natField j "amountWei"
      .ok (.nativeTransfer chainId to amountWei)
  | "erc20Transfer" =>
      let token ← addrField j "token"
      let decimals ← natField j "decimals"
      let to ← addrField j "to"
      let amount ← natField j "amount"
      .ok (.erc20Transfer chainId token decimals to amount)
  | "erc20Approve" =>
      let token ← addrField j "token"
      let spender ← addrField j "spender"
      let amountJ ← field j "amount"
      let amount ← parseApproveAmount amountJ
      .ok (.erc20Approve chainId token spender amount)
  | "uniswapV3SwapSingle" =>
      let tokenIn  ← addrField j "tokenIn"
      let tokenOut ← addrField j "tokenOut"
      let amountIn ← natField j "amountIn"
      let fee ← natField j "fee"
      let minAmountOut ← natField j "minAmountOut"
      let recipient ← addrField j "recipient"
      let deadline ← natField j "deadline"
      .ok (.uniswapV3SwapSingle chainId tokenIn tokenOut amountIn fee minAmountOut recipient deadline)
  | "aaveV3Supply" =>
      let asset ← addrField j "asset"
      let amount ← natField j "amount"
      let onBehalfOf ← addrField j "onBehalfOf"
      .ok (.aaveV3Supply chainId asset amount onBehalfOf)
  | "aaveV3Withdraw" =>
      let asset ← addrField j "asset"
      let amount ← natField j "amount"
      let recipient ← addrField j "recipient"
      .ok (.aaveV3Withdraw chainId asset amount recipient)
  | "rawCall" =>
      let to ← addrField j "to"
      let valueWei ← natField j "valueWei"
      let data ← bytesField j "data"
      let rationale ← strField j "rationale"
      .ok (.rawCall chainId to valueWei data rationale)
  | other =>
      -- parseActionTag already vetted the whitelist; this is unreachable
      -- but keeps the match exhaustive.
      .error s!"unknown intent action tag: {other}"

end LeanKohaku.Ethereum.IntentJson
