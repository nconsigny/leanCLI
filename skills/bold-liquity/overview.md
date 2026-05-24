# bold-liquity — overview

## What it is

**Liquity V2 (BOLD)** is a CDP-style stablecoin protocol that mints
**BOLD** against overcollateralised positions called **Troves**. It
generalises Liquity V1 in three ways:

1. **Multi-collateral**. One "branch" per collateral type — currently
   ETH (via WETH), wstETH, rETH. Each branch has its own
   `BorrowerOperations`, `TroveManager`, `StabilityPool`,
   `ActivePool`, etc.
2. **Per-Trove interest rate**. The borrower picks an annual rate
   when opening a Trove. Higher rates earn priority in BOLD
   redemptions ("debt in front") and have a lower upfront fee.
3. **No governance**. There is a `Governance` contract for
   incentive direction (`bribe` for LP rewards), but the core
   mint / redeem path is unowned.

The protocol is **mainnet-only**. The `liquity/bold` repo carries
a commented-out testnet block from a prior Sepolia deploy; the
wallet should not target those addresses.

## Core contracts (cross-branch)

| Contract | Mainnet | Role |
|---|---|---|
| `BoldToken` | `0x6440f144B7E50d6a8439336510312D2F54beB01D` | ERC-20 (+ Permit + EIP-5267). Mintable only by branches via `CollateralRegistry`. |
| `CollateralRegistry` | `0xf949982B91C8c61e952B3bA942cbbfaef5386684` | Maps collateral ERC-20 → `TroveManager`. Routes redemptions across branches. |
| `HintHelpers` | `0xF0caE19C96E572234398d6665cC1147A16cBe657` | Off-chain helper for sorted-list insertion hints. |
| `MultiTroveGetter` | `0xFA61dB085510C64b83056dB3a7Acf3B6F631d235` | Batch view for fetching multiple Troves. |
| `Governance` | `0x807DEf5E7d057DF05C796F4bc75C3Fe82Bd6EeE1` | Incentive routing (not core protocol). |

## Per-collateral branches (mainnet)

### ETH branch (collateral: WETH `0xC02a…6Cc2`)

| Component | Address |
|---|---|
| `BorrowerOperations` | `0x372ABd1810EaF23cb9d941bbE7596DFB2c46BC65` |
| `TroveManager` | `0x7bcb64b2C9206A5b699Ed43363f6F98D4776CF5a` |
| `StabilityPool` | `0x5721cBbd64fc7Ae3eF44a0a3F9a790a9264cF9bf` |
| `ActivePool` | `0xeb5A8c825582965f1d84606E078620A84Ab16AfE` |
| `PriceFeed` | `0xCc5f8102Eb670c89A4a3c567C13851260303c24F` |

### WSTETH branch (collateral: wstETH `0x7f39…2ca0`)

| Component | Address |
|---|---|
| `BorrowerOperations` | `0xA741A32f9DCFE6aDBA088FD0F97E90742d7d5dA3` |
| `TroveManager` | `0xa2895d6A3BF110561dfE4b71Ca539d84e1928B22` |
| `StabilityPool` | `0x9502b7c397e9Aa22fe9DB7Ef7daF21CD2AeBe56B` |

### RETH branch (collateral: rETH `0xae78…6393`)

| Component | Address |
|---|---|
| `BorrowerOperations` | `0xE8119Fc02953b27a1B48d2573855738485A17329` |
| `TroveManager` | `0xb2B2aBeb5C357a234363fF5d180912d319e3e19E` |
| `StabilityPool` | `0xD442e41019b7F5C4dD78F50dC03726c446148695` |

## The five user-facing verbs

* `openTrove` — mint a `TroveNFT`, deposit collateral, mint BOLD.
* `addColl` / `withdrawColl` — adjust collateral.
* `withdrawBold` / `repayBold` — adjust debt.
* `adjustTrove` — combined adjustment in one tx.
* `closeTrove` — burn the NFT, repay debt, withdraw collateral.

Plus on the redemption / stability side:

* `CollateralRegistry.redeemCollateral` — burn BOLD for the cheapest
  collateral across all branches.
* `StabilityPool.provideToSP` / `withdrawFromSP` — earn liquidation
  yield.

## Concepts the agent must know

### MCR (Minimum Collateral Ratio)

The branch's hard cliff. Below MCR, the Trove is liquidatable.
Typical values: 110% for ETH/WSTETH branches, higher for RETH. The
wallet reads `BorrowerOperations.MCR()` per branch rather than
hard-coding.

### ICR (Individual Collateral Ratio) and "zombie" Troves

`ICR = (collateral * price) / debt`. A Trove with `ICR < MCR` is
liquidatable. A "zombie" Trove has `ICR < MCR` but hasn't been
liquidated yet (typically during oracle outage); it has restricted
adjustment functions (`adjustZombieTrove`).

### Per-Trove interest and "debt in front"

Each Trove picks its annual rate (`_annualInterestRate`). Redemptions
hit the lowest-rate Troves first (least-paid debt is the easiest to
redeem). The `DebtInFrontHelper` view returns how much BOLD debt is
"in front" of a given Trove for redemption purposes.

### Stability Pool

Deposit BOLD; earn pro-rata share of liquidated collateral when a
Trove is liquidated below MCR. The SP's BOLD is burned to cover the
liquidated debt. A user's deposit can drop to zero if the branch
liquidates more collateral than the SP can absorb.

### Redemption

Anyone can burn BOLD and receive an equivalent (minus
`redemptionFeePercentage`) amount of collateral from the cheapest
Trove. Redemptions are the protocol's price-anchor mechanism — they
keep BOLD ≥ $1.

## Citations

* Liquity V2 repo / README — <https://github.com/liquity/bold>
* Whitepaper — <https://github.com/liquity/bold/tree/main/whitepaper>
* Mainnet deployment table — `liquity/bold:frontend/app/.env`
