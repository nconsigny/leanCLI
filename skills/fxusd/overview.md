# fxusd — overview

## What it is

**fxUSD** is the stable asset of the **f(x) Protocol** by Aladdin DAO.
Each collateral (wstETH, sfrxETH, weETH, ezETH) has its own
`MarketV2` + `TreasuryV2` pair that splits collateral into two
synthetic tokens:

* **fToken** — the **stable** leg. Approximately $1 of value;
  insulated from price drops by the levered leg taking the hit
  first. Users wrap fTokens into **fxUSD** 1:1 for fungibility
  across markets.
* **xToken** — the **levered** leg. Implicit 2× to 3× leverage on
  the underlying (depending on collateral ratio). Takes the brunt
  of price moves both up and down.

The central `FxUSD` contract at
`0x085780639CC2cACd35E474e71f4d000e2405d8f6` is the cross-market
fungible representation of fTokens — wrap fToken_wstETH → fxUSD,
unwrap fxUSD → fToken_sfrxETH, etc.

The protocol is **mainnet-only**; there is no Sepolia deployment.

## Core contracts

| Contract | Mainnet | Role |
|---|---|---|
| `FxUSD` | `0x085780639CC2cACd35E474e71f4d000e2405d8f6` | Cross-market fxUSD ERC-20 + wrap/unwrap. |
| `FxUSDImplementation` | `0x6C338c0bFB67970231109d4b33047A6e6BC685e5` | Logic contract (proxy points here). |
| `FxUSDRebalancer` | `0x78c3aF23A4DeA2F630C130d2E42717587584BF05` | Rebalancer keeper. |

## Markets (per-collateral)

| Market | Treasury | Market | fToken | xToken |
|---|---|---|---|---|
| wstETH  | `0xED803540…3Df1f`  | `0xAD9A0E7C…b6155` | `0xD6B8162e…3A23D` | `0x5a097b01…EfF5` |
| sfrxETH | `0xcfEEfF21…F2359` | `0x714B853b…6EbB42` | `0xa87F04c9…73769` | `0x2bb0C321…C82c` |
| weETH   | `0x781BA968…63885`  | `0x267C6A96…CD65f` | `0x92162721…C560` | `0xACB36044…8d2C` |

The full address table is in `contracts.json`.

## The seven user-facing verbs

* **Enter the protocol**
  * `MarketV2.mintFToken(baseIn, recipient, minFTokenOut)` — deposit
    base; receive the stable leg.
  * `MarketV2.mintXToken(baseIn, recipient, minXTokenOut)` — deposit
    base; receive the levered leg.
  * `FxUSD.mint(baseToken, amount, receiver, minOut)` — mint
    fxUSD directly (under the hood: mint fToken, then wrap).
* **Move between legs**
  * `MarketV2.swapFTokenToXToken(fIn, recipient, minXOut)`
  * `MarketV2.swapXTokenToFToken(xIn, recipient, minFOut)`
* **Wrap / unwrap fxUSD**
  * `FxUSD.wrap(baseToken, amount, receiver)`
  * `FxUSD.redeem(baseToken, amount, receiver, minOut)`
* **Stake fxUSD for protocol yield**
  * `FxUSD.earn(baseToken, amount, receiver)` — deposit fxUSD into
    a market's Rebalance Pool.
  * `FxUSD.autoRedeem(amount, receiver, markets)` — burn fxUSD;
    redeem across multiple markets.

## Concepts the agent must know

### Collateral ratio (CR)

`CR = (TVL_in_base * price) / (fToken_supply * 1 + xToken_supply * leveraged_value)`.
Each market has:

* **Stability threshold** (typically 130%) — below this, **xToken
  minting is paused** and the market enters "stability mode".
* **Liquidation threshold** (typically 120%) — below this, the
  Rebalance Pool absorbs xToken positions to recapitalize.
* **Recap mode** (typically 110%) — below this, the protocol can
  socialise losses across fTokens.

The wallet reads `MarketV2.collateralRatio()` or
`TreasuryV2.collateralRatio()` and surfaces the current band
before any mint / wrap.

### Rebalance Pools (Stability sink)

Stakers of fxUSD in a market's Rebalance Pool absorb xToken
liquidations when the market drops into recap mode. They earn:

* Direct collateral gains from absorbed positions.
* Gauge incentives (FXN emissions).
* Boost from veFXN holdings.

Risk: principal can be partially burned if the market needs to
recap by burning Rebalance Pool deposits.

### xToken leverage

xToken's implicit leverage is `L = TVL / (TVL - fToken_supply)`. As
collateral price drops, `fToken_supply` stays ~constant but `TVL`
drops, increasing `L`. At ~115% CR, leverage exceeds 6×, and the
position is approaching liquidation.

### Oracle dependence

Each market has a price oracle (`MarketV2.priceOracle()`). Stale
prices or oracle deviation directly affect CR. The wallet should
read `MarketV2.currentBaseTokenPrice()` and surface any anomaly.

## Citations

* f(x) Protocol docs — <https://docs.aladdin.club/fx-protocol/>
* Deployments — <https://github.com/AladdinDAO/aladdin-v3-contracts/tree/main/deployments/mainnet>
* fxUSD interface — `abi/fxUSD.json` (composed: ERC-20 + IFxUSD.sol)
