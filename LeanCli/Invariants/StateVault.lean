import LeanCli.Daemon.StateVault
import LeanCli.Encoding.Json

/-!
# Invariants — Category 16: StateVault provenance

The StateVault (`LeanCli.Daemon.StateVault`) is the wallet's partial
state node: persistent chain state tagged with the trust tier of the
read that produced it. These proofs pin down the provenance algebra the
operational code uses at every write site:

* **16.1 Provenance classification is honest.** A direct read (`via? =
  none`) can only ever be recorded as `rpcUnverified`; a light-client
  read as `consensusVerified` (`tierOfVia`). A Lean-verified MPT pin
  never upgrades an unverified root: `pinTier rpcUnverified =
  rpcUnverified` — you cannot manufacture `leanProven` state out of an
  untrusted header.

* **16.2 No-downgrade replacement.** `shouldReplace stored incoming`
  holds exactly when `incoming` is at least as trusted as `stored`, so
  re-reading an immutable fact over direct RPC can never silently
  overwrite its consensus-verified record. Parsing is fail-safe
  downward: only the exact tags `"consensus"` / `"lean"` read back as
  elevated tiers — a corrupt or unknown tag degrades to `rpcUnverified`.

* **16.3 Staleness honesty is structural.** Every rendered mutable entry
  (`AccountEntry` / `StorageEntry` / `HeaderEntry`) carries its proven
  block number and tier in the JSON the daemon serves — there is no
  constructor and no serializer without them.

Signing independence (the third leg of the Cat 16 trust contract) is an
import-graph property, stated in INVARIANTS.md the same way as 5.3: no
signing module imports `Daemon.StateVault`, and the pre-sign pipeline
(`tx.decodeIntent → tx.simulate → ConfirmGate`) reads fresh verified
state, never the vault. MPT verifier soundness is stated as 📝 16.4 in
INVARIANTS.md (acceptance ⇒ key/value bound to the root, under keccak
collision resistance via the Cat-13 axiomatized boundary).
-/

namespace LeanCli.Invariants.StateVault

open LeanCli.Daemon.StateVault
open LeanCli.Encoding.Json

/-! ## 16.1 Provenance classification -/

/-- A direct (no light client) read is classified unverified — always. -/
theorem tierOfVia_none_unverified {α : Type} :
    tierOfVia (α := α) none = Tier.rpcUnverified := rfl

/-- A light-client-served read is classified consensus-verified. -/
theorem tierOfVia_some_consensus {α : Type} (v : α) :
    tierOfVia (some v) = Tier.consensusVerified := rfl

/-- `tierOfVia` never emits `leanProven`: that tier is reserved for the
    MPT pin path — no plain network read can claim it. -/
theorem tierOfVia_never_leanProven {α : Type} (o : Option α) :
    tierOfVia o ≠ Tier.leanProven := by
  cases o <;> simp [tierOfVia]

/-- A Lean-verified proof against an UNVERIFIED root stays unverified:
    internal consistency is not trust. -/
theorem pinTier_unverified_root :
    pinTier Tier.rpcUnverified = Tier.rpcUnverified := rfl

/-- A Lean-verified proof against a consensus-verified root earns the
    top tier. -/
theorem pinTier_verified_root :
    pinTier Tier.consensusVerified = Tier.leanProven := rfl

/-- `pinTier` is monotone: it never ranks a less-trusted root above a
    more-trusted one. -/
theorem pinTier_monotone : ∀ a b : Tier,
    a.le b = true → (pinTier a).le (pinTier b) = true := by
  intro a b
  cases a <;> cases b <;> decide

/-! ## Trust order -/

theorem tier_le_refl : ∀ t : Tier, t.le t = true := by
  intro t
  cases t <;> decide

theorem tier_le_trans : ∀ a b c : Tier,
    a.le b = true → b.le c = true → a.le c = true := by
  intro a b c
  cases a <;> cases b <;> cases c <;> decide

theorem tier_le_antisymm : ∀ a b : Tier,
    a.le b = true → b.le a = true → a = b := by
  intro a b
  cases a <;> cases b <;> decide

theorem tier_le_total : ∀ a b : Tier,
    a.le b = true ∨ b.le a = true := by
  intro a b
  cases a <;> cases b <;> decide

/-! ## 16.2 No-downgrade replacement -/

/-- Replacement happens exactly when the incoming observation is at
    least as trusted as the stored one. -/
theorem shouldReplace_iff_le : ∀ stored incoming : Tier,
    shouldReplace stored incoming = true ↔ stored.le incoming = true := by
  intro stored incoming
  cases stored <;> cases incoming <;> decide

/-- Concretely: nothing ever overwrites `leanProven` except `leanProven`. -/
theorem leanProven_only_replaced_by_leanProven : ∀ incoming : Tier,
    shouldReplace Tier.leanProven incoming = true → incoming = Tier.leanProven := by
  intro incoming
  cases incoming <;> decide

/-- Tag round-trip: a tier survives serialize → parse. -/
theorem tier_tag_roundtrip : ∀ t : Tier, Tier.ofString t.asString = t := by
  intro t
  cases t <;> rfl

/-- Fail-safe parse: reading back `consensusVerified` requires the exact
    `"consensus"` tag — no other byte string parses to it. -/
theorem ofString_consensus_only (s : String) :
    Tier.ofString s = Tier.consensusVerified → s = "consensus" := by
  unfold Tier.ofString
  split <;> simp_all

/-- Fail-safe parse: reading back `leanProven` requires the exact
    `"lean"` tag. -/
theorem ofString_leanProven_only (s : String) :
    Tier.ofString s = Tier.leanProven → s = "lean" := by
  unfold Tier.ofString
  split <;> simp_all

/-! ## 16.3 Staleness honesty (structural) -/

/-- Every served account entry carries the exact block it was proven
    at. There is no "current balance" render path. -/
theorem accountEntry_json_has_block (e : AccountEntry) :
    getField "block" e.toJson = some (Json.num (Int.ofNat e.blockNumber)) := rfl

/-- Every served account entry carries its provenance tier. -/
theorem accountEntry_json_has_tier (e : AccountEntry) :
    getField "tier" e.toJson = some (Json.str e.tier.asString) := rfl

/-- Every served storage entry carries its proven block. -/
theorem storageEntry_json_has_block (e : StorageEntry) :
    getField "block" e.toJson = some (Json.num (Int.ofNat e.blockNumber)) := rfl

/-- Every served storage entry carries its provenance tier. -/
theorem storageEntry_json_has_tier (e : StorageEntry) :
    getField "tier" e.toJson = some (Json.str e.tier.asString) := rfl

/-- Every served header pin carries its block number and tier. -/
theorem headerEntry_json_has_block (e : HeaderEntry) :
    getField "block" e.toJson = some (Json.num (Int.ofNat e.blockNumber)) := rfl

theorem headerEntry_json_has_tier (e : HeaderEntry) :
    getField "tier" e.toJson = some (Json.str e.tier.asString) := rfl

end LeanCli.Invariants.StateVault
