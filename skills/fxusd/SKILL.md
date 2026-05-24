---
name: fxusd
version: 0.2
description: fxUSD — Aladdin DAO's LRT/LST-backed stable asset, with per-collateral Markets and Rebalance Pools (mainnet only).
category: protocol
alwaysOn: false
ofacFlagged: false
triggers:
  - fxusd
  - fx.aladdin
  - aladdin dao
  - fx protocol
  - ftoken
  - leveraged token
  - 0x085780639cc2cacd35e474e71f4d000e2405d8f6
  - 0xed803540037b0ae069c93420f89cd653b6e3df1f
  - 0xad9a0e7c08bc9f747df97a3e7e7f620632cb6155
  - 0xcfeeff214b256063110d3236ea12db49d2df2359
  - 0x714b853b3ba73e439c652cfe79660f329e6ebb42
  - 0x781ba968d5cc0b40eb592d5c8a9a3a4000063885
  - 0x267c6a96db7422faa60aa7198ffeeec4169cd65f
---
fxUSD is the stable asset of the Aladdin DAO fx Protocol. Each
collateral (wstETH, sfrxETH, weETH, ezETH) has its own `MarketV2` /
`TreasuryV2` pair that splits collateral deposits into a fractional
"fToken" (the stable-leaning leg) and a "xToken" (the levered leg).
Users wrap fTokens to fxUSD and unwrap fxUSD back to fTokens through
the central `FxUSD` contract at
`0x085780639CC2cACd35E474e71f4d000e2405d8f6`. The wallet decodes
mint, redeem, wrap, unwrap, and stability-pool interactions through
the standard pre-sign pipeline. Mainnet only — no Sepolia.
