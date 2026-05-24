# `exactInput(tuple)`

Multi-hop exact-input V3 swap. The `path` is a packed bytes
sequence `tokenA || fee1 || tokenB || fee2 || tokenC` etc. Use this
only when the pair has no good direct pool — multi-hop adds gas and
risk for marginal price improvement.

`params` tuple fields:

| Field | Type | Notes |
|---|---|---|
| `path` | bytes | Packed `(address,uint24)*` ending in a `address`. |
| `recipient` | address | |
| `amountIn` | uint256 | |
| `amountOutMinimum` | uint256 | **Must be > 0.** |

Agent must surface the full hop sequence in the ConfirmGate. A
multi-hop swap whose hops the agent cannot enumerate is a refusal.

## ABI

* stateMutability: `payable`
* inputs:
  - `params` : `tuple`
* outputs:
  - `amountOut` : `uint256`
