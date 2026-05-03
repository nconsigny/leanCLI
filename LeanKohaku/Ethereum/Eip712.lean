import LeanKohaku.Crypto.Hacl
import LeanKohaku.Crypto.Hex
import LeanKohaku.Encoding.Json
import LeanKohaku.Wallet.HDKey

/-!
# EIP-712 typed data hashing

Pure structural assembly of the `encodeType` string and recursive
`hashStruct` digest, with keccak256 as the only IO boundary. Covers the
shapes used by Permit, Permit2, OpenSea Seaport, and Safe transactions.
Intentionally rejects shapes outside that envelope (e.g. fixed-size arrays
with non-decimal length, ints/uints with non-multiple-of-8 width).
-/

namespace LeanKohaku.Ethereum.Eip712

open LeanKohaku.Encoding.Json
open LeanKohaku.Crypto

/-- A field of a struct type: `(name, typeStr)`. -/
structure Field where
  name : String
  typeStr : String
  deriving Repr

/-- `types[name] = list of fields`. -/
structure Registry where
  entries : Array (String × Array Field)
  deriving Repr

def Registry.find? (r : Registry) (name : String) : Option (Array Field) :=
  r.entries.findSome? (fun (n, fs) => if n = name then some fs else none)

def Registry.has (r : Registry) (name : String) : Bool :=
  (r.find? name).isSome

/-! ## Type-string parsing

EIP-712 type strings are like `uint256`, `address`, `bytes32`, `Mail`,
`Person[]`, `Person[2]`. We strip a single trailing `[...]` to find the
inner type and detect arrays. We do not support nested arrays (`T[][]`)
since none of the targeted shapes use them; callers get a clear error.
-/

private def isDigitChar (c : Char) : Bool :=
  '0' ≤ c && c ≤ '9'

inductive ArrayKind where
  | none
  | dynamic
  | fixed (n : Nat)
  deriving Repr

/-- Strip one trailing `[k]` or `[]` if present.
    Returns `(innerType, arrayKind)`. -/
def parseArraySuffix (typeStr : String) : Except String (String × ArrayKind) :=
  let chars := typeStr.toList
  match chars.reverse with
  | ']' :: rest =>
      -- Find matching '['
      let revRest := rest
      -- Collect chars until '['
      let rec go (cs : List Char) (acc : List Char) : Except String (String × ArrayKind) :=
        match cs with
        | [] => .error s!"unterminated array brackets in type: {typeStr}"
        | '[' :: more =>
            -- `more` is reversed inner type; reverse again to get inner
            let inner := String.ofList more.reverse
            if acc.isEmpty then
              .ok (inner, .dynamic)
            else if acc.all isDigitChar then
              -- decimal length
              let n := acc.foldl (init := 0) (fun a c => a * 10 + (c.toNat - '0'.toNat))
              .ok (inner, .fixed n)
            else
              .error s!"invalid array length in type: {typeStr}"
        | c :: more => go more (c :: acc)
      go revRest []
  | _ => .ok (typeStr, .none)

/-! ## Atomic-type recognition -/

/-- Is `t` an EIP-712 atomic/dynamic primitive (not a struct)? -/
def isPrimitive (t : String) : Bool :=
  t = "address" || t = "bool" || t = "string" || t = "bytes"
    || t.startsWith "uint" || t.startsWith "int" || t.startsWith "bytes"

/-- Parse `uintN` / `intN` width in bits. Returns `none` for bare `uint`/`int`
    (which EIP-712 maps to width 256) or for non-multiple-of-8 widths. -/
def parseIntWidth (suffix : String) : Except String Nat :=
  if suffix.isEmpty then .ok 256
  else if suffix.toList.all isDigitChar then
    let n := suffix.toList.foldl (init := 0) (fun a c => a * 10 + (c.toNat - '0'.toNat))
    if n = 0 || n > 256 || n % 8 ≠ 0 then
      .error s!"invalid int width: {n}"
    else .ok n
  else .error s!"invalid int width suffix: {suffix}"

