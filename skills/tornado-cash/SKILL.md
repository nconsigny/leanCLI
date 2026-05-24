---
name: tornado-cash
version: 0.1
description: Tornado Cash ETH mixer pools. OFAC-sanctioned (SDN list, 2022-08-08). Research / decode-only — Kohaku ships no SDK and the agent does NOT draft Tornado Cash transactions.
category: protocol
alwaysOn: false
ofacFlagged: true
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
to break the on-chain link between deposit and withdrawal. The primary smart
contracts are sanctioned under U.S. Treasury / OFAC (SDN listing 2022-08-08,
E.O. 13694). **Kohaku ships no `@kohaku-eth/tornado-cash` SDK.** This skill
is **research and decode-only**: the agent can explain what a Tornado Cash
calldata blob does, but it does NOT draft outgoing Tornado Cash transactions.
The agent surfaces sanctions status as a factual statement; the legal decision
belongs to the user in their own jurisdiction.
