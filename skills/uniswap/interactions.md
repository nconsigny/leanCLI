# uniswap — interaction recipes

## Recipe: single-pool V3 swap (ETH → ERC-20)

Goal: trade `amountIn` ETH for at least `amountOutMinimum` of
`tokenOut`, on chain `chainId`, before `deadline`.

1. Pick the V3 fee tier. If unknown:
   * Call the V3 Quoter via `chain_read` with the pool params, or
   * Use the V3 default `3000` (0.30%) and surface the assumption.
2. `nonce({chainId, address: from})` → `<nonce>`.
3. `gas_price({chainId})` → use as the upper bound for fee
   estimation.
4. Compute `amountOutMinimum = quote * (1 - slippage)`.
5. Build calldata for `SwapRouter02.exactInputSingle(...)` with
   `tokenIn = WETH(chain)`. (See `functions/exactInputSingle.md` for
   the exact tuple layout.)
6. `tx.simulate({chainId, from, to: SwapRouter02, value: amountIn,
   data})`.
7. `propose_send({chainId, to: SwapRouter02, value: amountIn,
   data})`.

The wrapper handles wrapping ETH inside the router. The `value`
field on the outer tx is the literal ETH amount; the encoder
embeds `tokenIn = WETH` so the router knows to wrap.

## Recipe: single-pool V3 swap (ERC-20 → ETH)

Same shape, with two differences:

* `value: 0` on the outer tx — no ETH attached.
* `recipient: zeroAddress` in the inner call, then a follow-up
  `unwrapWETH9(amountOutMinimum, recipient)` packed into a
  `multicall(...)`. The Universal Router or
  `SwapRouter02.multicall(...)` is the simplest container.
* Pre-leg: `tokenIn` must have allowance to `SwapRouter02`.
  Call `chain_read` against `allowance(owner, spender)` first; if
  insufficient, emit an `approve(...)` `propose_send` first (the
  user confirms each leg).

## Recipe: V2 swap (legacy pool with no V3 counterpart)

1. Read pool address from `UniswapV2Router02.getPair(...)`.
2. Build calldata for
   `swapExactTokensForTokens(amountIn, amountOutMin, path,
    to, deadline)`.
3. Otherwise same simulate + propose flow.

## Refusal triggers (this skill)

* User asks to add liquidity, remove liquidity, or interact with the
  `NonfungiblePositionManager`. Out of scope for spot swap.
* User asks to swap on a chain other than mainnet (1) or Sepolia
  (11155111).
* User asks for "no slippage" or "infinite slippage". Both refuse.

## Cross-reference to upstream descriptors

`bridge/clearsign/registry/uniswap-v3-swap-router-02.json` already
contains an ERC-7730 descriptor for SwapRouter02. The agent should
use `decode_calldata` against that descriptor and not duplicate the
function-by-function decoding here.
