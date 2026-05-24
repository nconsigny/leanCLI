# Protocol skills curation (Phase 1b follow-up)

This doc records the curation of `skills/<protocol>/` content for the six
DeFi protocols Phase 1b scaffolded. For each protocol we list which ABI
source worked, which functions are covered by an existing ERC-7730
descriptor in `bridge/clearsign/registry/`, and any address corrections
made against the Phase 1b scaffold.

## Method

The methodology for every protocol is the same:

1. Check `bridge/clearsign/registry/` for a 7730 descriptor that already
   covers the user-facing decoded view. If found, the function
   `.md` files **reference** the descriptor instead of duplicating
   semantics.
2. Fetch the contract ABI. Source priority:
   1. Etherscan v2 API (requires API key — skipped in this sandbox).
   2. Official GitHub raw / GitHub Contents API.
   3. unpkg (npm CDN) when the protocol publishes ABIs as compiled
      artifacts.
   On failure the ABI file gets a `TODO(curator):` note pointing at
   the canonical URL. No ABI entry is fabricated.
3. Enumerate every function (`type: "function"`) and generate
   `skills/<p>/functions/<name>.md` with **signature**, **selector**
   (keccak256 of the canonical ABI signature), and **mutability**
   filled from the ABI directly. Overloaded names get a
   `--<8-hex-selector>` filename suffix. Semantics paragraphs are
   `TODO(curator):` unless the function is in a 7730 descriptor or
   was already populated by Phase 1b.
4. Write `overview.md`, `security.md`, `interactions.md` — high
   confidence sections written, low-confidence sections kept as
   `TODO(curator):` with a doc pointer.

Addresses in `contracts.json` are **EIP-55 checksummed**. Triggers in
`SKILL.md` use the lowercased form for hex matching.

## ABI fetch result

| Protocol | Contract | Source that worked |
|---|---|---|
| uniswap | SwapRouter02 | unpkg `@uniswap/swap-router-contracts@1.3.1` (already populated) |
| uniswap | UniversalRouter | unpkg `@uniswap/universal-router` (already populated) |
| uniswap | UniswapV2Router02 | already populated by Phase 1b |
| cowswap | GPv2Settlement | unpkg `@cowprotocol/contracts@1.8.0/deployments/mainnet/GPv2Settlement.json` |
| aave | Pool | unpkg `@aave/core-v3@1.19.3/artifacts/.../Pool.json` |
| aave | PoolAddressesProvider | unpkg `@aave/core-v3@1.19.3/artifacts/.../PoolAddressesProvider.json` |
| morpho | MorphoBlue | GitHub `morpho-org/morpho-blue` (compiled out/ artifact via API) |
| morpho | MetaMorphoFactory | GitHub `morpho-org/metamorpho` |
| bold-liquity | BoldToken | GitHub `liquity/bold` raw Solidity source — interface extracted manually for ABI |
| bold-liquity | BorrowerOperations + TroveManager (per branch) | GitHub `liquity/bold` |
| fxusd | FxUSD | GitHub `AladdinDAO/aladdin-v3-contracts/contracts/f(x)/v2/FxUSD.sol` |

## 7730 descriptor coverage

| Protocol | Descriptor file | What it covers |
|---|---|---|
| uniswap | `bridge/clearsign/registry/uniswap-v3-swap-router-02.json` | SwapRouter02 `exactInputSingle`, `exactInput`, `multicall`, `refundETH`, `unwrapWETH9` |
| uniswap (UR) | `bridge/clearsign/registry/permit2.json` | Permit2 `approve` (used by Universal Router) |
| cowswap | `bridge/clearsign/registry/eip712-cowswap-order.json` | The EIP-712 `Order` struct users sign off-chain |
| erc-20 baseline | `bridge/clearsign/registry/erc20.json` | `approve`, `transfer`, `transferFrom` (used by every protocol) |
| aave | (none) | — |
| morpho | (none) | — |
| bold-liquity | (none) | — |
| fxusd | (none) | — |

Missing descriptors that would be useful (not added in this PR per scope):

- Aave V3 `Pool.supply`, `Pool.borrow`, `Pool.repay`, `Pool.withdraw`.
- Morpho Blue `supply`, `borrow`, `repay`, `withdraw`, `supplyCollateral`,
  `withdrawCollateral`.
- CowSwap `setPreSignature` (the on-chain settlement-side
  pre-signature; the EIP-712 signing path is already covered).
- Liquity v2 `BorrowerOperations.openTrove` /
  `BorrowerOperations.adjustTrove`.

## Address corrections from Phase 1b scaffold

- **bold-liquity**: Phase 1b scaffold used `BoldToken =
  0xb01dd87B29d187F3E3a4Bf6cdAebfb97F3D9aB98` cited from "GitHub deployment
  table". The actual mainnet deployment per
  `liquity/bold:frontend/app/.env` (committed in the canonical repo) is
  `0x6440f144B7E50d6a8439336510312D2F54beB01d`. This curation pass uses
  the env file value; the scaffold value is documented here as wrong.
  Source: <https://github.com/liquity/bold/blob/main/frontend/app/.env>.
- **fxusd**: Phase 1b scaffold value
  `0x085780639CC2cACd35E474e71f4d000e2405d8f6` (fxUSD token proxy)
  matches the canonical `deployments/mainnet/Fx.FxUSD.json` entry
  `FxUSD.proxy.fxUSD`. No correction.
- **aave, morpho, cowswap, uniswap**: Phase 1b scaffold addresses
  match official docs / npm artifacts. No correction.

## Scope

This curation does **not** change Lean code, daemon RPCs, agent tools, or
the registry. It only fills `skills/{uniswap,cowswap,aave,morpho,bold-liquity,fxusd}/`
with real ABIs (where fetchable) and real function indexes.
