---
name: tornado-cash
version: 0.1
description: Tornado Cash ETH mixer pools. Coming soon — no `@kohaku-eth/tornado-cash` SDK is wired in yet.
category: protocol
alwaysOn: false
triggers:
  - tornado cash
  - tornado
  - mixer
  - 0x12d66f87a04a9e220743712ce6d9bb1b5616b8fc
  - 0x47ce0c6ed5b0ce3d3a51fdb1c52dc66a7c3c2936
  - 0x910cbd523d972eb0a6f4cae4618ad62622b39dbf
  - 0xa160cdab225685da1d56aa342ad8841c3b53f291
---
Tornado Cash is an older fixed-denomination Ethereum mixer that uses zk-SNARKs
to break the on-chain link between deposit and withdrawal. leanCLI does not yet
ship a `@kohaku-eth/tornado-cash` SDK package, so drafting Tornado Cash
transactions through the agent is **coming soon**. The skill is loaded today
for decode context: the agent can explain what a Tornado Cash calldata blob
does. To shield ETH today, use Privacy Pool (`@kohaku-eth/privacy-pools`) or
Railgun (`@kohaku-eth/railgun`) from the Privacy menu.
