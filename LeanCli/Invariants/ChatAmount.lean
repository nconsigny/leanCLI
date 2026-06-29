import LeanCli.Agent.State
import LeanCli.LlmAgent.AmountGuard

/-!
# Chat-drafted amount integrity

When a chat request falls through to the LLM, the model is **never**
permitted to choose the numeric magnitude that ends up in calldata. The
daemon parses the human amount out of the user's message, converts it to
base units in Lean, and publishes the result as an `AmountEntry` table
on the per-turn `AgentConfig`. The model references an amount by a
`ref` handle; the amount-bearing tools resolve it via `findAmount`.

This module proves the two structural facts the security argument rests
on:

* **Input prevention** (`findAmount_mem`): a resolved handle can only
  ever name an entry the daemon itself placed in the table. The model
  cannot conjure an amount through this path — at worst it picks the
  wrong (but daemon-derived) entry, which the user still sees at
  `ConfirmGate`.

* **Output re-check soundness** (`amountInTable_iff`,
  `amountInTable_sound`): the daemon's post-hoc equality check
  (`revalidateAmounts`, which decides acceptance via `amountInTable`)
  admits a decoded magnitude **iff** it equals a Lean-derived table
  entry. There is no third outcome where a magnitude the daemon never
  produced slips through.

Together these are the prevent-at-input + verify-at-output halves of the
hybrid amount-authority design.
-/

namespace LeanCli.Agent

/-- A resolved amount handle always names an entry that is actually in
    the table, and that entry's `ref` is the one that was asked for. The
    model cannot fabricate an `AmountEntry`; `findAmount` is a pure
    lookup into the daemon-built table. -/
theorem findAmount_mem
    {table : List AmountEntry} {ref : String} {e : AmountEntry}
    (h : findAmount table ref = some e) :
    e ∈ table ∧ e.ref = ref := by
  induction table with
  | nil => simp [findAmount] at h
  | cons x xs ih =>
    simp only [findAmount, List.find?_cons] at h
    split at h
    · next hx =>
        obtain rfl := Option.some.inj h
        exact ⟨List.mem_cons.mpr (Or.inl rfl), eq_of_beq hx⟩
    · next hx =>
        obtain ⟨hmem, href⟩ := ih h
        exact ⟨List.mem_cons.mpr (Or.inr hmem), href⟩

/-- The output re-check predicate is exactly "the decoded magnitude
    equals some Lean-derived entry". This is the spec the daemon's
    `revalidateAmounts` is implemented against. -/
theorem amountInTable_iff
    {table : List AmountEntry} {decoded : Nat} :
    amountInTable table decoded = true ↔ ∃ e ∈ table, e.base = decoded := by
  simp [amountInTable, List.any_eq_true, beq_iff_eq]

/-- Soundness direction, stated on its own for downstream use: if the
    re-check admits a magnitude, that magnitude was produced by Lean
    (it equals the `base` of an entry the daemon placed in the table). -/
theorem amountInTable_sound
    {table : List AmountEntry} {decoded : Nat}
    (h : amountInTable table decoded = true) :
    ∃ e ∈ table, e.base = decoded :=
  amountInTable_iff.mp h

/-- An empty amount table admits no magnitude. This is why the daemon
    must publish a non-empty table for any amount-bearing draft: with no
    entries, `revalidateAmounts` rejects every non-trivial amount rather
    than silently waving it through. -/
theorem amountInTable_empty (decoded : Nat) :
    amountInTable [] decoded = false := by
  simp [amountInTable]

/-- Output re-check soundness (native value): if the daemon's
    `AmountGuard.revalidate` admits a draft whose native `value` is
    non-zero, that value is one of the Lean-derived `allowed` amounts —
    never a magnitude the model invented. This is the fail-closed
    guarantee on the raw `propose_send` path: the value field is always
    checkable, so an opaque draft cannot smuggle native value past it. -/
theorem revalidate_value_sound
    {value : Nat} {data : String} {allowed : List Nat}
    (h : LeanCli.LlmAgent.AmountGuard.revalidate value data allowed = .ok ())
    (hv : value ≠ 0) : value ∈ allowed := by
  have h1 : (value != 0) = true := by simpa using hv
  cases hb : allowed.contains value with
  | true  => exact List.contains_iff_mem.mp hb
  | false =>
      have hc : (value != 0 && !allowed.contains value) = true := by rw [h1, hb]; decide
      unfold LeanCli.LlmAgent.AmountGuard.revalidate at h
      rw [if_pos hc] at h
      exact absurd h (by simp)

end LeanCli.Agent
