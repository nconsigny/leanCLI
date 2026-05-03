import LeanKohaku.Ethereum.Eip712
import LeanKohaku.Encoding.Json
import LeanKohaku.Crypto.Hex

/-!
# EIP-712 Mail vector smoke test

Standalone executable that runs the canonical Mail vector through
`computeDigestIO` and compares the digest to the spec value
`0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2`.
Exits non-zero on mismatch so it can be wired into CI.
-/

open LeanKohaku.Ethereum.Eip712
open LeanKohaku.Encoding.Json

def mailVectorJson : String :=
  "{\"types\":{\"EIP712Domain\":[" ++
    "{\"name\":\"name\",\"type\":\"string\"}," ++
    "{\"name\":\"version\",\"type\":\"string\"}," ++
    "{\"name\":\"chainId\",\"type\":\"uint256\"}," ++
    "{\"name\":\"verifyingContract\",\"type\":\"address\"}],\"Mail\":[" ++
    "{\"name\":\"from\",\"type\":\"Person\"}," ++
    "{\"name\":\"to\",\"type\":\"Person\"}," ++
    "{\"name\":\"contents\",\"type\":\"string\"}],\"Person\":[" ++
    "{\"name\":\"name\",\"type\":\"string\"}," ++
    "{\"name\":\"wallet\",\"type\":\"address\"}]}," ++
    "\"primaryType\":\"Mail\"," ++
    "\"domain\":{\"name\":\"Ether Mail\",\"version\":\"1\",\"chainId\":1," ++
      "\"verifyingContract\":\"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC\"}," ++
    "\"message\":{" ++
      "\"from\":{\"name\":\"Cow\",\"wallet\":\"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826\"}," ++
      "\"to\":{\"name\":\"Bob\",\"wallet\":\"0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB\"}," ++
      "\"contents\":\"Hello, Bob!\"}}"

def expectedDigest : String :=
  "0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2"

def main : IO UInt32 := do
  match parse mailVectorJson with
  | .error err =>
      IO.eprintln s!"vector parse failed: {err}"
      return 1
  | .ok td =>
      match ← computeDigestIO td with
      | .error err =>
          IO.eprintln s!"computeDigestIO failed: {err}"
          return 1
      | .ok d =>
          let digestHex := LeanKohaku.Crypto.Hex.encode d.digest
          IO.println s!"primaryType: {d.primaryType}"
          IO.println s!"domainSeparator: {LeanKohaku.Crypto.Hex.encode d.domainSeparator}"
          IO.println s!"messageHash: {LeanKohaku.Crypto.Hex.encode d.messageHash}"
          IO.println s!"digest: {digestHex}"
          IO.println s!"expected: {expectedDigest}"
          if digestHex == expectedDigest then
            IO.println "OK: Mail vector matches spec"
            return 0
          else
            IO.eprintln "MISMATCH"
            return 2
