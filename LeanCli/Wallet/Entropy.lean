import LeanCli.Crypto.Random
import LeanCli.Wallet.Mnemonic

/-!
# BIP-39 entropy generation
-/

namespace LeanCli.Wallet.Entropy

open LeanCli.Wallet.Mnemonic

def entropyBytesForWordCount : Nat → Option Nat
  | 12 => some 16
  | 15 => some 20
  | 18 => some 24
  | 21 => some 28
  | 24 => some 32
  | _ => none

def generateMnemonic (wordCount : Nat) : IO Mnemonic := do
  let bytesLen ←
    match entropyBytesForWordCount wordCount with
    | some n => pure n
    | none => throw <| IO.userError s!"unsupported BIP-39 word count: {wordCount}"
  let entropy ← LeanCli.Crypto.Random.getRandomBytes bytesLen
  match ← entropyToWords entropy with
  | some mnemonic => pure mnemonic
  | none => throw <| IO.userError "failed to convert entropy to mnemonic"

end LeanCli.Wallet.Entropy
