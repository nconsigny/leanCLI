# aave — interaction recipes

## Agent rule: use typed prepare tools

Do not walk Aave manually with `protocol_lookup`, ad hoc `chain_read`,
or hand-encoded calldata. For the retail verbs below, call the matching
typed tool once:

* `prepare_aave_supply`
* `prepare_aave_withdraw`
* `prepare_aave_borrow`
* `prepare_aave_repay`
* `prepare_aave_set_collateral`

If the regex seed already includes `amountBase`, pass that exact decimal
string as the tool's `amount`; do not recompute it.

If the prompt contains multiple Aave legs, such as `withdraw 1.5 AAVE
from Aave and borrow 100 DAI`, do not emit a single-leg draft. The
acceptable outcomes are:

* one explicit smart-account batch proposal containing all requested legs,
  decoded as `executeBatch`, or
* a clarification asking the user to split the legs into separate prompts.

Never let the first matched Aave verb discard the rest of the sentence.

## Recipe: supply native ETH from SPHINCS/smart account

Goal: supply native ETH on Aave by wrapping to WETH and supplying WETH
atomically from a smart account such as `SPHINCS1`.

Trigger phrases include:

* `supply 0.0123 ETH to Aave sepolia from SPHINCS1`
* `supply 0.0123 ETH in Aave sepolia form SPHINCS1`
* `deposit 0.0123 ETH on Aave from SPHINCS1`

Treat `form <wallet>` as a likely typo for `from <wallet>`. Treat
`in Aave` as equivalent to `on Aave`. Do not ask the user to confirm
WETH when the wallet is SPHINCS/smart; the daemon handles wrapping.

1. Resolve the wallet slot with `slot_lookup`.
2. Call `prepare_aave_supply` with:
   `chainId=11155111` for Sepolia, `sender=<slot address>`,
   `asset="ETH"`, `amount=<wei decimal string>`,
   `accountKind="sphincsHybrid"`.
3. The daemon returns one `ready` `executeBatch` frame targeting the
   smart account. It contains `WETH.deposit{value: amount}()`, optional
   `WETH.approve(Pool, max)`, and `Pool.supply(WETH, amount, sender, 0)`.
4. Feed that returned `action` frame directly to `propose_send` with the
   same `sender`.

Sepolia reserve warning: Aave Sepolia's WETH reserve is
`0xc558dbdd856501fcd9aaf1e62eae57a9f0629a3c`. Do not substitute the
generic Sepolia/Uniswap WETH token
`0xfff9976782d46cc05630d1f6ebab18b2324d6b14`; `Pool.supply` reverts
because that token has no Aave reserve.

For an EOA, native ETH supply is intentionally not auto-composed here:
wrap ETH to WETH first, then use the ERC-20 supply recipe with
`asset="WETH"`.

## Recipe: supply ERC-20 collateral

Goal: deposit `amount` of `asset` and use it as collateral. Mainnet
chainId 1, Sepolia chainId 11155111.

1. Call `prepare_aave_supply` with `sender`, `asset`, and base-unit
   `amount`.
2. If the result is `ready`, feed `action` to `propose_send`.
3. If the result is `needs_approval`, feed `approve` first, then
   `action` to `propose_send` (unless the daemon already returned a
   smart-account batch as `ready`).
4. Post-tx: re-read `getUserAccountData(user)` to confirm
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

1. Call `prepare_aave_withdraw` with `sender`, `asset`, and base-unit
   `amount`; use `amount="MAX"` only for an explicit full withdrawal.
   If the user says `ETH`, pass `asset="ETH"` and let the daemon normalize to
   Aave's WETH reserve. Do not call generic `token_lookup("WETH")` for Aave
   Sepolia; it returns the wrong token for this market.
2. The result should be a Pool call to `withdraw(asset, amount, recipient)`.
   It burns the user's aTokens and returns underlying to `recipient`
   (default: `sender`). For `asset="ETH"` the underlying returned by the Pool
   is WETH; unwrapping native ETH is a separate transaction unless a future
   wallet batch composes it. Do not draft an ERC-20 transfer or approval for
   withdraw.
3. **Pre-withdraw guard**: compute post-hf as in `borrow`.
4. **Refuse if `post_hf < 1.05`.**
5. Feed the returned `action` to `propose_send`.
6. Post-tx: re-read `getUserAccountData(user)` and state whether supplied
   collateral decreased and whether debt/health factor changed.

## Position wording

Before proposing a signable Aave transaction, label the side of the position
that changes:

* `supply` increases supplied collateral / aToken balance.
* `withdraw` decreases supplied collateral / aToken balance and returns
  underlying.
* `borrow` increases variable debt and sends the borrowed underlying.
* `repay` decreases variable debt and pulls underlying from the payer unless
  using an aToken repayment variant.

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
