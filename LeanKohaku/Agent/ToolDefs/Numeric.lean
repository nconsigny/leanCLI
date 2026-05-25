import LeanKohaku.Agent.Tools
import LeanKohaku.Encoding.Json

/-!
# Numeric utility agent tools

Three pure tools that stop the LLM from doing prose arithmetic
anywhere on the calldata path:

* `hex_to_uint({hex})`       → `{decimal: "..."}`
* `uint_to_hex({decimal})`   → `{hex: "0x..."}`
* `apply_slippage({amount, slippageBps})` → `{result: "..."}`

All three are PURE: no IO, no FFI, no daemon round-trip. They live in
the agent layer because their only consumer is the LLM tool surface —
the daemon does not need to expose them as RPCs (and would not benefit
from doing so).

## Why string I/O

`amount` (slippage input) and the hex/decimal endpoints all accept
and emit decimal STRINGS. JSON numbers are routinely truncated to
IEEE-754 doubles by chat-completion clients; anything over `2^53`
loses precision silently. Strings let us hand the model a uint256
faithfully and let `Nat` do exact integer math underneath.

## Trust model

No chain reads, no signing primitive touched. The agent registry
classifies all three as `.read`.
-/

namespace LeanKohaku.Agent.ToolDefs.Numeric

open LeanKohaku.Agent
open LeanKohaku.Agent.Tools
open LeanKohaku.Encoding.Json

/-- Standard short error envelope used across all three tools so the
    model sees a uniform `{kind, error}` shape on any rejection. -/
private def errResult (kind err : String) : ToolResult :=
  { ok := false,
    data := .obj #[("kind", .str kind), ("error", .str err)] }

/-! ## Pure conversions -/

/-- Parse a single hex character `[0-9a-fA-F]` to its 0–15 value. -/
private def hexCharValue (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c ∧ c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c ∧ c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

/-- Parse a non-empty ASCII decimal string into a `Nat`. Returns
    `none` on empty input or any non-`0-9` character. -/
private def parseDecimalNat (s : String) : Option Nat := Id.run do
  if s.isEmpty then return none
  let mut acc : Nat := 0
  for c in s.toList do
    if '0' ≤ c ∧ c ≤ '9' then
      acc := acc * 10 + (c.toNat - '0'.toNat)
    else
      return none
  return some acc

/-- Parse a `0x`-prefixed (case-insensitive) hex string into a `Nat`.
    Surrounding whitespace is trimmed. Empty body after the prefix
    fails. Returns `none` on any non-hex character. -/
def hexToNat (raw : String) : Option Nat := Id.run do
  let trimmed := raw.trimAscii.toString
  let body :=
    if trimmed.startsWith "0x" ∨ trimmed.startsWith "0X" then
      (trimmed.drop 2).toString
    else
      trimmed
  if body.isEmpty then return none
  let mut acc : Nat := 0
  for c in body.toList do
    match hexCharValue c with
    | some v => acc := acc * 16 + v
    | none   => return none
  return some acc

/-- Encode a `Nat` as a `0x`-prefixed lowercase hex string. `0`
    renders as `"0x0"`. -/
def natToHex (n : Nat) : String :=
  if n = 0 then "0x0" else "0x" ++ natToHexBody n
where
  /-- Build the hex body (most-significant nibble first) by repeated
      division by 16. The `fuel` parameter is `n` itself — a `Nat`
      shrinks under integer division, so we are guaranteed to bottom
      out at zero. -/
  natToHexBody (n : Nat) : String :=
    let rec loop (n : Nat) (acc : String) (fuel : Nat) : String :=
      match fuel with
      | 0 => acc
      | _ + 1 =>
        if n = 0 then acc
        else
          let digit := nibbleChar (n % 16)
          loop (n / 16) (String.singleton digit ++ acc) fuel.pred
    loop n "" (n + 1)
  /-- Lower-case nibble (0–15) to char. -/
  nibbleChar (n : Nat) : Char :=
    if n < 10 then Char.ofNat ('0'.toNat + n)
    else Char.ofNat ('a'.toNat + (n - 10))

/-- Apply slippage in basis points to an integer amount:
    `amount * (10000 - bps) / 10000`. Caller is expected to validate
    `bps ≤ 10000`; we mirror `Swap.Prepare.applySlippage`'s defensive
    cap so the math stays total even if the validator is bypassed. -/
def applySlippageNat (amount bps : Nat) : Nat :=
  let cappedBps := if bps > 10000 then 10000 else bps
  amount * (10000 - cappedBps) / 10000

/-! ## Tool declarations -/

/-- `hex_to_uint` — `"0xff"` → `"255"`. -/
def hexToUint : ToolDecl := {
  name := "hex_to_uint",
  description :=
    "Convert a hex string (e.g. \"0xff\", \"0xFF\", with or without \
     the 0x prefix) to its decimal integer representation as a \
     string. Pure integer math, no chain reads. Use this instead of \
     computing the conversion in prose.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "hex"]),
    ("properties", .obj #[
      ("hex", .obj #[
        ("type", .str "string"),
        ("description", .str "Hex string with optional 0x prefix, case-insensitive")
      ])
    ])
  ],
  classify := .read,
  invoke := fun _cfg args => do
    let some hexJ := getField "hex" args
      | pure (errResult "bad_request" "hex_to_uint: missing 'hex'")
    let some hex := asString hexJ
      | pure (errResult "bad_request" "hex_to_uint: 'hex' must be a string")
    match hexToNat hex with
    | some n =>
        pure { ok := true,
               data := .obj #[("decimal", .str (toString n))],
               summary := some s!"{hex} → {n}" }
    | none =>
        pure (errResult "bad_hex" s!"hex_to_uint: not a valid hex string: {hex}")
}

