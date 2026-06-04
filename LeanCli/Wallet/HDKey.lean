import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Secp256k1
import LeanCli.Crypto.Secp256k1Native
import LeanCli.Encoding.Rlp

/-!
# BIP32 derivation scaffold

This module implements the structural BIP32 derivation interface and delegates
HMAC-SHA512 to the HACL boundary. Full hardened/non-hardened child derivation
requires secp256k1 public-key serialization; that will be filled in once the
K1 public-key path is complete.
-/

namespace LeanCli.Wallet.HDKey

open LeanCli.Crypto.Hacl
open LeanCli.Crypto.Secp256k1
open LeanCli.Crypto.Secp256k1Native
open LeanCli.Encoding.Rlp

structure ExtendedPrivateKey where
  key               : Nat
  chainCode         : ByteArray
  depth             : UInt8
  index             : UInt32
  parentFingerprint : UInt32

def hardenedOffset : UInt32 := 0x80000000

def take (bytes : ByteArray) (start len : Nat) : ByteArray :=
  (List.range len).foldl
    (init := ByteArray.empty)
    (fun acc i => acc.push bytes[start + i]!)

def Nat.toFixedBytes (len n : Nat) : ByteArray :=
  let raw := natBytes n
  if raw.size ≥ len then
    take raw (raw.size - len) len
  else
    concat [List.replicate (len - raw.size) (0 : UInt8) |>.toByteArray, raw]

def UInt32.toBytesBE (n : UInt32) : ByteArray :=
  ByteArray.empty
    |>.push (UInt8.ofNat ((n.toNat / 16777216) % 256))
    |>.push (UInt8.ofNat ((n.toNat / 65536) % 256))
    |>.push (UInt8.ofNat ((n.toNat / 256) % 256))
    |>.push (UInt8.ofNat (n.toNat % 256))

def masterKeySeed : ByteArray :=
  "Bitcoin seed".toByteArray

def bytesToNat (bytes : ByteArray) : Nat :=
  bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

def bytesToUInt32BE (bytes : ByteArray) : UInt32 :=
  UInt32.ofNat <| bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

def requireBytes (label : String) (expected : Nat) (bytes : ByteArray) :
    IO (Except String ByteArray) :=
  if bytes.size = expected then
    pure (.ok bytes)
  else
    pure (.error s!"{label}: expected {expected} bytes, got {bytes.size}")

def expectOk {α : Type} : Except String α → IO α
  | .ok value => pure value
  | .error err => throw <| IO.userError err

def fromSeed (seed : ByteArray) : ExtendedPrivateKey :=
  let i := hmacSha512 masterKeySeed seed
  { key := bytesToNat (take i 0 32),
    chainCode := take i 32 32,
    depth := 0,
    index := 0,
    parentFingerprint := 0 }

def fromSeedIO (seed : ByteArray) : IO (Except String ExtendedPrivateKey) := do
  let i ← hmacSha512IO (LeanCli.Crypto.Hex.encode masterKeySeed)
    (LeanCli.Crypto.Hex.encode seed)
  match i with
  | .error err => pure (.error err)
  | .ok bytes =>
      if bytes.size != 64 then
        pure (.error s!"fromSeedIO: expected 64 HMAC bytes, got {bytes.size}")
      else
        let key := bytesToNat (take bytes 0 32)
        if key = 0 ∨ key ≥ n then
          pure (.error "fromSeedIO: derived invalid master key")
        else
          pure <| .ok
            { key := key,
              chainCode := take bytes 32 32,
              depth := 0,
              index := 0,
              parentFingerprint := 0 }

def publicPoint (key : ExtendedPrivateKey) : Point :=
  scalarMul key.key G

def compressedPublicKey (key : ExtendedPrivateKey) : Option ByteArray :=
  match publicPoint key with
  | .infinity => none
  | .affine x y =>
      let prefixByte : UInt8 := if y % 2 = 0 then 0x02 else 0x03
      some (concat [ByteArray.empty.push prefixByte, Nat.toFixedBytes 32 x])

def childData (parent : ExtendedPrivateKey) (index : UInt32) : Option ByteArray :=
  if index.toNat ≥ hardenedOffset.toNat then
    some <| concat [
      ByteArray.empty.push 0,
      Nat.toFixedBytes 32 parent.key,
      UInt32.toBytesBE index
    ]
  else
    match compressedPublicKey parent with
    | none => none
    | some pub =>
        some <| concat [pub, UInt32.toBytesBE index]

