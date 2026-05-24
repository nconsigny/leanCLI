---
name: railgun
version: 0.1
description: RAILGUN Smart Wallet 2.0 — shielded transfers and shielded interactions on EVM. Mainnet only at present.
category: protocol
alwaysOn: false
ofacFlagged: false
triggers:
  - railgun
  - shield
  - unshield
  - 0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9
  - 0x4d2a481a31d7d4f2937a20a309c4d71fdfd498b6
---
RAILGUN is a SNARK-based shielding system for EVM tokens. The agent decodes
shield/unshield/transfer-shielded calldata to a human-readable intent and surfaces
it to the user via the standard pre-sign pipeline. Witnesses are produced off-chain
by the kohaku-bridge sidecar; the daemon re-validates structure before broadcast.

