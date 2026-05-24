# bold-liquity — security

## Pre-sign checklist (every Trove call)

1. Resolve the branch's `BorrowerOperations`, `TroveManager`, and
   `PriceFeed` addresses from `contracts.json`. There is one branch
   per collateral type — the wallet must know which branch the
   `_troveId` belongs to.
2. For `openTrove` / `adjustTrove` / `withdrawColl` / `withdrawBold`:
   read `PriceFeed.fetchPrice()`, compute the **post-action ICR**,
   and refuse if it would drop below `1.10 × MCR`.
3. The `_maxUpfrontFee` field on `openTrove`/`withdrawBold`/`adjustTrove`
   caps the borrowing fee at submission time. Refuse if the user
   leaves it at `type(uint256).max` (defenseless against a fee spike).
4. The `_annualInterestRate` chosen at `openTrove`:
   * `< 1%` (1e16) is below the protocol's minimum and reverts.
   * `> 350%` is the protocol's maximum.
   * Lower rates pay less interest but face redemption earlier.
   Surface the choice and its consequences.
5. The sorted-list hints `_upperHint` / `_lowerHint`: a wrong hint
   makes the call O(n) in the number of Troves. Always use
   `HintHelpers.getApproxHint` → `SortedTroves.findInsertPosition`
   to derive them.
6. For `adjustTroveInterestRate`: if `< 7 days` since last
   adjustment, the protocol charges an upfront fee. Surface the
   fee timing before signing.

## Refusal triggers

* Post-action ICR < `1.10 × MCR`.
* `_maxUpfrontFee = type(uint256).max`.
* `_annualInterestRate < 1e16` (< 1%) or `> 350 * 1e16` (> 350%).
* `redeemCollateral` from a non-arb flow.
* `liquidate*` functions from a retail flow.
* `setAddManager` / `setRemoveManager` to an address the user has
  not explicitly named.

## Redemption and "debt in front"

Liquity V2's redemption mechanism is intentionally adversarial: the
lowest-rate Troves get redeemed against first. A borrower picking
"the lowest interest rate" actually picks the highest-risk-of-being-
redeemed position. The wallet should surface, when proposing
`openTrove`:

* The chosen rate.
* The total BOLD debt currently "in front" (i.e. carrying a higher
  rate) — read via `DebtInFrontHelper`.
* The implication: "if total BOLD-in-front is X and BOLD-price drops,
  your Trove will be redeemed once X BOLD has been redeemed".

## Stability Pool deposits

SP deposits absorb liquidation losses pro-rata. The wallet should
surface the current branch's outstanding SP deposits and the worst-
case loss (size of the riskiest Trove that could be liquidated against
the SP) before proposing `provideToSP`.

## Oracle dependency

Each branch has a `PriceFeed` that wraps Chainlink (with a fallback
mechanism for LST exchange-rate freshness). A stale oracle marks the
entire branch as "in shutdown mode" — `openTrove` and similar are
disabled. The wallet should read `PriceFeed.lastGoodPrice()` and
surface any deviation from the live oracle.

## Per-Trove role management

`setAddManager` / `setRemoveManager` lets the Trove owner grant a
third party the right to (respectively) add collateral / repay
debt vs withdraw collateral / mint BOLD. Setting a remove-manager
is effectively delegating wallet-control over the Trove. Refuse
unless the user has explicitly named the manager.

## Citations

* <https://github.com/liquity/bold/blob/main/README.md>
* <https://github.com/liquity/bold/tree/main/whitepaper>
