---
name: revoke-approval
description: Revoke an existing ERC-20 allowance by setting it to exactly 0. The canonical wallet-hygiene move after interacting with a dApp the user no longer trusts.
category: hygiene
risk: low
requires:
  daemonRpcs:
    - tx.encodeIntent
    - tx.simulate
    - chain.ethCall
  wallets:
    - eoa
    - r1
notes:
  - "REVOKE means amount = 0 exactly. Any other amount is an approve, not a revoke. Refuse to emit anything else under this skill."
  - "A revoke is an on-chain transaction. It costs gas. The user gets nothing back, but the spender can no longer pull tokens."
  - "If the user says 'revoke unlimited approval' that's still a revoke — emit amount = 0, not 'unlimited'."
---

# revoke-approval — set an ERC-20 allowance to 0

## When to use

* `revoke <SYMBOL> approval for <spender>`
* `revoke all <SYMBOL> approvals` (the user means "for the spender they currently have one with"; if multiple spenders, ask which)
* `cancel my USDC allowance to Uniswap`
* `remove approval for <0xSpender>`

This is the **single safest wallet-hygiene action** — strictly never moves
funds, only removes permissions. Encourage the user to use it after any
dApp interaction they regret or any spender contract they no longer trust.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `token` | user prompt | The token whose allowance is being revoked. Resolve symbol → address via the regex seed. |
| `spender` | user prompt | The contract / address that currently has the allowance. |
| `chainId` | request context | |

The `amount` is **fixed at 0** by this skill — do not take it from the user.

## Intent shape

```json
{
  "action": "erc20Approve",
  "chainId": <int>,
  "token": "0x...",
  "spender": "0x...",
  "amount": { "exact": 0 }
}
```

**Always** `{ "exact": 0 }`. NEVER `"unlimited"`, NEVER any other number.
If the user is asking to set a *non-zero* allowance, this is the wrong
skill — that's an approve action, not a revoke.

## Tools available

You may call these read-only daemon tools before emitting the Intent.

- `allowance` — read the current allowance. Call this when you want to
  confirm there *is* a non-zero allowance to revoke (the user may have
  already revoked it; a zero → zero revoke is a wasted gas tx). If the
  current allowance is already 0, return `{error: "the allowance for
  this spender is already 0 — no revoke needed", ask: "..."}` instead
  of emitting an Intent.

Don't call `balanceOf` or `simulateTx` here — revokes don't move funds,
and the Lean validator already enforces `amount = 0`.

## Safety

* Hard-refuse to emit anything but `amount: { "exact": 0 }`. If the
  user's prompt implies setting allowance to a non-zero value, return
  `{error: "this skill only revokes (sets allowance to 0). For setting an allowance, ask differently.", ask: "..."}`.
* The Lean validator + canonical text show `amount: 0` to the user;
  if the model accidentally emits something else, the user will see
  the actual amount and bail.
* On simulate, this should produce no token movement (it changes an
  allowance slot, not balances). The TransfersBlock will be empty —
  this is correct, not a sign of failure.

## Example prompts that should trigger this skill

1. `revoke USDC approval for Uniswap`
2. `cancel my DAI allowance to 0xC0deDeAD…`
3. `remove the unlimited WETH approval I gave to the sushiswap router`
4. `revoke approve USDC 0x...`
