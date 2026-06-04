/-!
# Recursive Length Prefix (RLP)

Minimal Ethereum RLP encoder used for typed transaction payloads.
-/

namespace LeanCli.Encoding.Rlp

inductive Item where
  | bytes (value : ByteArray)
  | list (items : List Item)

def singleton (b : UInt8) : ByteArray :=
  ByteArray.empty.push b

def append (a b : ByteArray) : ByteArray :=
  b.foldl (init := a) (fun acc byte => acc.push byte)

def concat (xs : List ByteArray) : ByteArray :=
  xs.foldl append ByteArray.empty

partial def natBytesAux : Nat → List UInt8 → List UInt8
  | 0, acc => acc
  | n, acc => natBytesAux (n / 256) (UInt8.ofNat (n % 256) :: acc)

def natBytes (n : Nat) : ByteArray :=
  match n with
  | 0 => ByteArray.empty
  | _ => (natBytesAux n []).toByteArray

def lengthBytes (n : Nat) : ByteArray :=
  natBytes n

def encodeBytes (payload : ByteArray) : ByteArray :=
  let len := payload.size
  if len = 1 then
    let b := payload[0]!
    if b < 0x80 then payload
    else append (singleton (UInt8.ofNat (0x80 + len))) payload
  else if len ≤ 55 then
    append (singleton (UInt8.ofNat (0x80 + len))) payload
  else
    let lenBytes := lengthBytes len
    append (append (singleton (UInt8.ofNat (0xb7 + lenBytes.size))) lenBytes) payload

def encodeListPayload (payload : ByteArray) : ByteArray :=
  let len := payload.size
  if len ≤ 55 then
    append (singleton (UInt8.ofNat (0xc0 + len))) payload
  else
    let lenBytes := lengthBytes len
    append (append (singleton (UInt8.ofNat (0xf7 + lenBytes.size))) lenBytes) payload

partial def encode : Item → ByteArray
  | .bytes value => encodeBytes value
  | .list items => encodeListPayload (concat (items.map encode))

def encodeNat (n : Nat) : Item :=
  .bytes (natBytes n)

def encodeByteArray (bytes : ByteArray) : Item :=
  .bytes bytes

def encodeEmptyList : Item :=
  .list []

end LeanCli.Encoding.Rlp
