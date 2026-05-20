---
name: approve-erc20
description: Grant an ERC-20 allowance to a spender so they can call `transferFrom` later. The non-revoke side of approve. Pair with revoke-approval for the inverse.
category: transfer
risk: medium
requires:
  daemonRpcs:
    - tx.encodeIntent
    - tx.simulate
    - chain.ethCall
  wallets:
    - eoa
    - r1
notes:
  - "Approving = giving permission to pull tokens. The user is taking on the risk that the spender will misbehave."
  - "If the user says `approve unlimited X for Y`, the Intent's amount is `\"unlimited\"`. The Lean validator will warn loudly at confirm time."
  - "If the user says `revoke X for Y`, this is the WRONG skill — use revoke-approval instead (amount must be exactly 0)."
  - "The amount is in BASE UNITS of the token, not human-readable. 100 USDC with 6 decimals → 100000000."
---

# approve-erc20 — grant an ERC-20 allowance

## When to use

* `approve <amount> <SYMBOL> for <spender>`
* `approve unlimited <SYMBOL> for <spender>` → emit `amount: "unlimited"`
* `give <spender> permission to spend <amount> <SYMBOL>`
* `increase my <SYMBOL> allowance to <spender> by <amount>` → see safety note: you cannot
  increase without first reading the current allowance, and this skill produces a SET, not an
  add. Return `{error: "approve sets the allowance to a specific amount, it does not add. Please tell me the absolute target amount you want.", ask: "..."}`.

Do **not** use this skill when the user wants to REVOKE (set to 0) — that's
[revoke-approval](../revoke-approval/SKILL.md). If the prompt is ambiguous between
"give" vs "revoke", ask.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `token` | regex seed or chainContext.knownTokens | Resolve symbol → address from `chainContext.knownTokens[chainId][SYMBOL]`. NEVER invent. |
| `spender` | user prompt | 0x-prefixed checksummed address. ENS auto-resolved upstream. |
| `amount` | user prompt | If user said "unlimited", emit `{ "unlimited": true }`. Else convert decimal to base units using the token's decimals. |
| `chainId` | request context | |

## Intent shape

```json
{
  "action": "erc20Approve",
  "chainId": <int>,
  "token": "0x...",
  "spender": "0x...",
  "amount": { "exact": <int> } | "unlimited"
}
```

**Amount conversion — DO NOT compute this yourself.** If the user said
"unlimited" / "infinite" / "max", emit `"unlimited"`. Otherwise copy
`seed.fields.amountBase` verbatim into `{ "exact": <amountBase> }`.
The daemon ran a deterministic `parseUnits` against the token's
decimals before this prompt reached you. Recomputing in the model is
the #1 failure mode for quantitative correctness.

If `amountBase` is missing from the seed, the daemon couldn't determine
decimals. Return `{error, ask}` rather than guessing.

## Tools available

You may call these read-only daemon tools before emitting the Intent. Each
goes through `Privacy.NetworkPolicy` exactly like a CLI/TUI request, and
the result lands in your context as a `role: "tool"` message.

- `allowance` — read the current `allowance(owner, spender)`. **Call this
  whenever the user says "double my current allowance", "add N USDC to
  what I already approved", "make sure the spender can still pull X" —
  any relative or comparative phrasing.** Without this, you'd have to
  guess the current value and the Intent would be wrong.
- `balanceOf` — read the owner's token balance. Useful when the user says
  "approve enough to deposit my full balance" — the approve amount is
  the balance.
- `simulateTx` — dry-run a candidate `{to, value, data}`. Use this when
  the spender is non-standard (not a known protocol) and you want to
  rule out a revert before emitting the Intent. NOT a substitute for
  the final `tx.simulate` the daemon runs at ConfirmGate time.

Tool calls are bounded (max 5 rounds). Emit the final Intent JSON as
soon as you have enough information — don't probe speculatively.

## Safety

* If the user wrote `approve 100 USDC for vitalik.eth`, the spender is the named one. Refuse
  if you cannot resolve the spender address — return `{error, ask}`.
* If `amount` is `"unlimited"`, attach a `rationale` in the Intent making the risk explicit:
  *"Unlimited approval — the spender can pull ANY amount of this token at any time. The
  canonical text in confirm will display UNLIMITED."*
* Refuse `amount: { "exact": 0 }` — that's a revoke, not an approve. Redirect via
  `{error, ask}`.
* The token contract MUST come from `chainContext.knownTokens` (resolved upstream) or be a
  0x address the user explicitly typed. NEVER hallucinate addresses from the symbol — the
  Lean validator's `symbols not in registry` rule will reject anyway.

## Example prompts that should trigger this skill

1. `approve 100 USDC for 0xC0deDeAD…`
2. `give Uniswap permission to spend 50 DAI from my wallet`
3. `approve unlimited WETH for the sushiswap router`
4. `approve 1000 USDC for alice` (when alice is in the user's address book seed)