/-- Parse `bytesN` size 1..32. -/
def parseBytesNSize (suffix : String) : Except String Nat :=
  if suffix.isEmpty then .error "bare 'bytes' is dynamic, not bytesN"
  else if suffix.toList.all isDigitChar then
    let n := suffix.toList.foldl (init := 0) (fun a c => a * 10 + (c.toNat - '0'.toNat))
    if n = 0 || n > 32 then .error s!"invalid bytesN size: {n}"
    else .ok n
  else .error s!"invalid bytesN size: {suffix}"

/-! ## Registry construction from JSON -/

private def fieldFromJson (json : Json) : Except String Field := do
  match getField "name" json >>= asString, getField "type" json >>= asString with
  | some n, some t => .ok { name := n, typeStr := t }
  | _, _ => .error "field missing name/type"

def registryFromJson (typesJson : Json) : Except String Registry := do
  match typesJson with
  | .obj fields => do
      let mut acc : Array (String × Array Field) := #[]
      for (typeName, value) in fields do
        match value with
        | .arr items =>
            let mut fs : Array Field := #[]
            for it in items do
              fs := fs.push (← fieldFromJson it)
            acc := acc.push (typeName, fs)
        | _ => throw s!"types['{typeName}'] must be an array"
      .ok { entries := acc }
  | _ => .error "types must be an object"

/-! ## encodeType

For struct type T, `encodeType(T) = T(field1Type field1Name,...)` followed by
all transitively-referenced struct types other than T, sorted alphabetically.
-/

/-- Strip a single trailing array suffix to find the innermost type. We
    only handle one level of array brackets — that's all the targeted
    shapes use. -/
private def innerStructName? (r : Registry) (typeStr : String) : Option String :=
  match parseArraySuffix typeStr with
  | .ok (inner, _) =>
      if r.has inner then some inner else none
  | .error _ => none

partial def collectDeps (r : Registry) (root : String) : Except String (Array String) := do
  let rec walk (name : String) : StateM (Array String) (Except String Unit) := do
    let seen ← get
    if seen.contains name then return .ok ()
    set (seen.push name)
    match r.find? name with
    | none => return .error s!"unknown struct type: {name}"
    | some fields =>
        for f in fields do
          match innerStructName? r f.typeStr with
          | some s =>
              match ← walk s with
              | .ok () => pure ()
              | .error e => return .error e
          | none => pure ()
        return .ok ()
  match (walk root).run #[] with
  | (.ok (), seen) => .ok seen
  | (.error e, _) => .error e

/-- Render `T(t1 n1,t2 n2,...)`. -/
def renderOne (name : String) (fields : Array Field) : String :=
  let body :=
    fields.toList.map (fun f => f.typeStr ++ " " ++ f.name)
      |> String.intercalate ","
  name ++ "(" ++ body ++ ")"

/-- Compute `encodeType(primary)`. -/
def encodeType (r : Registry) (primary : String) : Except String String := do
  let deps ← collectDeps r primary
  -- Drop primary, sort the rest alphabetically.
  let rest := (deps.toList.filter (· ≠ primary)).mergeSort (· ≤ ·)
  let primaryFields ←
    match r.find? primary with
    | some fs => .ok fs
    | none => .error s!"unknown primary type: {primary}"
  let primaryStr := renderOne primary primaryFields
  let restStrs ← rest.mapM (fun n =>
    match r.find? n with
    | some fs => .ok (renderOne n fs)
    | none => .error s!"unknown referenced type: {n}")
  .ok (primaryStr ++ String.join restStrs)

/-! ## Encoding values to 32-byte words -/

private def zeroPad32 (bytes : ByteArray) : ByteArray :=
  if bytes.size ≥ 32 then bytes
  else
    let pad := List.replicate (32 - bytes.size) (0 : UInt8) |>.toByteArray
    pad ++ bytes

private def rightPad32 (bytes : ByteArray) : ByteArray :=
  if bytes.size ≥ 32 then bytes
  else
    let pad := List.replicate (32 - bytes.size) (0 : UInt8) |>.toByteArray
    bytes ++ pad

