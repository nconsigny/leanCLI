import LeanCli.Wallet.HDKey

/-!
# BIP-44 Ethereum paths

Canonical EOA paths are `m/44'/60'/<account>'/<change>/<index>`.
-/

namespace LeanCli.Wallet.Bip44

def parsePath (path : String) : Except String (List UInt32) :=
  LeanCli.Wallet.HDKey.parsePath path

def isHardened (i : UInt32) : Bool :=
  i.toNat ≥ LeanCli.Wallet.HDKey.hardenedOffset.toNat

def unharden (i : UInt32) : Nat :=
  i.toNat - LeanCli.Wallet.HDKey.hardenedOffset.toNat

def validateEthereumPath (path : String) : Except String (List UInt32) := do
  let indexes ← parsePath path
  match indexes with
  | [purpose, coin, account, change, index] =>
      if !(isHardened purpose) || unharden purpose != 44 then
        .error "BIP-44 purpose must be 44'"
      else if !(isHardened coin) || unharden coin != 60 then
        .error "Ethereum coin type must be 60'"
      else if !(isHardened account) then
        .error "account component must be hardened"
      else if isHardened change then
        .error "change component must be non-hardened"
      else if change.toNat != 0 && change.toNat != 1 then
        .error "change component must be 0 or 1"
      else if isHardened index then
        .error "address index must be non-hardened"
      else
        .ok indexes
  | _ => .error "Ethereum BIP-44 path must have 5 components after m"

def canonicalEthereumPath (account change index : Nat) : Except String String := do
  if account ≥ LeanCli.Wallet.HDKey.hardenedOffset.toNat then
    .error "account component too large"
  else if change ≥ LeanCli.Wallet.HDKey.hardenedOffset.toNat then
    .error "change component too large"
  else if change != 0 && change != 1 then
    .error "change component must be 0 or 1"
  else if index ≥ LeanCli.Wallet.HDKey.hardenedOffset.toNat then
    .error "index component too large"
  else
    .ok s!"m/44'/60'/{account}'/{change}/{index}"

end LeanCli.Wallet.Bip44
