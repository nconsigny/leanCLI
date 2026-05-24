# `exactInputSingle(tuple)`

Single-pool exact-input V3 swap. The user supplies `amountIn`
of `tokenIn`, gets *at least* `amountOutMinimum` of `tokenOut` from the
pool `(tokenIn, tokenOut, fee)`. The agent's default for new V3 flows.

`params` tuple fields:

| Field | Type | Notes |
|---|---|---|
| `tokenIn` | address | Token spent. WETH for ETH-in trades. |
| `tokenOut` | address | Token received. |
| `fee` | uint24 | Pool fee tier. One of 100/500/3000/10000. |
| `recipient` | address | Receiver. Always the caller unless explicit. |
| `amountIn` | uint256 | Exact input. Carry through verbatim. |
| `amountOutMinimum` | uint256 | Min output. **Must be > 0.** |
| `sqrtPriceLimitX96` | uint160 | 0 = no limit. Leave 0 unless explicitly requested. |

For an ETH-in swap, attach `msg.value = amountIn` and set
`tokenIn = WETH`. For an ETH-out swap, pair this with
`unwrapWETH9` inside `multicall`.

Agent refusals:

* `amountOutMinimum = 0`.
* `recipient ∉ {msg.sender, explicitly named}`.
* `fee ∉ {100, 500, 3000, 10000}`.

## ABI

* stateMutability: `payable`
* inputs:
  - `params` : `tuple`
* outputs:
  - `amountOut` : `uint256`