private def stripHexPrefix (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then (s.drop 2).toString else s

private def parseDecimal (s : String) : Option Nat :=
  if s.isEmpty then none
  else if s.toList.all isDigitChar then
    some (s.toList.foldl (init := 0) (fun a c => a * 10 + (c.toNat - '0'.toNat)))
  else none

private def parseHexNat (s : String) : Option Nat :=
  let raw := stripHexPrefix s
  if raw.isEmpty then none
  else
    raw.toList.foldl (init := some 0) (fun acc c =>
      match acc, Hex.hexDigit? c with
      | some n, some d => some (n * 16 + d.toNat)
      | _, _ => none)

/-- Parse a JSON value as a non-negative integer.
    Accepts `Json.num n` (n ≥ 0), decimal strings, and `0x…` hex strings. -/
def parseUintValue (j : Json) : Except String Nat :=
  match j with
  | .num n =>
      if n ≥ 0 then .ok n.toNat
      else .error "negative value for uint"
  | .str s =>
      if s.startsWith "0x" || s.startsWith "0X" then
        match parseHexNat s with
        | some n => .ok n
        | none => .error s!"invalid hex uint: {s}"
      else
        match parseDecimal s with
        | some n => .ok n
        | none => .error s!"invalid decimal uint: {s}"
  | _ => .error "uint value must be number or string"

/-- 2's-complement `intN` -> 32-byte big-endian. Accepts negative numbers
    only via JSON `num`; signed-string parsing isn't needed for the targeted
    shapes (Permit/Permit2/Seaport/Safe all use unsigned). -/
def encodeIntValue (width : Nat) (j : Json) : Except String ByteArray := do
  match j with
  | .num n =>
      if n ≥ 0 then
        let nat := n.toNat
        let bound := 2 ^ (width - 1)
        if nat ≥ bound then .error s!"int{width} value out of range"
        else .ok (zeroPad32 (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 nat))
      else
        -- negative: 2^256 + n (treat full 32-byte two's complement; width
        -- still bounds magnitude).
        let mag := (-n).toNat
        let bound := 2 ^ (width - 1)
        if mag > bound then .error s!"int{width} value out of range"
        else
          let twos := 2 ^ 256 - mag
          .ok (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 twos)
  | _ =>
      let n ← parseUintValue j
      let bound := 2 ^ (width - 1)
      if n ≥ bound then .error s!"int{width} value out of range"
      else .ok (zeroPad32 (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 n))

def encodeUintValue (width : Nat) (j : Json) : Except String ByteArray := do
  let n ← parseUintValue j
  if width < 256 then
    if n ≥ 2 ^ width then .error s!"uint{width} value out of range"
    else pure ()
  .ok (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 n)

def encodeBoolValue (j : Json) : Except String ByteArray :=
  match j with
  | .bool b => .ok (zeroPad32 (ByteArray.empty.push (if b then 0x01 else 0x00)))
  | _ => .error "bool value must be JSON bool"

def encodeAddressValue (j : Json) : Except String ByteArray := do
  match j with
  | .str s =>
      let raw := stripHexPrefix s
      if raw.length ≠ 40 then
        .error s!"address must be 40 hex chars: {s}"
      else match Hex.decode s with
        | none => .error s!"address not hex: {s}"
        | some b =>
            if b.size ≠ 20 then .error s!"address not 20 bytes: {s}"
            else .ok (zeroPad32 b)
  | _ => .error "address value must be a string"

def encodeBytesNValue (size : Nat) (j : Json) : Except String ByteArray := do
  match j with
  | .str s =>
      match Hex.decode s with
      | none => .error s!"bytesN value not hex: {s}"
      | some b =>
          if b.size ≠ size then
            .error s!"bytes{size} got {b.size} bytes"
          else .ok (rightPad32 b)
  | _ => .error "bytesN value must be hex string"

/-- keccak256 over a ByteArray. Returns 32 bytes. -/
def keccakIO (bytes : ByteArray) : IO (Except String ByteArray) :=
  Hacl.keccak256EthereumIO (Hex.encode bytes)

def encodeStringValueIO (j : Json) : IO (Except String ByteArray) := do
  match j with
  | .str s => keccakIO s.toUTF8
  | _ => pure (.error "string value must be JSON string")

def encodeDynamicBytesIO (j : Json) : IO (Except String ByteArray) := do
  match j with
  | .str s =>
      match Hex.decode s with
      | none => pure (.error s!"bytes value not hex: {s}")
      | some b => keccakIO b
  | _ => pure (.error "bytes value must be hex string")

/-! ## Recursive hashing -/

mutual

/-- Encode a value of the given `typeStr` to a 32-byte word. -/
partial def encodeValueIO (r : Registry) (typeStr : String) (value : Json) :
    IO (Except String ByteArray) := do
  match parseArraySuffix typeStr with
  | .error e => pure (.error e)
  | .ok (inner, .none) =>
      -- Atomic / struct
      if inner = "bool" then pure (encodeBoolValue value)
      else if inner = "address" then pure (encodeAddressValue value)
      else if inner = "string" then encodeStringValueIO value
      else if inner = "bytes" then encodeDynamicBytesIO value
      else if inner.startsWith "uint" then
        match parseIntWidth (inner.drop 4).toString with
        | .ok w => pure (encodeUintValue w value)
        | .error e => pure (.error e)
      else if inner.startsWith "int" then
        match parseIntWidth (inner.drop 3).toString with
        | .ok w => pure (encodeIntValue w value)
        | .error e => pure (.error e)
      else if inner.startsWith "bytes" then
        match parseBytesNSize (inner.drop 5).toString with
        | .ok n => pure (encodeBytesNValue n value)
        | .error e => pure (.error e)
      else if r.has inner then
        hashStructIO r inner value
      else
        pure (.error s!"unknown type: {inner}")
  | .ok (inner, _) =>
      -- Array: keccak256(concat (encodeValue inner each-element))
      match value with
      | .arr items => do
          let mut buf : ByteArray := ByteArray.empty
          for it in items do
            match ← encodeValueIO r inner it with
            | .error e => return .error e
            | .ok w => buf := buf ++ w
          keccakIO buf
      | _ => pure (.error s!"array value must be JSON array for type {typeStr}")

/-- `hashStruct(T, data) = keccak256(typeHash(T) || encodeData(T, data))`. -/
partial def hashStructIO (r : Registry) (typeName : String) (data : Json) :
    IO (Except String ByteArray) := do
  match encodeType r typeName with
  | .error e => pure (.error e)
  | .ok et =>
      match ← keccakIO et.toUTF8 with
      | .error e => pure (.error e)
      | .ok typeHash =>
          match r.find? typeName with
          | none => pure (.error s!"unknown struct type: {typeName}")
          | some fields => do
              let mut buf : ByteArray := typeHash
              for f in fields do
                match getField f.name data with
                | none => return .error s!"missing field '{f.name}' in {typeName}"
                | some v =>
                    match ← encodeValueIO r f.typeStr v with
                    | .error e => return .error e
                    | .ok w => buf := buf ++ w
              keccakIO buf

end -- mutual

/-! ## Top-level digest -/

structure Digest where
  domainSeparator : ByteArray
  messageHash : ByteArray
  digest : ByteArray
  primaryType : String

def computeDigestIO (typedData : Json) : IO (Except String Digest) := do
  let typesJson :=
    match getField "types" typedData with
    | some t => t
    | none => .null
  let primaryType :=
    (getField "primaryType" typedData >>= asString).getD ""
  let domainJson :=
    match getField "domain" typedData with
    | some d => d
    | none => .obj #[]
  let messageJson :=
    match getField "message" typedData with
    | some m => m
    | none => .null
  if primaryType.isEmpty then return .error "missing primaryType"
  match registryFromJson typesJson with
  | .error e => return .error e
  | .ok r =>
      if !r.has "EIP712Domain" then
        return .error "types must define EIP712Domain"
      if !r.has primaryType then
        return .error s!"types must define primaryType '{primaryType}'"
      match ← hashStructIO r "EIP712Domain" domainJson with
      | .error e => return .error e
      | .ok ds =>
          match ← hashStructIO r primaryType messageJson with
          | .error e => return .error e
          | .ok mh => do
              -- Why: 0x1901 || domainSeparator || hashStruct(message)
              let pfx := ByteArray.empty.push 0x19 |>.push 0x01
              let payload := pfx ++ ds ++ mh
              match ← keccakIO payload with
              | .error e => return .error e
              | .ok digest =>
                  return .ok {
                    domainSeparator := ds,
                    messageHash := mh,
                    digest := digest,
                    primaryType := primaryType
                  }

end LeanKohaku.Ethereum.Eip712
