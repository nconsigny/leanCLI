---
name: bold-liquity
version: 0.2
description: Liquity V2 (BOLD) — ETH/wstETH/rETH-collateralised stable asset, no governance (mainnet only).
category: protocol
alwaysOn: false
triggers:
  - bold
  - liquity v2
  - liquity bold
  - trove
  - boldtoken
  - 0x6440f144b7e50d6a8439336510312d2f54beb01d
  - 0xf949982b91c8c61e952b3ba942cbbfaef5386684
  - 0x372abd1810eaf23cb9d941bbe7596dfb2c46bc65
  - 0xa741a32f9dcfe6adba088fd0f97e90742d7d5da3
  - 0xe8119fc02953b27a1b48d2573855738485a17329
  - 0x7bcb64b2c9206a5b699ed43363f6f98d4776cf5a
  - 0xa2895d6a3bf110561dfe4b71ca539d84e1928b22
  - 0xb2b2abeb5c357a234363ff5d180912d319e3e19e
  - 0x5721cbbd64fc7ae3ef44a0a3f9a790a9264cf9bf
  - 0x9502b7c397e9aa22fe9db7ef7daf21cd2aebe56b
  - 0xd442e41019b7f5c4dd78f50dc03726c446148695
---
BOLD is the stable asset of Liquity V2 — overcollateralised by ETH /
wstETH / rETH, redeemable for collateral at $1, no governance over the
core mint/redeem path. The wallet decodes Trove open / adjust / close
calldata against `BorrowerOperations`, surfaces the post-action interest
rate and collateral ratio, and routes everything through the standard
pre-sign pipeline. Mainnet only — no Sepolia deployment.
