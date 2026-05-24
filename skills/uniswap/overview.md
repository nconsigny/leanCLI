# uniswap — overview

## What it is

Uniswap is a constant-product (V2) and concentrated-liquidity (V3)
automated market maker. The three router contracts the agent
interacts with for spot swaps:

| Router | Best when |
|---|---|
| `SwapRouter02` (V3) | Single-pool or multi-hop V3 swap, fixed fee tiers (100 / 500 / 3000 / 10000). Default for new V3 flows. |
| `UniversalRouter` | Combined flows: V2+V3, Permit2 batching, NFT (Looks/Seaport) wraps. Encodes a sequence of commands; harder to decode. |
| `UniswapV2Router02` | V2-only pools with no V3 counterpart. Legacy. |

For a plain "swap X for Y" intent on a popular pair on mainnet,
`SwapRouter02.exactInputSingle` is the right call. For the same on
Sepolia, the same function on the Sepolia-deployed router.

## Token conventions

* **ETH is not an ERC-20.** Every router accepts ETH by setting
  `tokenIn = WETH` (the contract on each chain) and forwarding
  `value: amountIn` on the call. The router unwraps via a
  `unwrapWETH9` command at the end of the trade.
* **WETH addresses**:
  * Mainnet — `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
  * Sepolia — `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` (Uniswap's
    canonical Sepolia WETH; verify in `contracts.json`).

## Fee tiers (V3)

The V3 pool address is determined by `keccak256(tokenA, tokenB,
fee)`. The standard fee tiers are 100 (0.01%), 500 (0.05%), 3000
(0.30%), and 10000 (1.00%) — denominated in hundredths of a basis
point. Always read the actual pool's `slot0` or use the quoter
contract to pick the right tier; do not guess.

## Slippage and `amountOutMinimum`

Spot price moves between the user's confirmation and the tx mining.
The defensive bound is `amountOutMinimum = quotedAmountOut * (1 -
slippageTolerance)`. The agent's default tolerance is 0.5% (50 bps);
the user can override but a value > 5% is a refusal trigger.

## Deadlines

Every router function accepts a `deadline` (Unix seconds). The agent
uses `now + 1200` (20 minutes) by default. A `deadline` of `0` or
`uint256.max` is a refusal trigger — both let MEV searchers sandwich
the trade weeks later.

## Recipient

Always set `recipient = msg.sender` (the user's address). A
recipient that is *not* the signer is unusual; surface explicitly.

## What this skill is NOT for

* Adding or removing liquidity (`Uniswap V3 NonfungiblePositionManager`).
* Cross-chain bridges of any kind.
* TWAMM, V4 hooks, or unreleased Uniswap surfaces.

The agent should refuse and ask for explicit user direction if asked
for any of these.
