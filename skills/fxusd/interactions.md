# fxusd — interaction recipes

## Recipe: mint fxUSD against wstETH

Goal: deposit `amount` of wstETH; receive fxUSD.

1. Resolve the wstETH market contracts from `contracts.json`
   (`wstETH_Market`, `wstETH_Treasury`, etc.).
2. Read collateral ratio: `chain_read({to: wstETH_Treasury, data:
   encode("collateralRatio()")})`.
3. **Refuse** if `cr < stabilityThreshold` (typ. 130%) — the
   user should be told the market is in stability or worse.
4. Read `MarketV2.currentBaseTokenPrice()` to anchor expected
   slippage.
5. Allowance dance: ERC-20 `approve(wstETH → FxUSD, amount)` (or
   for `mintFToken` path, `approve(wstETH → wstETH_Market, amount)`).
6. Build `FxUSD.mint(baseToken=wstETH, amount,
   receiver=msg.sender, minOut=expected*0.99)`.
7. `tx.simulate` → `propose_send`.

## Recipe: mint xToken (levered exposure on wstETH)

Goal: deposit `amount` of wstETH; receive xToken_wstETH.

1. Read collateral ratio. **Refuse** if `cr < stabilityThreshold`
   (xToken minting is paused).
2. Allowance dance: `approve(wstETH → wstETH_Market, amount)`.
3. Build `wstETH_Market.mintXToken(amount, recipient=msg.sender,
   minXTokenOut)`.
4. `tx.simulate` → `propose_send`.
5. Surface the implicit leverage (`TVL / (TVL - fTokenSupply)`)
   and the price at which the position enters liquidation mode.

## Recipe: swap fToken ↔ xToken (change leverage)

1. Read collateral ratio.
2. Build `wstETH_Market.swapFTokenToXToken(fTokenAmount,
   recipient, minXOut)` (or the inverse).
3. `tx.simulate` → `propose_send`.

## Recipe: stake fxUSD in a Rebalance Pool

1. Allowance dance: `approve(fxUSD → FxUSD, amount)`.
2. Build `FxUSD.earn(baseToken=wstETH, amount, receiver=msg.sender)`.
3. Surface the current Rebalance Pool TVL and the worst-case
   principal loss.
4. `tx.simulate` → `propose_send`.

## Recipe: redeem fxUSD for base token

1. Allowance dance: `approve(fxUSD → FxUSD, amount)`.
2. Read the redemption fee from the market.
3. Build `FxUSD.redeem(baseToken=wstETH, amount, receiver,
   minOut=expected*(1-fee)*0.99)`.
4. `tx.simulate` → `propose_send`.

## Recipe: auto-redeem (split across markets)

Goal: burn fxUSD; protocol routes the redemption across multiple
markets.

1. Build `FxUSD.autoRedeem(amount, receiver, markets=[wstETH,
   sfrxETH, weETH])`.
2. **Surface which markets will be hit** based on each market's
   redemption fee + available collateral.
3. `tx.simulate` → `propose_send`.

## Refusal triggers

* `mintXToken` when market is in stability mode or worse.
* `minOut = 0` on any redeem.
* `mint` / `wrap` into a market in liquidation or recap mode
  without explicit user acknowledgment.
* `addBaseToken` (treasury donation — not a wallet flow).
* `liquidate` (keeper-side).

## Cross-reference

* `bridge/clearsign/registry/erc20.json` — for every allowance leg.
* No dedicated 7730 descriptor for fx Protocol yet. The wallet
  falls back to ABI-decoded view; descriptors for `wrap`,
  `mint`, `redeem`, `earn`, `autoRedeem` would be worth adding
  upstream.
