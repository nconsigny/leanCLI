# `exactOutputSingle(tuple)`

Single-pool exact-output V3 swap. The user wants *exactly*
`amountOut` of `tokenOut` and is willing to spend up to
`amountInMaximum` of `tokenIn`. Use when the user phrases the trade
in terms of the output ("I need 1000 USDC").

`params` tuple fields:

| Field | Type | Notes |
|---|---|---|
| `tokenIn` | address | |
| `tokenOut` | address | |
| `fee` | uint24 | One of 100/500/3000/10000. |
| `recipient` | address | |
| `amountOut` | uint256 | Exact output. |
| `amountInMaximum` | uint256 | Cap. **Must be > 0 and finite.** |
| `sqrtPriceLimitX96` | uint160 | 0 unless explicitly requested. |

Any unused `tokenIn` allowance returns to `msg.sender` after the
swap. Pair with `refundETH()` inside `multicall` for ETH-in.

Agent refusals:

* `amountInMaximum` left at `uint256.max`. Always require a real
  cap.

## ABI

* stateMutability: `payable`
* inputs:
  - `params` : `tuple`
* outputs:
  - `amountIn` : `uint256`
