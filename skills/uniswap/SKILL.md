---
name: uniswap
version: 0.1
description: Uniswap V2 + V3 + Universal Router. Spot swap, exact-input/output routing across pools. Mainnet and Sepolia.
category: protocol
alwaysOn: false
triggers:
  - uniswap
  - uni
  - swap
  - swapexacttokensfortokens
  - exactinputsingle
  - exactinput
  - exactoutputsingle
  - 0x3fc91a3afd70395cd496c647d5a6cc9d4b2b7fad
  - 0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45
  - 0x7a250d5630b4cf539739df2c5dacb4c659f2488d
  - 0x3a9d48ab9751398bbfa63ad67599bb04e4bdf98b
  - 0x3bfa4769fb09eefc5a80d6e87c3b9c650f7ae48e
  - 0xee567fe1712faf6149d80da1e6934e354124cfe3
---

# uniswap — Uniswap V2, V3, and Universal Router

Decentralised exchange routing for spot swaps. The agent prefers
**SwapRouter02 (V3)** for new flows because V3's concentrated
liquidity gives better fills on the same pair. The Universal Router
is the right choice when the user wants to combine multiple swaps,
Permit2 batching, or NFT interactions in one transaction. V2's
`UniswapV2Router02` is kept for legacy pools that have no V3
counterpart.

Permit2 calldata that feeds a Universal Router flow is already
covered by the ERC-7730 descriptor at
`bridge/clearsign/registry/permit2.json`; reference it from
`decode_calldata` rather than re-decoding here.
