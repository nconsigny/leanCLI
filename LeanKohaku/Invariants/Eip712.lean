import LeanKohaku.Ethereum.Eip712

/-!
# EIP-712 sanity vector

The canonical "Mail" example from EIP-712 ships well-known intermediate
values: the `encodeType` string, the `typeHash`, and the final digest. We
expose them here so a small `IO` runner (see `script/check_eip712.sh`) can
assert byte equality against the `keccak`-driven implementation.

Pure parts (the `encodeType` string) ARE checked at build time. The
`keccak` boundary stays IO-only, which is consistent with the rest of the
crypto layer.
-/

namespace LeanKohaku.Invariants.Eip712

open LeanKohaku.Ethereum.Eip712

/-! ## Mail vector — pure facts checked at build time -/

/-- Mail registry as an in-Lean literal, mirroring the JSON `types`. -/
def mailRegistry : Registry := {
  entries := #[
    ("EIP712Domain", #[
      { name := "name", typeStr := "string" },
      { name := "version", typeStr := "string" },
      { name := "chainId", typeStr := "uint256" },
      { name := "verifyingContract", typeStr := "address" }]),
    ("Person", #[
      { name := "name", typeStr := "string" },
      { name := "wallet", typeStr := "address" }]),
    ("Mail", #[
      { name := "from", typeStr := "Person" },
      { name := "to", typeStr := "Person" },
      { name := "contents", typeStr := "string" }])
  ]
}

/-- Canonical encodeType for `Mail`. Person sorts after Mail; both are
    referenced transitively from primary so encodeType is
    `Mail(...)Person(...)`. -/
example :
    encodeType mailRegistry "Mail"
      = .ok "Mail(Person from,Person to,string contents)Person(string name,address wallet)" := by
  rfl

/-- Canonical encodeType for `EIP712Domain`. -/
example :
    encodeType mailRegistry "EIP712Domain"
      = .ok "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)" := by
  rfl

end LeanKohaku.Invariants.Eip712
