---
name: aave
version: 0.1
description: Aave V3 — Pool, PoolAddressesProvider. Supply/borrow/repay.
category: protocol
alwaysOn: false
triggers:
  - aave
  - aave v3
  - aave pool
  - 0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2
  - 0x2f39d218133afab8f2b819b1066c7e434ad94e9e
  - 0x6ae43d3271ff6888e7fc43fd7321a503ff738951
  - 0x012bac54348c0e635dcac9d5fb99f06f24136c9a
---
Aave V3 is a lending market. The agent decodes supply/borrow/repay/withdraw
calldata against the V3 Pool and reads health-factor + reserve data via
`chain_read`. Supports mainnet and Sepolia.

