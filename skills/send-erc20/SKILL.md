---
name: send-erc20
description: Move an ERC-20 token from a wallet the user controls to a recipient. Uses `transfer(address,uint256)`; the caller pays the gas.
category: transfer
risk: low
requires:
  daemonRpcs:
    - tx.encodeIntent
    - tx.simulate
    - chain.tokenBalance
    - chain.resolveName
  wallets:
    - eoa
    - r1
notes:
  - "NEVER invent contract addresses. If the user names a symbol you don't recognize, return {error, ask}."
  - "Decimals are token-specific. USDC=6, WETH=18, USDT=6, DAI=18. If you're uncertain, ask."
  - "Approval is NOT needed for plain `transfer` — only for `transferFrom` flows."
---

# send-erc20 — transfer an ERC-20 token

## When to use

* `send <amount> <SYMBOL> to <recipient>` where SYMBOL is a real token (not ETH).
* `transfer 100 USDC to alice`
* `pay <recipient> in <SYMBOL>`

Do **not** use this for native ETH — use [send-native](../send-native/SKILL.md).
WETH is an ERC-20 and routes through this skill; "ETH" alone does not.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `amount` | user prompt | Human-readable amount of the token. Convert to base units using the token's decimals: `amount * 10^decimals`. |
| `token` | regex seed or address book | 0x-prefixed contract address. If only a symbol is given, look it up in the seed's known-tokens hint. If unresolvable, ask. |
| `decimals` | known-tokens hint | Must match the canonical decimals for this token. Common: USDC=6, WETH=18, DAI=18, USDT=6, WBTC=8. |
| `to` | user prompt | 0x-prefixed checksummed recipient. |
| `chainId` | request context | |

## Intent shape

```json
{
  "action": "erc20Transfer",
  "chainId": <int>,
  "token": "0x...",
  "decimals": <int>,
  "to": "0x...",
  "amount": <int>
}
```

**Amount conversion — DO NOT compute this yourself.** Copy `seed.fields.amountBase` into the `amount` field of the Intent. The
daemon ran a deterministic `parseUnits(decimal_string, token.decimals)`
before this prompt reached you, looking up decimals from the known-tokens
registry. Recomputing in the model is the #1 failure mode for
quantitative correctness.

If `amountBase` is missing, the daemon couldn't determine decimals.
Return `{error, ask}` rather than guessing.

## Tools available

You may call these read-only daemon tools before emitting the Intent.

- `balanceOf` — read the sender's balance of `token`. **Call this when
  the user says "send all my X", "send half my X", "send the rest of
  my X", or any phrasing that implies the amount is derived from the
  current balance.** Use the returned `value` (base units) directly.
- `simulateTx` — dry-run a candidate `transfer(...)` call. Optional;
  the Lean daemon will simulate again at ConfirmGate time. Use it only
  if the user is asking about a non-trivial token (rebasing, fee-on-
  transfer) and you want to confirm the transfer math.

Skip these for the regular case (`send 100 USDC to alice`) — copy
`seed.fields.amountBase` and emit. Tool calls cost time.

## Safety

* Refuse `amount = 0`.
* Refuse a `token` address that wasn't in the regex seed's known-tokens list — that's an invented address.
* Refuse if `decimals` is missing or implausible (>30, <0). The encoder doesn't re-verify; getting it wrong silently sends the wrong amount.
* The canonical-text ConfirmGate displays `amount` in base units; the user sees `5000000` and recognizes it as `5 USDC` (or doesn't, and bails).

## Example prompts that should trigger this skill

1. `send 100 USDC to 0xC0deDeAD…`
2. `transfer 0.5 WETH to alice`
3. `pay vitalik.eth 50 DAI`
