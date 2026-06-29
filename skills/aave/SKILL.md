---
name: aave
version: 0.1
description: Aave V3 — Pool, PoolAddressesProvider. Supply/borrow/repay, including native ETH supply via SPHINCS smart-account WETH batching.
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
Aave V3 is a lending market. For user-facing actions prefer the typed
`prepare_aave_*` tools over manual reads: the daemon resolves Pool/token
addresses, reads allowance, encodes calldata, and returns frames for the
normal confirm pipeline. Supports mainnet and Sepolia.

Always describe the position effect plainly:

* `supply` / `withdraw` change the user's supplied collateral/aToken side.
* `borrow` / `repay` change the user's debt side.
* `withdraw` means `Pool.withdraw(asset, amount, recipient)` and burns the
  user's aTokens to return underlying. It is not an ERC-20 transfer, and it
  does not require an allowance.
* When the user says `ETH` for Aave `withdraw`, `borrow`, `repay`, or
  collateral toggles, use the Aave market's WETH reserve. On Sepolia that is
  `0xc558dbdd856501fcd9aaf1e62eae57a9f0629a3c`, not generic testnet WETH
  `0xfff9976782d46cc05630d1f6ebab18b2324d6b14`. The Pool withdraw returns
  WETH; unwrapping to native ETH is a separate step unless a future wallet
  batch composes it.
* For `withdraw` and `repay`, pass `amount:"MAX"` only when the user asked for
  the full supplied balance / full debt. Otherwise convert the user's human
  amount to base units and pass that exact string.

Fast path: for “supply ETH on Aave” from a SPHINCS/smart account, call
`prepare_aave_supply` once with `asset:"ETH"`, the SPHINCS account address
as `sender`, `accountKind:"sphincsHybrid"`, and the base-unit wei amount.
The daemon batches WETH.deposit + optional approve + Pool.supply into one
atomic `executeBatch` proposal.

Compound requests: if one user message contains more than one Aave action
(`withdraw ... and borrow ...`, `repay ... then withdraw ...`, etc.), do
not prepare only the first verb. Either use an explicit wallet batch composer
that returns one `executeBatch` proposal for smart accounts, or ask the user
to split the request into separate confirmations. Silent truncation is a
safety bug because the confirmation text no longer matches the full request.

Do not answer native-ETH smart-account supply with “Aave does not accept
ETH; do you want WETH?” The user already asked for the supported wallet
flow. The correct response is to prepare the daemon batch. On Sepolia,
Aave's WETH reserve is `0xc558dbdd856501fcd9aaf1e62eae57a9f0629a3c`;
the generic Sepolia/Uniswap WETH `0xfff9976782d46cc05630d1f6ebab18b2324d6b14`
is not the Aave reserve and must not be used for Aave supply.
