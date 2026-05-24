# morpho — overview

## What it is

**Morpho Blue** is a minimal, permissionless, isolated-market lending
primitive. Each market is a 5-tuple
`(loanToken, collateralToken, oracle, irm, lltv)`. Markets are
independent: a bad-debt event in one market never propagates to
another. The single mainnet contract is at
`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` (`MorphoBlue`).

**MetaMorpho** is the curated-vault layer on top of Blue. A
MetaMorpho vault accepts deposits of a single underlying asset
(e.g. USDC), allocates them across multiple Blue markets per the
curator's policy, and tracks the weighted yield in ERC-4626 shares.
The factory at `0xA9c3D3a366466Fa809d1Ae982Fb2c46E5fC41101`
(`MetaMorphoFactory`) deploys new vaults.

## Five user-facing verbs (Morpho Blue)

* `supplyCollateral` — deposit collateral for a borrow position.
* `borrow` — open / grow a debt position.
* `repay` — close / shrink a debt position.
* `withdrawCollateral` — redeem collateral (subject to LLTV check).
* `supply` / `withdraw` — supply loan asset to earn yield from
  borrowers. Note: collateral does NOT earn yield in Blue.

Auxiliary surfaces: `accrueInterest`, `flashLoan`,
`setAuthorization`, `setAuthorizationWithSig`, `liquidate`,
`createMarket`. Most are not retail flows.

## Concepts the agent must know

### Market id

Every market has an `id = keccak256(abi.encode(marketParams))`. The
wallet computes this locally rather than trusting a sidecar to
resolve the id from human-readable params.

### LLTV (liquidation loan-to-value)

Per-market; expressed in 1e18 scaled WAD. A market with `lltv = 86e16`
is 86% LLTV. The wallet computes the **post-action LLTV health**
before signing borrow / withdraw / supplyCollateral changes. Default
refusal threshold: post-action collateralisation < 1.05× LLTV.

### Position vs Market

* `position(id, user)` → `(supplyShares, borrowShares, collateral)`
* `market(id)` → totals + last accrual block + fee
* `idToMarketParams(id)` → resolve the market params from the id

The wallet uses these three views (one `chain_read` each) to render
"you are about to borrow X against Y" before signing.

### Authorization

A user can authorize a third party (`authorized`) to act on their
positions across all markets via `setAuthorization`. The
`setAuthorizationWithSig` variant accepts an EIP-712 signature so
a third party can submit. **Signing a `setAuthorization` is
delegating wallet control** — the wallet must decode every named
field before letting the user sign.

### Oracle and IRM dependence

Both `oracle` and `irm` are arbitrary external contracts chosen at
market creation. A malicious oracle can grief borrowers (`borrow`
reverts, `liquidate` triggers at the wrong price). A malicious IRM
can charge unbounded interest. The wallet should refuse markets
whose `oracle` / `irm` are not on a known-good list maintained by
the user (or downstream by the curator).

### MetaMorpho timelocks

A MetaMorpho vault has a `timelock` (in seconds) between an
allocator's proposal and its execution. Newly-deployed vaults via
`createMetaMorpho` have `initialTimelock` — the wallet should
surface this value on creation and refuse a 0-timelock vault
without explicit user override.

## Citations

* Morpho Blue dev docs — <https://docs.morpho.org/morpho/contracts/morpho-blue>
* MetaMorpho dev docs — <https://docs.morpho.org/curation/concepts/metamorpho>
* MorphoBlue ABI — `abi/MorphoBlue.json` (sourced from `morpho-org/morpho-blue@v1.0.0/src/interfaces/IMorpho.sol`)
* MetaMorphoFactory ABI — `abi/MetaMorphoFactory.json`
