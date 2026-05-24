# aave — interaction recipes

## Recipe: supply ERC-20 collateral

Goal: deposit `amount` of `asset` and use it as collateral. Mainnet
chainId 1, Sepolia chainId 11155111.

1. Resolve live Pool:
   `chain_read({to: PoolAddressesProvider, data: encode("getPool()")})`
   → `pool`.
2. Read allowance:
   `chain_read({to: asset, data: encode("allowance(address,address)", owner, pool)})`.
3. If allowance < amount, emit an `approve(pool, amount)` first.
   Prefer exact amount over unlimited (`bridge/clearsign/registry/erc20.json`).
4. Build `Pool.supply(asset, amount, onBehalfOf=msg.sender,
   referralCode=0)`.
5. `tx.simulate({chainId, from, to: pool, data})`.
6. `propose_send({chainId, to: pool, value: 0, data})`.
7. Post-tx: re-read `getUserAccountData(user)` to confirm
   `totalCollateralBase` grew by the supplied USD-equivalent.

## Recipe: borrow against existing collateral

Goal: borrow `amount` of `asset` with health-factor guard.

1. Resolve live Pool (as above).
2. **Pre-borrow guard**: read `getUserAccountData(user)` →
   `(totalCollateral, totalDebt, availableBorrows, …, healthFactor)`.
3. Read `getAssetPrice(asset)` to convert `amount` to base-currency.
4. Compute `post_debt = totalDebt + amount_in_base` and
   `post_hf = (totalCollateral * liquidationThreshold) / post_debt`.
5. **Refuse if `post_hf < 1.05`.** Surface both pre- and post-hf to
   the user.
6. Build `Pool.borrow(asset, amount, interestRateMode=2,
   referralCode=0, onBehalfOf=msg.sender)`.
7. `tx.simulate` → `propose_send`.

## Recipe: repay debt

Goal: repay `amount` of `asset` debt (or `type(uint256).max` for
full repay).

1. Resolve live Pool.
2. Read allowance for `asset` to `pool`. If insufficient, emit
   `approve` first.
3. Build `Pool.repay(asset, amount, interestRateMode=2, onBehalfOf=msg.sender)`.
4. `tx.simulate` → `propose_send`.

Variants:

* `Pool.repayWithATokens(asset, amount, 2)` — burns the caller's
  aTokens instead of pulling underlying. No allowance needed.
* `Pool.repayWithPermit(asset, amount, 2, onBehalfOf, deadline, v, r, s)`
  — one-shot ERC-2612 signature; the wallet decodes the typed-data
  before signing.

## Recipe: withdraw collateral

Goal: redeem `amount` of `asset` (or `type(uint256).max` for full).

1. Resolve live Pool.
2. **Pre-withdraw guard**: compute post-hf as in `borrow`.
3. **Refuse if `post_hf < 1.05`.**
4. Build `Pool.withdraw(asset, amount, to=msg.sender)`.
5. `tx.simulate` → `propose_send`.

## Recipe: toggle eMode

1. Read current category: `chain_read("getUserEMode(address)")`.
2. Build `Pool.setUserEMode(category)`.
3. Surface the new category's `ltv` / `liquidationThreshold` /
   `priceSource` from `getEModeCategoryData(category)`.
4. `tx.simulate` → `propose_send`.

## Refusal triggers

* Post-action health factor below 1.05.
* `interestRateMode != 2` on borrow / repay.
* `liquidationCall`, `flashLoan`, `flashLoanSimple` from a retail
  flow.
* Asset is in isolation mode + the user is trying to borrow a
  different asset.

## Cross-reference

* `bridge/clearsign/registry/erc20.json` — the `approve` leg before
  every supply / repay.
* No dedicated 7730 descriptor for Pool yet. The wallet falls
  back to ABI-decoded view; that descriptor would be worth adding
  upstream.
