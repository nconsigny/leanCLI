import LeanCli.Ethereum.Address
import LeanCli.Crypto.Secp256k1
import LeanCli.Encoding.Rlp

/-!
# Ethereum transactions

Type-2 (EIP-1559) transactions only to start. We model them at the
abstract level first; byte-level transaction encoding will be reintroduced
when it is needed by a production signing path.
-/

namespace LeanCli.Ethereum.Tx

open LeanCli.Ethereum.Address
open LeanCli.Crypto.Secp256k1
open LeanCli.Encoding.Rlp

/-- Unsigned EIP-1559 transaction. `value`, `gas*`, `nonce` are Nat — we'll
refine to explicit bit-widths (`UInt256`) after we settle the encoding. -/
structure TxEip1559 where
  chainId              : Nat
  nonce                : Nat
  maxPriorityFeePerGas : Nat
  maxFeePerGas         : Nat
  gasLimit             : Nat
  to                   : Option Address
  value                : Nat
  data                 : ByteArray
  accessList           : List (Address × List ByteArray) := []

/-- Signed transaction bundles the unsigned body with the signature. -/
structure SignedTx where
  unsigned : TxEip1559
  sig      : Signature

def encodeAddressOption : Option Address → Item
  | none => .bytes ByteArray.empty
  | some address => .bytes address.bytes

def encodeAccessListEntry (entry : Address × List ByteArray) : Item :=
  .list [
    .bytes entry.fst.bytes,
    .list (entry.snd.map (fun key => .bytes key))
  ]

def encodeAccessList (accessList : List (Address × List ByteArray)) : Item :=
  .list (accessList.map encodeAccessListEntry)

def TxEip1559.signingPayload (tx : TxEip1559) : ByteArray :=
  LeanCli.Encoding.Rlp.append (LeanCli.Encoding.Rlp.singleton 0x02) <|
    LeanCli.Encoding.Rlp.encode <| .list [
      encodeNat tx.chainId,
      encodeNat tx.nonce,
      encodeNat tx.maxPriorityFeePerGas,
      encodeNat tx.maxFeePerGas,
      encodeNat tx.gasLimit,
      encodeAddressOption tx.to,
      encodeNat tx.value,
      .bytes tx.data,
      encodeAccessList tx.accessList
    ]

def SignedTx.encode (tx : SignedTx) : ByteArray :=
  LeanCli.Encoding.Rlp.append (LeanCli.Encoding.Rlp.singleton 0x02) <|
    LeanCli.Encoding.Rlp.encode <| .list [
      encodeNat tx.unsigned.chainId,
      encodeNat tx.unsigned.nonce,
      encodeNat tx.unsigned.maxPriorityFeePerGas,
      encodeNat tx.unsigned.maxFeePerGas,
      encodeNat tx.unsigned.gasLimit,
      encodeAddressOption tx.unsigned.to,
      encodeNat tx.unsigned.value,
      .bytes tx.unsigned.data,
      encodeAccessList tx.unsigned.accessList,
      encodeNat tx.sig.v.toNat,
      encodeNat tx.sig.r,
      encodeNat tx.sig.s
    ]

end LeanCli.Ethereum.Tx
