# fxusd — security

## Pre-sign checklist (every mint / redeem)

1. Resolve the market by `baseToken`: read `FxUSD.getMarkets()` or
   look up the per-collateral Market contract directly from
   `contracts.json`.
2. Read the current **collateral ratio** via
   `MarketV2.collateralRatio()` or `TreasuryV2.collateralRatio()`.
3. Determine the market's current **mode**:
   * `cr >= stabilityThreshold` (typ. 130%): normal — all
     operations allowed.
   * `liquidationThreshold <= cr < stabilityThreshold`: **stability
     mode** — `mintXToken` is paused; minting fToken is still
     allowed.
   * `recapThreshold <= cr < liquidationThreshold`: **liquidation
     mode** — Rebalance Pool depositors lose principal first.
   * `cr < recapThreshold`: **recap mode** — fToken supply is
     burned to restore solvency.
4. Surface the mode and the post-action CR to the user.
5. For any `redeem` / `unwrap` path: read the market's
   `fTokenRedemptionFeeRatio` / `xTokenRedemptionFeeRatio` and
   show the user the fee before signing.
6. For `earn` (Rebalance Pool deposit): surface the worst-case
   principal loss (= total xToken supply that could be liquidated
   against the pool).

## Refusal triggers

* `mintXToken` while the market is in stability mode or worse.
* Any mint / wrap while the market is in liquidation or recap mode
  unless the user has explicitly acknowledged the mode.
* `addBaseToken` from a user flow (this is a donation /
  recapitalization gesture, not a wallet user surface).
* `liquidate` from a retail flow (keeper-side).
* `minOut = 0` or `minOut < expected * 0.95` on any redeem path —
  the wallet must enforce a slippage floor.

## Oracle dependence

Each market has its own `priceOracle` (read via
`MarketV2.priceOracle()`). A stale price reverts most
state-changing calls. The wallet should:

* Read `currentBaseTokenPrice()` from the market.
* Cross-check against an independent source (Chainlink for the
  underlying LST, the LST's own `exchange-rate-provider` for the
  ETH-LST rate).
* Refuse if the deviation is > 1%.

## Approval surface

* `mintFToken` / `mintXToken` / `addBaseToken` require ERC-20
  allowance for the underlying base token (wstETH / sfrxETH / etc.)
  to the **Market** contract.
* `FxUSD.wrap` / `FxUSD.mint` require allowance for the fToken or
  base token to the **FxUSD** contract.
* `FxUSD.redeem` / `FxUSD.autoRedeem` require allowance for fxUSD
  to the **FxUSD** contract.
* Prefer exact-amount allowance over unlimited.

## Governance and upgrade risk

* The `FxUSD` contract is a proxy; the implementation
  `0x6C338c0bFB67970231109d4b33047A6e6BC685e5` can be replaced by
  Aladdin DAO governance. Surface this fact when the user is
  considering a large position.
* Each market's `mintCap` and fees are governed parameters; a
  governance vote can change them mid-flight. The wallet should
  re-read these on each pre-sign rather than caching.

## Citations

* <https://docs.aladdin.club/fx-protocol/>
* <https://github.com/AladdinDAO/aladdin-v3-contracts/tree/main/whitepapers>
