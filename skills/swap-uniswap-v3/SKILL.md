---
name: swap-uniswap-v3
description: Swap one ERC-20 for another via Uniswap V3 `exactInputSingle`. Token→token only — ETH legs (ETH→token or token→ETH) wrap automatically into WETH at the encoder boundary.
category: swap
risk: medium
requires:
  daemonRpcs:
    - tx.encodeIntent
    - tx.simulate
    - swap.uniV3.quote
    - chain.ethCall
    - chain.tokenBalance
  wallets:
    - eoa
    - r1
notes:
  - "minAmountOut MUST be > 0 — the encoder refuses 0 (would accept any slippage)."
  - "Slippage is user-stated as a percentage; convert to an absolute minAmountOut via `quoteUniV3` then `floor(expected * (1 - slippage/100))`. NEVER pass `0` and NEVER invent a number."
  - "For ETH→token or token→ETH: emit `tokenIn`/`tokenOut` as the literal `\"ETH\"` only when calling `quoteUniV3`; in the final Intent, use the chain's WETH address. The Lean Intent parser requires 0x addresses."
  - "Approval: ERC-20 → ERC-20 needs allowance(tokenIn, router) >= amountIn. If insufficient, emit a SEPARATE `erc20Approve` Intent first (the user confirms each leg via ConfirmGate). Pure ETH-in swaps do NOT need approval."
  - "Default fee tier: 3000 (0.3%). `quoteUniV3` returns the tier it actually used — copy that into the Intent."
  - "Default slippage when the user omits it: 0.5%."
---

# swap-uniswap-v3 — single-pool exact-input swap

## Amounts (mandatory)

You never type `amountIn`. Call `prepare_uniswap_v3_swap` with
`amountRef` set to the handle from the `amounts` table — the daemon
already converted the input amount. Do NOT pass a literal `amountIn`;
it is rejected when an `amounts` table is present. The slippage-derived
`minOut` is computed by the daemon's quote + `applySlippage`, never by
you. Feed the returned `to`/`data` straight into `propose_send`; if the
result is `needs_approval`, the approve leg's amount is likewise
daemon-derived.

## When to use

* `swap <amount> <SYMBOL_IN> (for|to|into) <SYMBOL_OUT>`
* `swap <amount> <SYMBOL_IN> to <SYMBOL_OUT> with <N>% slippage`
* `trade USDC for WETH`, `convert ETH to USDC`, `dump my DAI for ETH`

This skill is for **Uniswap V3 only** on chains where the router is wired
(currently mainnet and Sepolia). For any other DEX, refuse with
`{error, ask}`.

Do **not** use this for adding liquidity, removing liquidity, or any
non-swap router action. There is no skill for those yet.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `tokenIn`  | user prompt → `resolveToken` | Symbol → 0x address. `"ETH"` resolves to `null` address (meaning native); see the WETH-substitution note below. |
| `tokenOut` | user prompt → `resolveToken` | Same. |
| `amountIn` | user prompt | Human-readable. Convert to base units with `tokenIn.decimals` (or copy `seed.fields.amountBase` when present). |
| `from`     | user prompt → `resolveWallet` | The signing wallet. If ambiguous, ask. |
| `slippage` | user prompt | Percentage (e.g. `0.5`). Default to `0.5` when omitted. |
| `chainId`  | request context | |

## Step-by-step (tool calls expected)

1. `resolveWallet({label: <from>})` — get the sender address. If
   `candidates` is returned, surface them in `{error, ask}` so the user
   picks. Use the resolved `address` as `recipient` in the Intent.
2. `resolveToken({chainId, symbol: <tokenIn>})` and
   `resolveToken({chainId, symbol: <tokenOut>})` in parallel. If either
   returns `ok: false`, refuse with `{error, ask}`.
3. `knownRouters({chainId, protocol: "uniswap-v3"})` — confirms the
   protocol is wired and yields the canonical Intent action tag
   (`uniswapV3SwapSingle`). If `ok: false`, refuse.
