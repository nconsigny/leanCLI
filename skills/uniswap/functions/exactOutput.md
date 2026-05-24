# `exactOutput(tuple)`

Multi-hop exact-output V3 swap. Same packed-path layout as
`exactInput` but interpreted from `tokenOut` backwards. Same
agent constraints as `exactOutputSingle`, plus the multi-hop
surface-the-hops obligation from `exactInput`.

## ABI

* stateMutability: `payable`
* inputs:
  - `params` : `tuple`
* outputs:
  - `amountIn` : `uint256`
