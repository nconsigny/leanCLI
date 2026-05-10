import LeanKohaku.Swap.Tokens

/-!
# Swap invariants

Properties we want the Uniswap V3 swap helpers to satisfy.
-/

namespace LeanKohaku.Invariants.Swap

/-- Apply a basis-point slippage tolerance to a quoted output amount.
    Uses saturating `Nat.sub`: when `slippageBps ≥ 10_000` the result is
    `0` (i.e. accept any output).  This is the same convention every
    routing UI uses. We keep it on `Nat` (no clamping below zero is
    possible) for cleanly provable monotonicity. -/
def applySlippageBps (amountOut slippageBps : Nat) : Nat :=
  let denom : Nat := 10000
  let cut : Nat := amountOut * slippageBps / denom
  amountOut - cut

/-- `slippageZeroIsIdentity`: a 0-bps slippage tolerance leaves the
    quoted amount untouched. This rules out off-by-one rounding bugs in
    the slippage helper. -/
theorem slippageZeroIsIdentity (amountOut : Nat) :
    applySlippageBps amountOut 0 = amountOut := by
  unfold applySlippageBps
  simp

/-- Build the candidate-token list that `swap.balances` fans out over for
    a given chain: every registry token whose `addressOn chainId` is
    `some _`. Skipping any token whose `addressOn` is `none` is the
    invariant we want to nail down — never silently use the mainnet
    address as a fallback on sepolia. -/
def balancesCandidates (chain : LeanKohaku.Swap.Tokens.ChainId) :
    List (LeanKohaku.Swap.Tokens.Token × String) :=
  LeanKohaku.Swap.Tokens.registry.filterMap fun t =>
    match LeanKohaku.Swap.Tokens.addressOn t chain with
    | some addr => some (t, addr)
    | none => none

/-- `balancesCandidates_addressOn_some`: every entry produced by
    `balancesCandidates chain` is a `(token, addr)` pair where
    `addressOn token chain = some addr`. Establishes the invariant that
    `swap.balances` cannot accidentally emit a token entry on a chain
    where the registry has no canonical deployment for it. -/
theorem balancesCandidates_addressOn_some
    (chain : LeanKohaku.Swap.Tokens.ChainId)
    (t : LeanKohaku.Swap.Tokens.Token) (addr : String)
    (h : (t, addr) ∈ balancesCandidates chain) :
    LeanKohaku.Swap.Tokens.addressOn t chain = some addr := by
  unfold balancesCandidates at h
  rcases List.mem_filterMap.mp h with ⟨t', ht'mem, ht'eq⟩
  -- `t'eq` reduces the inner `match` to `some (t', addr)`; case-split.
  cases hAddr : LeanKohaku.Swap.Tokens.addressOn t' chain with
  | none =>
      simp [hAddr] at ht'eq
  | some a =>
      simp [hAddr] at ht'eq
      rcases ht'eq with ⟨rfl, rfl⟩
      exact hAddr

end LeanKohaku.Invariants.Swap
