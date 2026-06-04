import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Hex
import LeanCli.Ethereum.Address

/-!
# Wallet address derivation

Ethereum EOA addresses are the last 20 bytes of Keccak-256 over the 64-byte
uncompressed secp256k1 public-key body (`x || y`), excluding the SEC1 `0x04`
prefix.
-/

namespace LeanCli.Wallet.Address

open LeanCli.Ethereum.Address

private def take (bytes : ByteArray) (start len : Nat) : ByteArray :=
  (List.range len).foldl
    (init := ByteArray.empty)
    (fun acc i => acc.push bytes[start + i]!)

def addressFromUncompressedPubkeyIO (pubkey : ByteArray) :
    IO (Except String Address) := do
  if pubkey.size != 65 then
    pure (.error s!"expected 65-byte uncompressed pubkey, got {pubkey.size}")
  else if pubkey[0]! != 0x04 then
    pure (.error "uncompressed pubkey must start with 0x04")
  else
    let body := take pubkey 1 64
    let digest ← LeanCli.Crypto.Hacl.keccak256EthereumIO
      (LeanCli.Crypto.Hex.encode body)
    match digest with
    | .error err => pure (.error err)
    | .ok hash =>
        if hash.size != 32 then
          pure (.error s!"expected 32-byte Keccak output, got {hash.size}")
        else
          match fromBytes? (take hash 12 20) with
          | some address => pure (.ok address)
          | none => pure (.error "internal address length error")

def eip55Checksum (address : Address) : IO (Except String String) :=
  LeanCli.Ethereum.Address.toChecksumIO address

end LeanCli.Wallet.Address
