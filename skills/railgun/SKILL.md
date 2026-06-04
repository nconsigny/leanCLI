---
name: railgun
version: 0.1
description: RAILGUN Smart Wallet 2.0 — shielded transfers and shielded interactions on EVM. Mainnet only at present. Agent uses the @kohaku-eth/railgun SDK; never drafts raw shielded calldata.
category: protocol
alwaysOn: false
triggers:
  - railgun
  - shield
  - unshield
  - 0zk
  - "@kohaku-eth/railgun"
  - 0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9
  - 0x4d2a481a31d7d4f2937a20a309c4d71fdfd498b6
---
RAILGUN is a SNARK-based shielding system for EVM tokens. The agent **must use
the `@kohaku-eth/railgun` SDK** to prepare every shield, unshield, and shielded
transfer — never draft RAILGUN calldata by hand. ZK witness generation runs
inside the leancli-bridge Node sidecar; the SDK returns prepared transactions
that the daemon re-decodes and gates through the standard `decode_calldata →
simulate → ConfirmGate` path before any signature is produced.
