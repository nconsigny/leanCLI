import LeanKohaku.Ethereum.Ens
import LeanKohaku.Crypto.Hex

/-!
# ENS namehash smoke test

Computes namehashes for the well-known names `eth` and `vitalik.eth` and
compares to EIP-137 spec values. Exits non-zero on mismatch so it can be
wired into CI.
-/

open LeanKohaku.Ethereum.Ens

def expectedEth : String :=
  "0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae"

def expectedVitalik : String :=
  "0xee6c4522aab0003e8d14cd40a6af439055fd2577951148c14b6cea9a53475835"

private def check (name expected : String) : IO Bool := do
  match ← namehashIO name with
  | .error e =>
      IO.eprintln s!"namehash({name}) failed: {e}"
      pure false
  | .ok bytes =>
      let got := LeanKohaku.Crypto.Hex.encode bytes
      IO.println s!"namehash({name}) = {got}"
      IO.println s!"expected         = {expected}"
      pure (got == expected)

def main : IO UInt32 := do
  let a ← check "eth" expectedEth
  let b ← check "vitalik.eth" expectedVitalik
  if a && b then
    IO.println "OK: ENS namehash vectors match"
    pure 0
  else
    IO.eprintln "MISMATCH"
    pure 2
