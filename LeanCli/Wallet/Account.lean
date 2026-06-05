import LeanCli.Ethereum.Chain

/-!
# Wallet account model

The CLI supports two Ethereum account families:

* `eoaK1`: regular BIP-39/BIP-32 Ethereum EOA account, signing with k1.
* `sphincsHybrid`: ERC-4337 smart account whose `_validateSignature`
  gates every UserOp on BOTH a stored ECDSA owner AND a stateless
  SPHINCS- post-quantum verifier. The ECDSA half lives in one of the
  wallet's existing eoaK1 accounts (or a freshly derived sub-path of
  the wallet's BIP-39 seed); the SPHINCS half is generated locally by
  the shim sidecar at one of the supported parameter sets (see
  `LeanCli.Sphincs.ParamSet`).

Both are local-only. Mainnet is the production default, and Sepolia
is an explicit dev/testnet target. No account kind implies remote
custody or online keystore access.
-/

namespace LeanCli.Wallet.Account

open LeanCli.Ethereum.Chain

inductive AccountKind where
  | eoaK1
  /-- Hybrid ECDSA + SPHINCS- ERC-4337 smart account. The ECDSA half is
      one of the wallet's eoaK1 accounts (existing or derived for this
      hybrid); the SPHINCS- half is generated locally by the shim and
      keyed by `(pkSeed, pkRoot)`. The deployed verifier address is
      selected per `(chain, paramSet)` via `cfg.sphincsVerifiers`. -/
  | sphincsHybrid
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

/-- How the ECDSA half of a `sphincsHybrid` account is sourced. -/
inductive EcdsaAttachment where
  /-- Reuse an existing eoaK1 account from `walletName`. `accountIndex`
      indexes into the wallet's `Record.accounts` array (the same
      indexing used by `eoa.account.list` / `eoa.account.add`). The
      hybrid's `owner` is set to that account's recovered address. -/
  | existing (walletName : String) (accountIndex : Nat)
  /-- Derive a fresh BIP-44 sub-path under `walletName` specifically for
      this hybrid account. The path is recorded so the daemon can
      reconstruct the ECDSA private key from the wallet's sealed
      mnemonic on every sign. -/
  | derived  (walletName : String) (path : DerivationPath)
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
  -- Why: hybrid accounts derive every secret (ECDSA + SPHINCS- seed) from
  -- the wallet's BIP-39 mnemonic at distinct paths so a single mnemonic
  -- backup recovers both halves.
  | .sphincsHybrid, .bip39Mnemonic => true
  | _, _ => false

def accepted (p : AccountPolicy) : Bool :=
  p.localOnly &&
    supportedChainId p.chainId &&
    compatible p.kind p.source &&
    match p.kind, p.path with
    | .eoaK1, some path => path.coinType = 60
    -- Hybrid carries an optional derivation path: present when the ECDSA
    -- half is freshly derived for this hybrid; absent when it reuses an
    -- existing eoaK1 (the path then lives on the referenced account).
    | .sphincsHybrid, some path => path.coinType = 60
    | .sphincsHybrid, none => true
    | _, _ => false

def defaultEoaK1 : AccountPolicy :=
  { kind := .eoaK1,
    source := .bip39Mnemonic,
    chainId := mainnetChainId,
    path := some defaultEthereumPath,
    localOnly := true }

def sepoliaEoaK1 : AccountPolicy :=
  { defaultEoaK1 with chainId := sepoliaChainId }

/-- Default policy shape for a Sepolia SPHINCS- hybrid account whose
    ECDSA half reuses an existing eoaK1 account (so no derivation path
    is recorded here). The concrete `(paramSet, EcdsaAttachment)` pair
    lives on the per-account record in
    `LeanCli.Wallet.SphincsHybridStore`. -/
def sepoliaSphincsHybrid : AccountPolicy :=
  { kind := .sphincsHybrid,
    source := .bip39Mnemonic,
    chainId := sepoliaChainId,
    path := none,
    localOnly := true }

end LeanCli.Wallet.Account
