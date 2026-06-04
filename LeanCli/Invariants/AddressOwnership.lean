import LeanCli.Ethereum.Ownership

/-!
# Invariant 4.1 — address-ownership resolver

Proves the structural safety property that backs the TUI's
"✓ locally re-derived" badge on transaction proposals:

* `checkOwned_verified_imp` — the per-wallet check helper can only
  emit `.verified path` when the BIP-44 derivation of the unlocked
  seed at `path` structurally equals the resolved address.

* `resolve_verified_witnesses_derivation` — by extension, any
  `.verified path` witness emitted by the top-level resolver
  necessarily witnesses *some* `deriveAddress seed path = address`.

The BIP-44 crypto primitive (`deriveAddress`) is treated as an
axiomatized FFI boundary, in the same tier as the other 🔒 entries in
`INVARIANTS.md`. What we prove here is purely structural: the resolver
code path cannot synthesize a `.verified` constructor without taking
the branch that explicitly compares the FFI output. A malicious
sidecar, a tampered on-disk record, or a stale wallet entry therefore
cannot upgrade itself to a green-badge status.

The daemon-side IO function in `Daemon.Server#chat.draft#resolveLocal`
is a refinement of `resolve` here: same case analysis, with the
`deriveAddress` call lifted into IO. Refinement-preservation gives us
the daemon-level invariant.
-/

namespace LeanCli.Invariants.AddressOwnership

open LeanCli.Ethereum.Ownership

/-- 🔒 FFI: BIP-44 Ethereum address derived from a seed at a path.
    Implemented by `LeanCli.Wallet.HDKey` (HMAC-SHA512 / secp256k1)
    + `LeanCli.Wallet.Address` (Keccak-256 / EIP-55). Axiomatized
    here because the invariant we want is *about the resolver*, not
    the crypto primitive. -/
axiom deriveAddress : ByteArray → String → String

/-- Daemon view of an EOA record on disk. Mirrors
    `LeanCli.Wallet.EoaStore.Record` projected to the fields the
    resolver uses. -/
structure WalletRecord where
  name           : String
  address        : String
  derivationPath : String

/-- In-memory unlocked-wallet slot. Mirrors
    `LeanCli.Daemon.State.UnlockedSlot`. -/
structure UnlockedWallet where
  name           : String
  seed           : ByteArray
  derivationPath : String

/-- The address `u` derives at its recorded path. -/
def UnlockedWallet.derivedAddress (u : UnlockedWallet) : String :=
  deriveAddress u.seed u.derivationPath

/-- Single-wallet ownership check. The **only** branch that can emit
    a `.verified` status is the one guarded by structural equality of
    the re-derived address and the resolver's input address. -/
def checkOwned (u : UnlockedWallet) (key address : String) : Witness :=
  if u.derivedAddress = address then
    { key := key, address := address, status := .verified u.derivationPath }
  else
    { key := key, address := address, status := .mismatch u.derivedAddress }

/-- Pure abstract resolver. The daemon's IO function is a refinement;
    same case structure, `deriveAddress` lifted into IO. -/
def resolve
    (key address : String)
    (records : List WalletRecord)
    (unlocked : List UnlockedWallet)
    (book : List (String × String))
    : Witness :=
  match records.find? (fun r => r.address = address) with
  | some r =>
      match unlocked.find? (fun u => u.name = r.name) with
      | some u => checkOwned u key address
      | none   => { key := key, address := address, status := .locked }
  | none =>
      match book.find? (fun e => e.snd = address) with
      | some _ => { key := key, address := address, status := .book }
      | none   => { key := key, address := address, status := .external }

/-- **Helper**: `checkOwned` emits `.verified path` only when the FFI
    derivation actually matched the resolved address — and the path
    is exactly the wallet's recorded derivation path. -/
theorem checkOwned_verified_imp
    (u : UnlockedWallet) (key address path : String)
    (h : (checkOwned u key address).status = .verified path) :
    deriveAddress u.seed path = address ∧ u.derivationPath = path := by
  unfold checkOwned at h
  by_cases hd : u.derivedAddress = address
  · -- The if-condition holds; checkOwned took the .verified branch.
    rw [if_pos hd] at h
    -- h : Status.verified u.derivationPath = Status.verified path
    -- (after projecting .status through the structure literal).
    injection h with hpath
    refine ⟨?_, hpath⟩
    -- Rewrite the goal back through the path equality, then use hd.
    subst hpath
    -- Goal: deriveAddress u.seed u.derivationPath = address
    -- which is exactly UnlockedWallet.derivedAddress unfolded.
    exact hd
  · -- if-condition fails; checkOwned took the .mismatch branch.
    rw [if_neg hd] at h
    -- h : Status.mismatch u.derivedAddress = Status.verified path,
    -- impossible by constructor distinction.
    exact Status.noConfusion h

/-- **Main invariant (4.1)**: any `.verified path` witness produced
    by `resolve` is backed by an actual FFI derivation that maps
    *some* seed to the resolved address at the claimed path.

    Practical reading: the TUI badge "✓ locally re-derived
    (m/44'/60'/0'/0/0)" rendered for a regex-resolved field is not
    forgeable from on-disk data alone — only an unlocked seed whose
    derivation matches can produce one. -/
theorem resolve_verified_witnesses_derivation
    (key address : String)
    (records : List WalletRecord)
    (unlocked : List UnlockedWallet)
    (book : List (String × String))
    (path : String)
    (h : (resolve key address records unlocked book).status = .verified path) :
    ∃ (seed : ByteArray), deriveAddress seed path = address := by
  unfold resolve at h
  split at h
  · -- records.find? = some _
    split at h
    · -- unlocked.find? = some u  ⇒  status came from checkOwned u …
      rename_i u _
      have ⟨hderive, _⟩ := checkOwned_verified_imp u key address path h
      exact ⟨u.seed, hderive⟩
    · -- unlocked.find? = none  ⇒  status = .locked, distinct from .verified.
      exact Status.noConfusion h
  · -- records.find? = none
    split at h
    · -- book hit  ⇒  status = .book.
      exact Status.noConfusion h
    · -- nothing  ⇒  status = .external.
      exact Status.noConfusion h

end LeanCli.Invariants.AddressOwnership
