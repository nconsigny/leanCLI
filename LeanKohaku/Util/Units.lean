/-!
# `parseUnits` — decimal-string → base-units `Nat`

Deterministic counterpart to viem / ethers `parseUnits`. Used by the
chat path so the LLM never has to do unit conversion (it has been
caught dropping zeros — emitted `1×10^15` for "0.01 ETH" instead of
`1×10^16`).

The contract:

* `parseUnits "0.01"  18 = some 10_000_000_000_000_000`
* `parseUnits "1"     18 = some 1_000_000_000_000_000_000`
* `parseUnits "100"   6  = some 100_000_000`
* `parseUnits "0.5"   6  = some 500_000`
* `parseUnits "1.234567" 6 = some 1_234_567`
* `parseUnits "1.2345678" 6 = none`           (more decimals than scale)
* `parseUnits ""      _  = none`              (empty)
* `parseUnits "1.2.3" _  = none`              (malformed)
* `parseUnits "1."    18 = some 10^18`         (trailing dot accepted)
* `parseUnits ".5"    18 = some 5×10^17`       (leading dot accepted)

We deliberately reject excess-precision rather than truncate: silent
truncation is the kind of bug that turns a "100.000001 USDC" prompt
into a stealth 100 USDC transfer.
-/

namespace LeanKohaku.Util.Units

private def parseDigits (s : String) : Option Nat :=
  if s.isEmpty then none
  else
    s.toList.foldl
      (fun acc c =>
        match acc with
        | none => none
        | some n =>
            if c.isDigit then
              some (n * 10 + (c.toNat - '0'.toNat))
            else
              none)
      (some 0)

/-- 10^n. Repeated multiplication; for the token-decimal range (≤ 24)
this is fine. -/
def pow10 : Nat → Nat
  | 0 => 1
  | n + 1 => 10 * pow10 n

/-- Convert a decimal string like `"0.01"` to its base-units `Nat`,
given the token's decimals (e.g. 18 for ETH, 6 for USDC). Returns
`none` for malformed input or excess precision. -/
def parseUnits (s : String) (decimals : Nat) : Option Nat :=
  if s.isEmpty then none
  else
    let parts := s.splitOn "."
    match parts with
    | [intPart] =>
        -- No decimal point. Parse the integer and scale up.
        match parseDigits intPart with
        | none => none
        | some n => some (n * pow10 decimals)
    | [intPart, fracPart] =>
        let fracLen := fracPart.length
        if fracLen > decimals then none
        else
          let intParsed :=
            if intPart.isEmpty then some 0 else parseDigits intPart
          let fracParsed :=
            if fracPart.isEmpty then some 0 else parseDigits fracPart
          match intParsed, fracParsed with
          | some i, some f =>
              some (i * pow10 decimals + f * pow10 (decimals - fracLen))
          | _, _ => none
    | _ => none  -- more than one '.' is malformed

/-! ## Smoke checks. These are `example`s — typecheck-only, no
runtime. They serve as both regression tests and documentation. -/

example : parseUnits "0.01" 18 = some 10000000000000000 := by native_decide
example : parseUnits "1" 18    = some 1000000000000000000 := by native_decide
example : parseUnits "100" 6   = some 100000000 := by native_decide
example : parseUnits "0.5" 6   = some 500000 := by native_decide
example : parseUnits "1.234567" 6 = some 1234567 := by native_decide
example : parseUnits "1.2345678" 6 = none := by native_decide
example : parseUnits "" 18     = none := by native_decide

end LeanKohaku.Util.Units
