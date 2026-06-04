import LeanCli.Crypto.Hacl
import LeanCli.Crypto.Hex
import LeanCli.Wallet.Bip39Wordlist

/-!
# BIP39 mnemonic model

Word-list validation is added separately with the canonical English list.
Mnemonic-to-seed already goes through the native PBKDF2-HMAC-SHA512 boundary.
-/

namespace LeanCli.Wallet.Mnemonic

structure Mnemonic where
  words : List String
  deriving Repr, DecidableEq

def wordCountValid (m : Mnemonic) : Bool :=
  [12, 15, 18, 21, 24].contains m.words.length

def wordsKnown (m : Mnemonic) : Bool :=
  m.words.all LeanCli.Wallet.Bip39Wordlist.contains

private def checksumBitsForEntropyBytes (n : Nat) : Option Nat :=
  match n with
  | 16 => some 4
  | 20 => some 5
  | 24 => some 6
  | 28 => some 7
  | 32 => some 8
  | _ => none

private def bitAt (bytes : ByteArray) (i : Nat) : Nat :=
  let b := bytes[i / 8]!
  let shift := 7 - (i % 8)
  (b.toNat / (2 ^ shift)) % 2

private def combinedBit (entropy checksum : ByteArray) (entBits : Nat) (i : Nat) : Nat :=
  if i < entBits then bitAt entropy i else bitAt checksum (i - entBits)

private def wordIndexAt (entropy checksum : ByteArray) (entBits : Nat) (word : Nat) : Nat :=
  (List.range 11).foldl
    (init := 0)
    (fun acc j => acc * 2 + combinedBit entropy checksum entBits (word * 11 + j))

private def wordsFromBits (entropy checksum : ByteArray) (entBits totalBits : Nat) :
    Array String :=
  (List.range (totalBits / 11)).foldl
    (init := #[])
    (fun acc i => acc.push LeanCli.Wallet.Bip39Wordlist.words[wordIndexAt entropy checksum entBits i]!)

def entropyToWords (entropy : ByteArray) : IO (Option Mnemonic) := do
  match checksumBitsForEntropyBytes entropy.size with
  | none => pure none
  | some csBits =>
      let checksum ← LeanCli.Crypto.Hacl.sha256IO
        (LeanCli.Crypto.Hex.encode entropy)
      match checksum with
      | .error _ => pure none
      | .ok checksumBytes =>
          let entBits := entropy.size * 8
          let words := wordsFromBits entropy checksumBytes entBits (entBits + csBits)
          pure (some { words := words.toList })

private def entropyBytesForMnemonicWords (n : Nat) : Option Nat :=
  match n with
  | 12 => some 16
  | 15 => some 20
  | 18 => some 24
  | 21 => some 28
  | 24 => some 32
  | _ => none

private def wordBit (index bit : Nat) : Nat :=
  (index / (2 ^ (10 - bit))) % 2

private def mnemonicBit (indexes : Array Nat) (i : Nat) : Nat :=
  wordBit indexes[i / 11]! (i % 11)

private def byteFromMnemonicBits (indexes : Array Nat) (byteIndex : Nat) : UInt8 :=
  UInt8.ofNat <| (List.range 8).foldl
    (init := 0)
    (fun acc bit => acc * 2 + mnemonicBit indexes (byteIndex * 8 + bit))

private def entropyFromIndexes (indexes : Array Nat) (entropyBytes : Nat) : ByteArray :=
  (List.range entropyBytes).foldl
    (init := ByteArray.empty)
    (fun acc i => acc.push (byteFromMnemonicBits indexes i))

def wordsToEntropy (m : Mnemonic) : IO (Option ByteArray) := do
  match entropyBytesForMnemonicWords m.words.length with
  | none => pure none
  | some entropyBytes =>
      let some indexes := m.words.mapM LeanCli.Wallet.Bip39Wordlist.wordIndex
        | pure none
      let entropy := entropyFromIndexes indexes.toArray entropyBytes
      match ← entropyToWords entropy with
      | some roundTrip =>
          if roundTrip.words = m.words then pure (some entropy) else pure none
      | none => pure none

def mnemonicValid (m : Mnemonic) : IO Bool := do
  if !(wordCountValid m && wordsKnown m) then
    pure false
  else
    match ← wordsToEntropy m with
    | some _ => pure true
    | none => pure false

def phrase (m : Mnemonic) : String :=
  String.intercalate " " m.words

def mnemonicToSeedIO (m : Mnemonic) (passphrase : String) :
    IO (Except String ByteArray) := do
  let valid ← mnemonicValid m
  if !valid then
    pure (.error "invalid BIP-39 mnemonic")
  else
    let passwordHex := LeanCli.Crypto.Hex.encode (phrase m).toByteArray
    let saltHex := LeanCli.Crypto.Hex.encode ("mnemonic" ++ passphrase).toByteArray
    LeanCli.Crypto.Hacl.pbkdf2HmacSha512IO passwordHex saltHex 2048 64

end LeanCli.Wallet.Mnemonic
