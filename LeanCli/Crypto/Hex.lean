/-!
# Hex encoding

Hex encoding / decoding of byte arrays. Kept in `Crypto` for now since the
rest of the crypto stack speaks bytes and hex is the canonical Ethereum
wire format.
-/

namespace LeanCli.Crypto.Hex

/-- Decode a single hex digit. Returns `none` if not `[0-9a-fA-F]`. -/
def hexDigit? (c : Char) : Option UInt8 :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat.toUInt8 - '0'.toNat.toUInt8)
  else if 'a' ≤ c ∧ c ≤ 'f' then some (c.toNat.toUInt8 - 'a'.toNat.toUInt8 + 10)
  else if 'A' ≤ c ∧ c ≤ 'F' then some (c.toNat.toUInt8 - 'A'.toNat.toUInt8 + 10)
  else none

/-- Encode a nibble (0..15) to a lowercase hex char. -/
def nibbleToChar (n : UInt8) : Char :=
  if n < 10 then Char.ofNat ('0'.toNat + n.toNat)
  else Char.ofNat ('a'.toNat + (n.toNat - 10))

/-- Encode bytes to a lowercase `0x`-prefixed hex string. -/
def encode (bytes : ByteArray) : String := Id.run do
  let mut s := "0x"
  for b in bytes do
    s := s.push (nibbleToChar (b >>> 4)) |>.push (nibbleToChar (b &&& 0x0f))
  return s

/-- Strip a leading `0x` / `0X` prefix from a char list, if present. -/
private def stripPrefix : List Char → List Char
  | '0' :: 'x' :: rest => rest
  | '0' :: 'X' :: rest => rest
  | cs => cs

/-- Decode a hex char list pair-by-pair into a byte list. Returns `none`
on any non-hex char. `acc` is collected in reverse and reversed at the end. -/
private def decodeChars : List Char → List UInt8 → Option (List UInt8)
  | [], acc => some acc.reverse
  | [_], _  => none
  | c1 :: c2 :: rest, acc => do
    let hi ← hexDigit? c1
    let lo ← hexDigit? c2
    decodeChars rest (((hi <<< 4) ||| lo) :: acc)

/-- Decode a hex string (with optional `0x` prefix). Odd-length inputs fail. -/
def decode (s : String) : Option ByteArray := do
  let bytes ← decodeChars (stripPrefix s.toList) []
  return ⟨bytes.toArray⟩

end LeanCli.Crypto.Hex
