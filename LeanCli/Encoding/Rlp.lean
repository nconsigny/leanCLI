/-!
# Recursive Length Prefix (RLP)

Minimal Ethereum RLP encoder used for typed transaction payloads, plus a
strict decoder used by the Merkle-Patricia proof verifier
(`LeanCli.Ethereum.Mpt`). The decoder is total (fuel-indexed, fuel =
input size) and canonical: non-minimal length encodings and single bytes
wrapped in an unnecessary `0x81` prefix are rejected, so a malicious
proof node cannot have two distinct valid encodings.
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

/-! ## Decoder -/

/-- Bytes `[start, start+len)` of `b`; `none` when out of range. -/
def slice? (b : ByteArray) (start len : Nat) : Option ByteArray :=
  if start + len ≤ b.size then
    some ((List.range len).foldl
      (init := ByteArray.empty)
      (fun acc i => acc.push (b.get! (start + i))))
  else
    none

/-- Big-endian Nat from `count` bytes at `pos`. Canonical: rejects a
    leading zero byte (non-minimal length encoding). -/
def beLen? (b : ByteArray) (pos count : Nat) : Option Nat := do
  let payload ← slice? b pos count
  if count > 0 && payload.get! 0 == 0 then none
  else
    some (payload.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat))

mutual
  /-- Decode one item at `pos`; returns the item and the bytes consumed.
      Fuel bounds recursion depth (any `b.size + 1` is sufficient). -/
  def decodeItemAux : Nat → ByteArray → Nat → Option (Item × Nat)
    | 0, _, _ => none
    | fuel + 1, b, pos => do
        if pos < b.size then
          let b0 := (b.get! pos).toNat
          if b0 < 0x80 then
            -- single byte, its own encoding
            some (.bytes (ByteArray.empty.push (b.get! pos)), 1)
          else if b0 ≤ 0xb7 then
            let len := b0 - 0x80
            let payload ← slice? b (pos + 1) len
            -- canonical: a 1-byte payload < 0x80 must use the single-byte form
            if len == 1 && payload.get! 0 < 0x80 then none
            else some (.bytes payload, 1 + len)
          else if b0 ≤ 0xbf then
            let lenOfLen := b0 - 0xb7
            let len ← beLen? b (pos + 1) lenOfLen
            if len ≤ 55 then none  -- canonical: short form required
            else
              let payload ← slice? b (pos + 1 + lenOfLen) len
              some (.bytes payload, 1 + lenOfLen + len)
          else if b0 ≤ 0xf7 then
            let len := b0 - 0xc0
            if pos + 1 + len ≤ b.size then
              let items ← decodeListAux fuel b (pos + 1) (pos + 1 + len)
              some (.list items, 1 + len)
            else none
          else
            let lenOfLen := b0 - 0xf7
            let len ← beLen? b (pos + 1) lenOfLen
            if len ≤ 55 then none  -- canonical: short form required
            else if pos + 1 + lenOfLen + len ≤ b.size then
              let items ← decodeListAux fuel b (pos + 1 + lenOfLen) (pos + 1 + lenOfLen + len)
              some (.list items, 1 + lenOfLen + len)
            else none
        else
          none

  /-- Decode consecutive items in `[pos, stop)` until the window is
      exactly exhausted. -/
  def decodeListAux : Nat → ByteArray → Nat → Nat → Option (List Item)
    | 0, _, _, _ => none
    | fuel + 1, b, pos, stop =>
        if pos == stop then some []
        else if pos > stop then none
        else do
          let (item, used) ← decodeItemAux fuel b pos
          if pos + used > stop then none
          else
            let rest ← decodeListAux fuel b (pos + used) stop
            some (item :: rest)
end

/-- Decode a complete RLP payload; rejects trailing bytes. -/
def decode (b : ByteArray) : Option Item :=
  match decodeItemAux (b.size + 1) b 0 with
  | some (item, used) => if used == b.size then some item else none
  | none => none

end LeanCli.Encoding.Rlp
