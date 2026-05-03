import LeanKohaku.Ethereum.P256Precompile

/-!
# Wallet account model

The CLI supports two Ethereum account families:

* `eoaK1`: regular BIP-39/BIP-32 Ethereum EOA account, signing with k1.
* `r1Smart`: local hardware-backed P-256/R1 account verified by EIP-7951.

Both are local-only. Mainnet is the production default, and Sepolia is an
explicit dev/testnet target. No account kind implies remote custody or online
keystore access.
-/

namespace LeanKohaku.Wallet.Account

open LeanKohaku.Ethereum.P256Precompile

inductive AccountKind where
  | eoaK1
  | r1Smart
  deriving DecidableEq, Repr

inductive KeySource where
  | bip39Mnemonic
  | localEnclave
  deriving DecidableEq, Repr

structure DerivationPath where
  purpose : Nat
  coinType : Nat
  account : Nat
  change : Nat
  index : Nat
  deriving Repr, DecidableEq

def defaultEthereumPath : DerivationPath :=
  { purpose := 44, coinType := 60, account := 0, change := 0, index := 0 }

def DerivationPath.asString (p : DerivationPath) : String :=
  s!"m/{p.purpose}'/{p.coinType}'/{p.account}'/{p.change}/{p.index}"

structure AccountPolicy where
  kind     : AccountKind
  source   : KeySource
  chainId  : Nat := mainnetChainId
  path     : Option DerivationPath := none
  localOnly : Bool := true
  deriving Repr, DecidableEq

def compatible : AccountKind → KeySource → Bool
  | .eoaK1, .bip39Mnemonic => true
  | .r1Smart, .localEnclave => true
  | _, _ => false

def accepted (p : AccountPolicy) : Bool :=
  p.localOnly &&
    supportedChainId p.chainId &&
    compatible p.kind p.source &&
    match p.kind, p.path with
    | .eoaK1, some path => path.coinType = 60
    | .r1Smart, none => true
    | _, _ => false

def defaultEoaK1 : AccountPolicy :=
  { kind := .eoaK1,
    source := .bip39Mnemonic,
    chainId := mainnetChainId,
    path := some defaultEthereumPath,
    localOnly := true }

def defaultR1Smart : AccountPolicy :=
  { kind := .r1Smart,
    source := .localEnclave,
    chainId := mainnetChainId,
    path := none,
    localOnly := true }

def sepoliaEoaK1 : AccountPolicy :=
  { defaultEoaK1 with chainId := sepoliaChainId }

def sepoliaR1Smart : AccountPolicy :=
  { defaultR1Smart with chainId := sepoliaChainId }

-- Mainnet R1 smart-account policy. Identical to `defaultR1Smart` (mainnet
-- chainId), introduced for the `wallet deploy r1 --chain mainnet` gate.
def mainnetR1Smart : AccountPolicy :=
  { defaultR1Smart with chainId := mainnetChainId }

end LeanKohaku.Wallet.Account
