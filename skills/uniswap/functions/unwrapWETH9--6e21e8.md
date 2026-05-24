# `unwrapWETH9(uint256)`

Unwraps the router's WETH balance to ETH and forwards
`amountMinimum` (or more) to `recipient`. Used as the tail of a
V3 swap whose output was WETH.

Argument shape (single-recipient overload):

| Field | Type | Notes |
|---|---|---|
| `amountMinimum` | uint256 | Tail-end slippage floor. **Must be > 0.** |
| `recipient` | address | Always the caller unless explicit. |

The two-arg overload omits `recipient` (defaults to `msg.sender`).

## ABI

* stateMutability: `payable`
* inputs:
  - `amountMinimum` : `uint256`
