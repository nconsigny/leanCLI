---
name: morpho
version: 0.1
description: Morpho Blue lending primitive + MetaMorpho vaults. Mainnet primary.
category: protocol
alwaysOn: false
ofacFlagged: false
triggers:
  - morpho
  - morpho blue
  - metamorpho
  - 0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb
  - 0xa9c3d3a366466fa809d1ae982fb2c46e5fc41101
---
Morpho Blue is a minimal lending primitive with isolated markets and a permissionless
deployer. MetaMorpho is the curated-vault layer that aggregates deposits across Blue
markets. The agent treats Blue market positions and MetaMorpho deposits as
stateful — every action requires a fresh `chain_read` against the relevant market.

