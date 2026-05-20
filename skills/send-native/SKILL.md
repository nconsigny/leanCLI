---
name: send-native
description: Move native ETH from a wallet the user controls to a recipient. The canonical baseline skill — all other skills are variations on this shape.
category: transfer
risk: low
requires:
  daemonRpcs:
    - tx.encodeIntent
    - tx.simulate
    - chain.balance
    - chain.resolveName
  wallets:
    - eoa
    - r1
notes:
  - "Decimals: ETH is always 18. Convert decimal-ETH inputs to integer wei before emitting the Intent."
  - "ENS recipients are auto-resolved daemon-side in chat.draft; if you still see a .eth in the regex seed, the daemon could not resolve it — ask the user."
  - "Never invent the `to` address. If the user wrote a name we don't have a resolution for, emit {error, ask}."
---

# send-native — transfer native ETH

## When to use

Natural-language triggers:

* `send <amount> ETH to <recipient>`
* `transfer <amount> ETH to <recipient>`
* `pay <recipient> <amount> ETH`
* `send <recipient> the <amount> ETH I owe them`

Do **not** use this skill for token transfers (USDC, WETH, etc.) — use
[send-erc20](../send-erc20/SKILL.md) instead. WETH is an ERC-20, not native ETH.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `amount` | user prompt | Decimal ETH (e.g. `0.01`). Convert to wei: `amount * 10^18`. |
| `to` | user prompt | 0x-prefixed checksummed address. ENS auto-resolved upstream. |
| `chainId` | request context | The user is on a chain; do not invent. |

If the user prompt is ambiguous on any field, return `{error, ask}` per
the system prompt — do not guess.

## Intent shape

```json
{
  "action": "nativeTransfer",
  "chainId": <int>,
  "to": "0x...",
  "amountWei": <int>
}
```

**Amount conversion — DO NOT compute this yourself.** The daemon has
already done it for you. Look at `seed.fields` for an entry with key
`amountBase` — that's the integer wei amount you should copy verbatim
into `amountWei`. The daemon ran a deterministic `parseUnits` against
the token's decimals before this prompt reached you.

If `amountBase` is missing from the seed, that means the daemon couldn't
determine the decimals (unknown asset). Do not guess; return
`{error: "amountBase not provided by daemon — asset may be unknown", ask: "..."}`.

## Tools available

You may call these read-only daemon tools before emitting the Intent.

- `ethBalance` — read the sender's native ETH balance. **Call this when
  the user says "send all my ETH", "send half my ETH", "send everything
  except gas", or any phrasing that derives the amount from the current
  balance.** Returns wei + human-readable ETH.
- `simulateTx` — dry-run the transfer. Rarely needed for native sends
  (the daemon simulates again at ConfirmGate); only call it if you
  suspect the recipient is a contract that might revert (`getCode`
  isn't on the tool surface yet, so this is the indirect way to learn).

Skip these for the regular case (`send 0.01 ETH to alice`) — copy
`seed.fields.amountBase` and emit.

## Safety

* Refuse to emit if `to` is `0x000…0001` or other known burn-like
  addresses unless the user explicitly says so.
* Refuse `amountWei = 0` (the user typed `0` for some reason; surface
  it as an ask).
* The `to` must be checksum-correct (mixed case). Lowercase-only is a
  phishing red flag — the validator hard-rejects.

## Example prompts that should trigger this skill

1. `send 0.01 ETH to 0xC0deDeAD…`
2. `transfer 1.5 ETH to vitalik.eth` (ENS auto-resolved before you see it)
3. `pay alice 0.05 ETH` (only if `alice` is in the user's address book seed)
4. `send my friend 2 eth to 0x...`
