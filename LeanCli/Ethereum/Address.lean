import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Hex

/-!
# Ethereum addresses

20-byte addresses with EIP-55 mixed-case checksum encoding.
-/

namespace LeanCli.Ethereum.Address

/-- A 20-byte Ethereum address wrapped in a dependent pair with a length proof. -/
structure Address where
  bytes : ByteArray
  sizeOk : bytes.size = 20

private def stripHexPrefix (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then
    (s.drop 2).toString
  else
    s

private def lowerString (s : String) : String :=
  String.ofList (s.toList.map Char.toLower)

def fromBytes? (bytes : ByteArray) : Option Address :=
  if h : bytes.size = 20 then
    some { bytes := bytes, sizeOk := h }
  else
    none

def fromHex (s : String) : Option Address := do
  let bytes ← LeanCli.Crypto.Hex.decode s
  fromBytes? bytes

private def hashNibble (hash : ByteArray) (i : Nat) : UInt8 :=
  let b := hash[i / 2]!
  if i % 2 = 0 then b >>> 4 else b &&& 0x0f

private def checksumChars (hash : ByteArray) : List Char → Nat → List Char
  | [], _ => []
  | c :: cs, i =>
      let c' :=
        if 'a' ≤ c ∧ c ≤ 'f' ∧ hashNibble hash i ≥ 8 then
          c.toUpper
        else
          c
      c' :: checksumChars hash cs (i + 1)

def toHexLower (address : Address) : String :=
  stripHexPrefix (LeanCli.Crypto.Hex.encode address.bytes)

def toChecksumIO (address : Address) : IO (Except String String) := do
  let lower := toHexLower address
  let hash ← LeanCli.Crypto.Hacl.keccak256EthereumIO
    (LeanCli.Crypto.Hex.encode lower.toByteArray)
  match hash with
  | .error err => pure (.error err)
  | .ok hashBytes =>
      if hashBytes.size != 32 then
        pure (.error s!"toChecksumIO: expected 32-byte Keccak output, got {hashBytes.size}")
      else
        pure (.ok ("0x" ++ String.ofList (checksumChars hashBytes lower.toList 0)))

end LeanCli.Ethereum.Address
