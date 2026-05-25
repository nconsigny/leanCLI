---
name: privacy-pool
version: 0.1
description: Privacy Pools v1 (0xbow) — opt-in association-set shielded pools on EVM. Agent uses the @kohaku-eth/privacy-pools SDK; never drafts raw shielded calldata.
category: protocol
alwaysOn: false
triggers:
  - privacy pool
  - privacy-pool
  - privacypool
  - privacy pools
  - 0xbow
  - "@kohaku-eth/privacy-pools"
  - asp
  - ragequit
  - 0x6818809eefce719e480a7526d76bd3e561526b46
---
Privacy Pools enable shielded deposits and withdrawals constrained by an opt-in
association set ("ASP"). The agent **must use the `@kohaku-eth/privacy-pools`
SDK** to prepare every deposit, withdrawal, and ragequit — never draft pool
calldata by hand. Witnesses and ASP proofs are produced inside the kohaku-bridge
Node sidecar; the daemon re-decodes every returned transaction and gates through
the standard `decode_calldata → simulate → ConfirmGate` path before signing.
