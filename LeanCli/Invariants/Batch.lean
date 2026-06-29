import LeanCli.Invariants.Wallet

/-!
# Atomic batched sends (ERC-4337 `executeBatch`)

The abstract model of an ERC-4337 `executeBatch` UserOperation: a list of
sends (`legs`) executed left-to-right under a SINGLE UserOperation. Either
every leg applies and the userOp succeeds, or the userOp reverts and NO
leg's effect is persisted — the on-chain `executeBatch` is atomic.

`applyBatch` folds the verified single-send `apply`
(`LeanCli.Invariants.Wallet`) over the legs in the `Option` monad, so the
short-circuit on the first unaffordable leg *is* the atomicity.

## Properties proved here

* `applyBatch_atomic` — a successful batch decomposes into successful
  prefixes: a batch never persists the effect of only some of its legs.
* `applyBatch_head_affordable` — the batch analogue of
  `apply_some_affordable`: no leg is ever debited via silent `Nat.sub`
  clamping. With `applyBatch_atomic` this lifts to every leg.
* `applyBatch_uninvolved` — conservation: an account that is neither
  sender nor recipient in ANY leg keeps its balance across the batch.

## Nonce atomicity

A batch is a *single* UserOperation, so it consumes exactly one nonce
regardless of leg count — this is already proved at the operational layer
by Category 12 (`applySomeIncrementsNonce` / `applySomeConsumesCurrentNonce`
in `LeanCli/Invariants/SphincsAccount.lean`). Batching N actions therefore
neither consumes N nonces nor lets an individual leg be replayed alone.
-/

namespace LeanCli.Invariants.Batch

open LeanCli.Invariants.Wallet

/-- Apply a list of sends as ONE atomic batch: fold `apply`
left-to-right in the `Option` monad. The result is `none` the moment any
leg is unaffordable, and the partial state from earlier legs is discarded
(never persisted) — the abstract model of an `executeBatch` UserOp that
either fully succeeds or reverts. -/
def applyBatch (σ : State) : List Send → Option State
  | []      => some σ
  | s :: ss => (apply σ s).bind (fun σ' => applyBatch σ' ss)

@[simp] theorem applyBatch_nil (σ : State) : applyBatch σ [] = some σ := rfl

@[simp] theorem applyBatch_cons (σ : State) (s : Send) (ss : List Send) :
    applyBatch σ (s :: ss) = (apply σ s).bind (fun σ' => applyBatch σ' ss) := rfl

/-- `applyBatch` over a concatenation is the sequential composition of the
two halves. This is the structural backbone of batch atomicity. -/
theorem applyBatch_append (σ : State) (ss₁ ss₂ : List Send) :
    applyBatch σ (ss₁ ++ ss₂)
      = (applyBatch σ ss₁).bind (fun σ' => applyBatch σ' ss₂) := by
  induction ss₁ generalizing σ with
  | nil => simp
  | cons s ss ih =>
      simp only [List.cons_append, applyBatch_cons]
      cases apply σ s with
      | none => simp
      | some σ' => exact ih σ'

/-- **Atomicity / no partial application.** If a batch succeeds, it
decomposes: every prefix succeeded and produced the input state for the
rest. In particular the batch never persists the effect of only some of
its legs — it is all-or-nothing. -/
theorem applyBatch_atomic {σ σ' : State} {ss₁ ss₂ : List Send}
    (h : applyBatch σ (ss₁ ++ ss₂) = some σ') :
    ∃ σ'', applyBatch σ ss₁ = some σ'' ∧ applyBatch σ'' ss₂ = some σ' := by
  rw [applyBatch_append] at h
  cases h₁ : applyBatch σ ss₁ with
  | none => rw [h₁] at h; simp at h
  | some σ'' => rw [h₁] at h; simp at h; exact ⟨σ'', rfl, h⟩

/-- **No silent underflow on the leading leg.** The batch analogue of
`apply_some_affordable`: a successful batch's first leg was affordable in
the starting state. Composed with `applyBatch_atomic`, every leg is
affordable at the point it is applied — no leg is ever silently clamped. -/
theorem applyBatch_head_affordable {σ σ' : State} {s : Send} {ss : List Send}
    (h : applyBatch σ (s :: ss) = some σ') : s.affordable σ := by
  rw [applyBatch_cons] at h
  cases h₁ : apply σ s with
  | none => rw [h₁] at h; simp at h
  | some σ'' => exact apply_some_affordable h₁

/-- A single send leaves account `a` untouched when `a` is neither the
sender nor any recipient. -/
theorem apply_uninvolved {σ σ' : State} {s : Send} {a : AccountId}
    (h : apply σ s = some σ') (hne : a ≠ s.sender) (hcred : s.creditedTo a = 0) :
    σ'.balance a = σ.balance a := by
  rw [apply_non_sender_balance h hne, hcred, Nat.add_zero]

/-- **Conservation for uninvolved accounts.** An account that is neither a
sender nor a recipient in ANY leg of the batch has the same balance after
the batch as before — batching moves no value to or from a bystander. -/
theorem applyBatch_uninvolved {a : AccountId} (ss : List Send) :
    ∀ {σ σ' : State},
      applyBatch σ ss = some σ' →
      (∀ s ∈ ss, a ≠ s.sender ∧ s.creditedTo a = 0) →
      σ'.balance a = σ.balance a := by
  induction ss with
  | nil =>
      intro σ σ' h _
      rw [applyBatch_nil] at h
      injection h with h; subst h; rfl
  | cons s ss ih =>
      intro σ σ' h hall
      rw [applyBatch_cons] at h
      cases h₁ : apply σ s with
      | none => rw [h₁] at h; simp at h
      | some σ'' =>
          -- `h : (some σ'').bind (…) = some σ'` is defeq to
          -- `applyBatch σ'' ss = some σ'`, so `ih h` typechecks directly.
          rw [h₁] at h
          have huninv := hall s (by simp)
          have hstep := apply_uninvolved h₁ huninv.1 huninv.2
          have htail := ih h (fun t ht => hall t (by simp [ht]))
          rw [htail, hstep]

end LeanCli.Invariants.Batch
