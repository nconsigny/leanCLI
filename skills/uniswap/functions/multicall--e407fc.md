# `multicall(uint256,bytes[])`

`multicall` with a deadline guard. Refuses to execute if
`block.timestamp > deadline`. Prefer this form for batched flows so
the deadline applies uniformly.

Agent: `deadline ≤ now + 1 hour` per `security.md`.

## ABI

* stateMutability: `payable`
* inputs:
  - `deadline` : `uint256`
  - `data` : `bytes[]`
* outputs:
  - `` : `bytes[]`
