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

**Amount conversion examples:**
* `0.01 ETH` → `amountWei: 10000000000000000` (1×10^16)
* `1 ETH`    → `amountWei: 1000000000000000000`
* `0.5 ETH`  → `amountWei: 500000000000000000`

Note: the model is documented unreliable on unit conversion. The canonical
text in ConfirmGate displays `valueWei` for the user to verify; getting
the count of zeros wrong is the most likely failure mode and the user
will catch it.

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