/-- `uint_to_hex` — `"255"` → `"0xff"`. -/
def uintToHex : ToolDecl := {
  name := "uint_to_hex",
  description :=
    "Convert a non-negative decimal integer string (e.g. \"255\") \
     to its 0x-prefixed lowercase hex representation. Pure integer \
     math, no chain reads. Use this instead of computing the \
     conversion in prose.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "decimal"]),
    ("properties", .obj #[
      ("decimal", .obj #[
        ("type", .str "string"),
        ("description", .str "Non-negative decimal integer string, e.g. \"255\"")
      ])
    ])
  ],
  classify := .read,
  invoke := fun _cfg args => do
    let some decJ := getField "decimal" args
      | pure (errResult "bad_request" "uint_to_hex: missing 'decimal'")
    let some dec := asString decJ
      | pure (errResult "bad_request" "uint_to_hex: 'decimal' must be a string")
    match parseDecimalNat dec with
    | some n =>
        let hex := natToHex n
        pure { ok := true,
               data := .obj #[("hex", .str hex)],
               summary := some s!"{dec} → {hex}" }
    | none =>
        pure (errResult "bad_uint"
          s!"uint_to_hex: not a non-negative decimal integer: {dec}")
}

/-- `apply_slippage` — integer-math slippage application. -/
def applySlippage : ToolDecl := {
  name := "apply_slippage",
  description :=
    "Apply a basis-point slippage to a base-units integer amount. \
     Computes amount * (10000 - slippageBps) / 10000 with exact \
     integer math. Use this for any minOut / minimum-received \
     calculation; never multiply by floats in prose.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "amount", .str "slippageBps"]),
    ("properties", .obj #[
      ("amount", .obj #[
        ("type", .str "string"),
        ("description",
          .str "Base-units integer as a decimal string (e.g. \"1000000\")")
      ]),
      ("slippageBps", .obj #[
        ("type", .str "integer"),
        ("description",
          .str "Slippage in basis points, 0–10000 (e.g. 50 = 0.50%)")
      ])
    ])
  ],
  classify := .read,
  invoke := fun _cfg args => do
    let some amtJ := getField "amount" args
      | pure (errResult "bad_request" "apply_slippage: missing 'amount'")
    let some amtStr := asString amtJ
      | pure (errResult "bad_request"
          "apply_slippage: 'amount' must be a decimal string")
    let some amount := parseDecimalNat amtStr
      | pure (errResult "bad_amount"
          s!"apply_slippage: 'amount' is not a non-negative decimal integer: {amtStr}")
    let some bpsJ := getField "slippageBps" args
      | pure (errResult "bad_request" "apply_slippage: missing 'slippageBps'")
    let some bps := asNat bpsJ
      | pure (errResult "bad_request"
          "apply_slippage: 'slippageBps' must be a non-negative integer")
    if bps > 10000 then
      pure (errResult "invalid_slippage"
        s!"apply_slippage: slippageBps must be ≤ 10000 (100%), got {bps}")
    else
      let result := applySlippageNat amount bps
      pure { ok := true,
             data := .obj #[("result", .str (toString result))],
             summary := some s!"{amtStr} × (10000 - {bps}) / 10000 = {result}" }
}

end LeanKohaku.Agent.ToolDefs.Numeric
