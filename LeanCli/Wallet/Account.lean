import LeanCli.Ethereum.Chain

/-!
# Wallet account model

The CLI supports two Ethereum account families:

* `eoaK1`: regular BIP-39/BIP-32 Ethereum EOA account, signing with k1.
* `smart …`: an ERC-4337 smart (contract) account. Today the only
  subtype is `.sphincs` — a hybrid ECDSA + SPHINCS- account whose
  `_validateSignature` gates every UserOp on BOTH a stored ECDSA owner
  AND a stateless SPHINCS- post-quantum verifier. The ECDSA half lives
  in one of the wallet's existing eoaK1 accounts (or a freshly derived
  sub-path of the wallet's BIP-39 seed); the SPHINCS half is generated
  locally by the shim sidecar at one of the supported parameter sets
  (see `LeanCli.Sphincs.ParamSet`). A `.frame` subtype is reserved for
  a future smart-account kind and not yet implemented.

Smart accounts are the wallets that support atomic multi-call
(`executeBatch`) execution from a single UserOperation; see
`LeanCli.Wallet.ExecuteBatch`.

Both families are local-only. Mainnet is the production default, and
Sepolia is an explicit dev/testnet target. No account kind implies
remote custody or online keystore access.
-/

namespace LeanCli.Wallet.Account

open LeanCli.Ethereum.Chain

/-- The subtype of a smart (ERC-4337 contract) account. Modeled as its
    own inductive so the account kind reads as "smart account, sphincs
    subtype" and so a future `frame` kind is an additive change here
    rather than a new flat sibling of `eoaK1`. -/
inductive SmartAccountKind where
  /-- Hybrid ECDSA + SPHINCS- account. The ECDSA half is one of the
      wallet's eoaK1 accounts (existing or derived for this hybrid);
      the SPHINCS- half is generated locally by the shim and keyed by
      `(pkSeed, pkRoot)`. The deployed verifier address is selected per
      `(chain, paramSet)` via `cfg.sphincsVerifiers`. -/
  | sphincs
  -- | frame   -- reserved for a future smart-account kind; not yet implemented
  deriving DecidableEq, Repr

inductive AccountKind where
  | eoaK1
  /-- An ERC-4337 smart (contract) account; `k` selects the subtype. -/
  | smart (k : SmartAccountKind)
  deriving DecidableEq, Repr

/-- Whether this account is a smart (ERC-4337 contract) account — the
    accounts that support batched `executeBatch` execution. -/
def AccountKind.isSmart : AccountKind → Bool
  | .smart _ => true
  | .eoaK1   => false

/-- The smart-account subtype, if this is a smart account. -/
def AccountKind.smartKind? : AccountKind → Option SmartAccountKind
  | .smart k => some k
  | .eoaK1   => none

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
  | .smart .sphincs, .bip39Mnemonic => true
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
    | .smart .sphincs, some path => path.coinType = 60
    | .smart .sphincs, none => true
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
  { kind := .smart .sphincs,
    source := .bip39Mnemonic,
    chainId := sepoliaChainId,
    path := none,
    localOnly := true }

end LeanCli.Wallet.Account
