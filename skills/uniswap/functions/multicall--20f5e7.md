# `multicall(bytes[])`

Batch multiple calls to this router in a single transaction.
The contract delegate-calls back into itself for each entry, so each
inner call sees `msg.sender = original caller`.

Common shapes the agent emits:

* `[exactInputSingle, unwrapWETH9]` — V3 swap into WETH then unwrap
  to ETH for the user.
* `[exactInputSingle, refundETH]` — V3 ETH-in swap that returns any
  unused ETH.

Agent must enumerate every inner call in the ConfirmGate. A
`multicall` where any inner is opaque is a refusal.

## ABI

* stateMutability: `payable`
* inputs:
  - `data` : `bytes[]`
* outputs:
  - `results` : `bytes[]`
