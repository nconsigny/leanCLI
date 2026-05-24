# `wrapETH(uint256)`

Wraps `value` ETH from the call's `msg.value` into WETH held by
the router. Used as the head of a V3 swap whose input is ETH and
the user wants to combine the wrap + swap in one tx via `multicall`.

## ABI

* stateMutability: `payable`
* inputs:
  - `value` : `uint256`
