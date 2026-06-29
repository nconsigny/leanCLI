# aave — overview

## What it is

Aave V3 is a permissioned-pool lending market: users supply ERC-20
assets to a shared pool, earn variable APY in **aToken** form, and
can borrow against their collateral subject to a per-reserve **LTV**
and a portfolio-level **health factor** (hf). A position with `hf <
1` can be liquidated by any third party.

The single mainnet entrypoint for retail flows is `Pool` at
`0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`. Its address is
discoverable at runtime via `PoolAddressesProvider.getPool()` —
prefer that over hard-coding because Aave can re-point the proxy.
The Lean daemon's `prepare_aave_*` tools own this lookup/encoding path;
the model should call them instead of hand-assembling Pool calldata.

| Chain | Pool | PoolAddressesProvider |
|---|---|---|
| Mainnet (1) | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | `0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e` |
| Sepolia (11155111) | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` | `0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A` |

## The five user-facing verbs

* `supply` — deposit asset; receive aTokens.
* `withdraw` — burn aTokens; receive underlying.
* `borrow` — open or grow a variable-rate debt position.
* `repay` — close or shrink a debt position.
* `setUserUseReserveAsCollateral` — toggle whether a supplied asset
  counts toward LTV.

V3 also exposes `liquidationCall`, `flashLoan`, `flashLoanSimple`,
and an admin surface — these are not retail flows. The wallet should
refuse to surface them absent explicit user direction.

## Native ETH vs WETH

Aave Pool supplies ERC-20 assets. In this wallet, native ETH supply from
a SPHINCS/smart account is supported by the daemon as one atomic
`executeBatch`: wrap ETH with WETH9 `deposit()`, approve the Pool if
needed, then call `Pool.supply(WETH, amount, onBehalfOf, 0)`. The agent
should trigger that path by calling `prepare_aave_supply` with
`asset="ETH"` and `accountKind="sphincsHybrid"`.

Plain EOAs do not get this automatic multi-step composition in the Aave
tool. For EOAs, wrap to WETH first and then supply `asset="WETH"`.

On Sepolia, Aave's WETH reserve is the market token
`0xc558dbdd856501fcd9aaf1e62eae57a9f0629a3c`, not the generic
Sepolia/Uniswap WETH token `0xfff9976782d46cc05630d1f6ebab18b2324d6b14`.
Use the typed `prepare_aave_*` tools so the daemon resolves the
Aave-specific reserve and checks `Pool.getReserveData(asset)` before
signing.

## Concepts the agent must know

### Health factor

`hf = sum(collateral * liquidationThreshold) / totalDebtInBaseCurrency`.
A position is liquidatable when `hf < 1`. The wallet computes the
**post-action** hf before signing any borrow/withdraw/collateral-toggle
and surfaces it explicitly. Default refusal threshold: `hf < 1.05`.

Read via `Pool.getUserAccountData(user)` returning
`(totalCollateralBase, totalDebtBase, availableBorrowsBase,
currentLiquidationThreshold, ltv, healthFactor)`.

### Variable rate only

The V3 stable-rate mode was killed; only `interestRateMode = 2`
(variable) is accepted. `swapBorrowRateMode` is a no-op and the
wallet should never propose it.

### eMode (efficiency mode)

A correlation bucket (e.g. all ETH-correlated LSTs, or all stables).
Within an eMode, LTV is much higher. `setUserEMode` toggles which
category the user is in; changes are health-factor checked.

### Isolation mode

Some long-tail assets are flagged isolation-mode: they can only be
borrowed against alone, up to a debt ceiling. The wallet must read
`getReserveConfigurationData` to know whether an asset is isolated
before proposing a `supply + borrow` combo.

### aTokens and debt tokens

* aToken = receipt for supplied principal + interest. Transferable.
* variableDebtToken = receipt for owed principal + interest.
  Non-transferable. Burned on `repay`.

`Pool.supply(asset, amount, onBehalfOf, referralCode)` ultimately
calls `aToken.mint(...)`. The wallet does not interact with the
aToken directly for supply / withdraw — Pool wraps it.

## Citations

* Aave V3 dev docs — <https://aave.com/docs/developers/smart-contracts/pool>
* Pool ABI — `abi/Pool.json` (sourced from `@aave/core-v3@1.19.3`)
* PoolAddressesProvider ABI — `abi/PoolAddressesProvider.json`