def deriveChild (parent : ExtendedPrivateKey) (index : UInt32) : Option ExtendedPrivateKey := do
  let data ← childData parent index
  let i := hmacSha512 parent.chainCode data
  let il := bytesToNat (take i 0 32)
  let ir := take i 32 32
  if il ≥ n then
    none
  else
    let childKey := (il + parent.key) % n
    if childKey = 0 then
      none
    else
      some
        { key := childKey
          chainCode := ir
          depth := parent.depth + 1
          index := index
          parentFingerprint := 0 }

def compressedPublicKeyIO (key : ExtendedPrivateKey) : IO (Except String ByteArray) :=
  pubkeyIO (LeanCli.Crypto.Hex.encode (Nat.toFixedBytes 32 key.key)) true

def fingerprintIO (key : ExtendedPrivateKey) : IO (Except String UInt32) := do
  let pub ← compressedPublicKeyIO key
  match pub with
  | .error err => pure (.error err)
  | .ok pubBytes =>
      let sha ← sha256IO (LeanCli.Crypto.Hex.encode pubBytes)
      match sha with
      | .error err => pure (.error err)
      | .ok shaBytes =>
          let ripe ← ripemd160IO (LeanCli.Crypto.Hex.encode shaBytes)
          match ripe with
          | .error err => pure (.error err)
          | .ok ripeBytes =>
              if ripeBytes.size < 4 then
                pure (.error "fingerprintIO: RIPEMD-160 output too short")
              else
                pure (.ok (bytesToUInt32BE (take ripeBytes 0 4)))

def childDataIO (parent : ExtendedPrivateKey) (index : UInt32) :
    IO (Except String ByteArray) := do
  if index.toNat ≥ hardenedOffset.toNat then
    pure <| .ok <| concat [
      ByteArray.empty.push 0,
      Nat.toFixedBytes 32 parent.key,
      UInt32.toBytesBE index
    ]
  else
    let pub ← compressedPublicKeyIO parent
    match pub with
    | .error err => pure (.error err)
    | .ok pubBytes => pure <| .ok <| concat [pubBytes, UInt32.toBytesBE index]

def deriveChildIO (parent : ExtendedPrivateKey) (index : UInt32) :
    IO (Except String ExtendedPrivateKey) := do
  let data ← childDataIO parent index
  match data with
  | .error err => pure (.error err)
  | .ok dataBytes =>
      let i ← hmacSha512IO (LeanCli.Crypto.Hex.encode parent.chainCode)
        (LeanCli.Crypto.Hex.encode dataBytes)
      match i with
      | .error err => pure (.error err)
      | .ok bytes =>
          if bytes.size != 64 then
            pure (.error s!"deriveChildIO: expected 64 HMAC bytes, got {bytes.size}")
          else
            let il := bytesToNat (take bytes 0 32)
            let ir := take bytes 32 32
            if il ≥ n then
              pure (.error "deriveChildIO: IL is out of range")
            else
              let childKey := (il + parent.key) % n
              if childKey = 0 then
                pure (.error "deriveChildIO: derived zero child key")
              else
                let fp ← fingerprintIO parent
                match fp with
                | .error err => pure (.error err)
                | .ok parentFp =>
                    pure <| .ok
                      { key := childKey
                        chainCode := ir
                        depth := parent.depth + 1
                        index := index
                        parentFingerprint := parentFp }

def parsePathElem (s : String) : Except String UInt32 := do
  let hardened := s.endsWith "'"
  let digits := if hardened then (s.dropEnd 1).toString else s
  let n ←
    match digits.toNat? with
    | some n => .ok n
    | none => .error s!"invalid path element: {s}"
  if n ≥ hardenedOffset.toNat then
    .error s!"path element too large: {s}"
  else
    let raw := if hardened then n + hardenedOffset.toNat else n
    .ok (UInt32.ofNat raw)

def parsePath (path : String) : Except String (List UInt32) := do
  let parts := path.splitOn "/"
  match parts with
  | [] => .error "empty derivation path"
  | root :: rest =>
      if root != "m" then
        .error "derivation path must start with m"
      else
        rest.mapM parsePathElem

def derivePathIO (root : ExtendedPrivateKey) (path : String) :
    IO (Except String ExtendedPrivateKey) := do
  match parsePath path with
  | .error err => pure (.error err)
  | .ok indexes =>
      try
        let key ← indexes.foldlM
          (fun acc index => do
            let child ← deriveChildIO acc index
            expectOk child)
          root
        pure (.ok key)
      catch e =>
        pure (.error e.toString)

end LeanCli.Wallet.HDKey
