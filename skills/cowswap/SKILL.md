---
name: cowswap
version: 0.1
description: CoW Protocol settlement contract — batch-auction-based DEX with EIP-712 signed orders.
category: protocol
alwaysOn: false
ofacFlagged: false
triggers:
  - cowswap
  - cow swap
  - cow protocol
  - gpv2settlement
  - 0x9008d19f58aabd9ed0d60971565aa8510560ab41
---
CoW Protocol settles user orders through a batch auction. Users sign an EIP-712
`Order` struct off-chain; solvers compete to find an optimal settlement.
The order EIP-712 typed-data is covered by the existing ERC-7730 descriptor at
`bridge/clearsign/registry/eip712-cowswap-order.json` — the agent's
`decode_eip712` tool uses that, not a duplicate here.

