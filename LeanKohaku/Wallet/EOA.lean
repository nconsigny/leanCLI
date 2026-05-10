import LeanKohaku.Crypto.Hacl
import LeanKohaku.Crypto.Secp256k1
import LeanKohaku.Crypto.Secp256k1Native
import LeanKohaku.Ethereum.Tx

/-!
# EOA signing helpers

This module keeps EOA signing typed: it signs EIP-1559 transaction payloads,
not arbitrary bytes. Runtime Keccak and secp256k1 signing go exclusively
through the `*IO` entry points, which shell out to the native
HACL/libsecp256k1 helpers (`INVARIANTS.md` Category 13).
-/

namespace LeanKohaku.Wallet.EOA

open LeanKohaku.Crypto
open LeanKohaku.Crypto.Secp256k1
open LeanKohaku.Ethereum.Tx

def bytesToNat (bytes : ByteArray) : Nat :=
  bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

private def take (bytes : ByteArray) (start len : Nat) : ByteArray :=
  (List.range len).foldl
    (init := ByteArray.empty)
    (fun acc i => acc.push bytes[start + i]!)

private def expectOk {α : Type} : Except String α → IO α
  | .ok value => pure value
  | .error err => throw <| IO.userError err

def encodeSignedEip1559 (tx : SignedTx) : ByteArray :=
  tx.encode

def signingDigestIO (tx : TxEip1559) : IO (Except String ByteArray) :=
  Hacl.keccak256EthereumIO (LeanKohaku.Crypto.Hex.encode tx.signingPayload)

def signatureFromNativeBytes (sig : ByteArray) : Except String Signature :=
  if sig.size != 65 then
    .error s!"native signature must be 65 bytes, got {sig.size}"
  else
    .ok
      { r := bytesToNat (take sig 0 32)
        s := bytesToNat (take sig 32 32)
        v := sig[64]! }

def signDigestIO (privateKey digest : ByteArray) : IO (Except String Signature) := do
  if privateKey.size != 32 then
    pure (.error s!"private key must be 32 bytes, got {privateKey.size}")
  else if digest.size != 32 then
    pure (.error s!"digest must be 32 bytes, got {digest.size}")
  else
    let sig ← Secp256k1Native.signIO
      (LeanKohaku.Crypto.Hex.encode privateKey)
      (LeanKohaku.Crypto.Hex.encode digest)
    match sig with
    | .error err => pure (.error err)
    | .ok sigBytes => pure (signatureFromNativeBytes sigBytes)

def signEip1559IO (tx : TxEip1559) (privateKey : ByteArray) :
    IO (Except String SignedTx) := do
  let digest ← signingDigestIO tx
  match digest with
  | .error err => pure (.error err)
  | .ok digestBytes =>
      let sig ← signDigestIO privateKey digestBytes
      match sig with
      | .error err => pure (.error err)
      | .ok sig => pure (.ok { unsigned := tx, sig := sig })

def personalMessagePayload (msg : ByteArray) : ByteArray :=
  (ByteArray.empty.push 0x19) ++ ("Ethereum Signed Message:\n" ++ toString msg.size).toByteArray ++ msg

def signPersonalMessageIO (msg privateKey : ByteArray) :
    IO (Except String Signature) := do
  let digest ← Hacl.keccak256EthereumIO
    (LeanKohaku.Crypto.Hex.encode (personalMessagePayload msg))
  match digest with
  | .error err => pure (.error err)
  | .ok digestBytes => signDigestIO privateKey digestBytes

end LeanKohaku.Wallet.EOA
