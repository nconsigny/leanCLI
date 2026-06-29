# aave — security

## Pre-sign checklist (every Pool call)

1. Resolve the live Pool address via
   `PoolAddressesProvider.getPool()` rather than the cached one.
   The provider is the only address that needs to be hard-coded.
2. For `borrow`, `withdraw`, and any toggle of
   `setUserUseReserveAsCollateral`: read
   `getUserAccountData(user)`, compute the **post-action health
   factor**, and surface it. Refuse if `post_hf < 1.05`.
3. For `supply`/`repay`: verify that the necessary allowance for
   the `Pool` exists (or, if using the `*WithPermit` variant, that
   the permit signature decodes correctly per ERC-2612 and is for
   the right spender). Prefer exact-amount allowance.
   Exception: native ETH supply from a SPHINCS/smart account is prepared
   as one daemon-built batch: `WETH.deposit{value}` + optional
   `WETH.approve(Pool, max)` + `Pool.supply(WETH, amount, onBehalfOf, 0)`.
   The batch must target the smart account itself and carry total
   `value = amount`.
   On Sepolia, resolve WETH through the Aave prepare tool, not the
   generic token registry: Aave's WETH reserve is
   `0xc558dbdd856501fcd9aaf1e62eae57a9f0629a3c`. Supplying generic
   Sepolia WETH `0xfff9976782d46cc05630d1f6ebab18b2324d6b14` reverts
   because `Pool.getReserveData(asset)` has a zero aToken address.
4. For `borrow(interestRateMode = ?)`: refuse any value other than
   `2` (variable). The V3 stable-rate mode is killed and the call
   will revert; the wallet should surface the killed-mode message
   rather than propagate the chain revert.
5. For asset in **isolation mode**: refuse `borrow` of any other
   asset while collateral remains in the isolated reserve.
6. For asset toggled **into eMode**: read
   `getUserEMode(user)` and surface the new category before
   proposing `setUserEMode(category)`.
7. The `referralCode` parameter is unused since V3 launch; the
   wallet should always pass `0`.

## Refusal triggers

* `liquidationCall` from a retail flow. Liquidations are keeper
  surfaces; refuse unless the user has explicitly opted into the
  "I'm a liquidator" flow.
* `flashLoan` / `flashLoanSimple` from a retail flow. Refuse — the
  caller must implement `IFlashLoanReceiver.executeOperation` and
  the wallet has no way to validate that contract.
* Post-action `health factor < 1.05`.
* `interestRateMode != 2`.
* Any admin function (`setConfiguration`, `dropReserve`,
  `setPoolImpl`, etc.). The `PoolAddressesProvider.getACLAdmin()`
  is governance; user EOAs cannot succeed here.

## Oracle dependency

Aave V3 prices every asset against the protocol's price oracle
(`PoolAddressesProvider.getPriceOracle()`). Oracle staleness or
manipulation directly affects the health factor. The wallet does
not currently re-validate the oracle's underlying Chainlink feeds —
that is an upstream-trust assumption.

## Approval surface

* `supply` / `repay` need ERC-20 allowance for the **Pool**, not
  the aToken. The aToken is the receipt; you don't approve it.
* `asset="ETH"` in `prepare_aave_supply` is only the smart-account
  native-ETH wrapper path. `asset="WETH"` means the account already
  has WETH and the daemon should prepare the ordinary ERC-20 supply.
* `repayWithATokens` skips the ERC-20 allowance dance entirely.
* `*WithPermit` variants accept a one-shot ERC-2612 signature
  in-place; the wallet must decode the permit (typed-data) and
  show it to the user before signing.

## Citations

* <https://aave.com/docs/developers/smart-contracts/pool>
* <https://aave.com/docs/developers/smart-contracts/pool-addresses-provider>
* <https://aave.com/docs/concepts/protocol/health-factor>
