/-!
# ETH → wei parsing

Pure-Nat conversion from a human ETH decimal string to wei.
Rejects floats, scientific notation, signs, and >18 fractional digits.
-/

namespace LeanKohaku.Invariants.EthAmount

def weiPerEth : Nat := 1000000000000000000

private def isDigit (c : Char) : Bool :=
  '0' ≤ c && c ≤ '9'

private def allDigits (cs : List Char) : Bool :=
  cs.all isDigit

private def digitsToNat (cs : List Char) : Nat :=
  cs.foldl (init := 0) (fun acc c => acc * 10 + (c.toNat - '0'.toNat))

private def pow10 : Nat → Nat
  | 0 => 1
  | n + 1 => 10 * pow10 n

def parseEthToWei (s : String) : Except String Nat :=
  if s.isEmpty then
    .error "empty ETH amount"
  else
    let cs := s.toList
    -- Why: split on the single allowed '.'; reject any other separator or extra dots.
    let dots := cs.filter (· = '.')
    if dots.length > 1 then
      .error s!"invalid ETH amount: {s} (multiple decimal points)"
    else
      match cs.span (· ≠ '.') with
      | (whole, []) =>
          if whole.isEmpty then
            .error s!"invalid ETH amount: {s}"
          else if !allDigits whole then
            .error s!"invalid ETH amount: {s} (non-digit character)"
          else
            .ok (digitsToNat whole * weiPerEth)
      | (whole, _ :: frac) =>
          if whole.isEmpty then
            .error s!"invalid ETH amount: {s} (missing whole part)"
          else if frac.isEmpty then
            .error s!"invalid ETH amount: {s} (missing fractional part)"
          else if !allDigits whole then
            .error s!"invalid ETH amount: {s} (non-digit character)"
          else if !allDigits frac then
            .error s!"invalid ETH amount: {s} (non-digit character)"
          else if frac.length > 18 then
            .error s!"invalid ETH amount: {s} (more than 18 fractional digits)"
          else
            let fracNat := digitsToNat frac
            let scale := pow10 (18 - frac.length)
            .ok (digitsToNat whole * weiPerEth + fracNat * scale)

example : parseEthToWei "0" = .ok 0 := rfl
example : parseEthToWei "1" = .ok 1000000000000000000 := rfl
example : parseEthToWei "0.001" = .ok 1000000000000000 := rfl
example : parseEthToWei "0.000000000000000001" = .ok 1 := rfl
example : parseEthToWei "1.5" = .ok 1500000000000000000 := rfl
example : parseEthToWei "0.123456789012345678" = .ok 123456789012345678 := rfl

example : (parseEthToWei "").toOption = none := rfl
example : (parseEthToWei "1.0000000000000000001").toOption = none := rfl
example : (parseEthToWei "-1").toOption = none := rfl
example : (parseEthToWei "1.5e2").toOption = none := rfl
example : (parseEthToWei "1.2.3").toOption = none := rfl
example : (parseEthToWei ".5").toOption = none := rfl
example : (parseEthToWei "1.").toOption = none := rfl
example : (parseEthToWei "abc").toOption = none := rfl

theorem parseEthToWei_zero : parseEthToWei "0" = .ok 0 := rfl
theorem parseEthToWei_one : parseEthToWei "1" = .ok weiPerEth := rfl
theorem parseEthToWei_milli : parseEthToWei "0.001" = .ok 1000000000000000 := rfl
theorem parseEthToWei_one_wei : parseEthToWei "0.000000000000000001" = .ok 1 := rfl

end LeanKohaku.Invariants.EthAmount