4. `quoteUniV3({chainId, tokenIn, tokenOut, amountIn})` — yields the
   matching `fee` tier and expected `amountOut` (base units, string).
   For ETH-leg swaps pass the literal `"ETH"` here; the daemon resolves
   to WETH for the pool lookup.
5. Compute `minAmountOut = floor(amountOut * (10000 - slippageBps) / 10000)`
   where `slippageBps = round(slippage * 100)` (so `0.5%` → 50 bps).
   The encoder refuses `minAmountOut = 0`; never emit zero.
6. **Approval pre-leg.** If `tokenIn` is not ETH:
   * Call `allowance({chainId, token: tokenIn, owner: <from>, spender: <router>})`.
   * If `value < amountIn`, emit an `erc20Approve` Intent first with
     `spender = router`, `amount = { exact: <some integer ≥ amountIn> }`
     or `"unlimited"` if the user agreed. The user confirms it
     separately in ConfirmGate before the swap Intent is emitted.
7. Emit the swap Intent.

## Intent shape

```json
{
  "action": "uniswapV3SwapSingle",
  "chainId": <int>,
  "tokenIn":  "0x...",
  "tokenOut": "0x...",
  "amountIn":     <int>,
  "fee":          <int>,
  "minAmountOut": <int>,
  "recipient":    "0x...",
  "deadline":     <int>
}
```

* `tokenIn` / `tokenOut`: ALWAYS the on-chain ERC-20 address. For an
  ETH leg, substitute the chain's **WETH** address (look it up via
  `resolveToken({symbol: "WETH"})`). Use the literal `"ETH"` only with
  `quoteUniV3`, never in the Intent.
* `amountIn`: base units integer. Match what was quoted.
* `fee`: copy from `quoteUniV3`'s result. Standard tiers are
  `100` / `500` / `3000` / `10000`.
* `minAmountOut`: base units integer derived in step 5. MUST be > 0.
* `recipient`: the `from` wallet address (same as the signer); do not
  let the model invent a different recipient.
* `deadline`: Unix seconds. Use `now + 1200` (20 minutes) as a safe
  default.

## Tools available

- `resolveToken` — symbol → {address, decimals}. Call before emitting the Intent for every symbol the user names.
- `resolveWallet` — wallet label → {address, kind}. Call once for the `from` argument; surface `candidates` on ambiguity.
- `knownRouters` — confirm the protocol/chain pair is wired. Cheap; call early so you can refuse fast on an unsupported chain.
- `quoteUniV3` — required for the slippage→minAmountOut conversion.
- `allowance` — only when tokenIn is an ERC-20 (skip for ETH-in).
- `balanceOf` — only when the user said "swap all my X" or "half my X".
- `simulateTx` — optional dry-run before emitting; useful when the user is swapping a non-trivial amount.

## Safety

* Refuse `minAmountOut = 0` or unset. The encoder also refuses, but the
  skill MUST refuse first with a clear `{error, ask}` so the user sees
  a useful message instead of an encoder rejection.
* Refuse `slippage > 5%` without an explicit confirmation in the
  prompt (e.g. "with 10% slippage, I know it's high"). Above 5% the
  user is almost always typo-ing or pasting; bail and ask.
* Refuse `tokenIn == tokenOut` (after WETH substitution) — the daemon
  refuses ETH→ETH as "not a swap" and a WETH-on-both-sides Intent is
  the same mistake one layer up.
* Never use any router address other than the one `knownRouters`
  returns. Do NOT hand-encode calldata to a router — emit the
  structured `uniswapV3SwapSingle` Intent and let the Lean encoder
  produce the bytes.

## Example prompts that should trigger this skill

1. `swap 10 USDC for WETH with 0.5% slippage from leanWallet`
2. `convert 0.1 ETH to USDC, 1% slippage`
3. `dump all my DAI for WETH from leanWallet/ops`
4. `swap 100 USDC to ETH` (no slippage given → default 0.5%)
