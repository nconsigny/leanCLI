---
name: unshield-eth
description: Withdraw shielded ETH (previously deposited via Privacy Pools) to a fresh receiving address. The second half of the "rotate identity" workflow.
category: privacy
risk: medium
requires:
  daemonRpcs:
    - shielded.balance
    - shielded.prepareWithdraw
    - shielded.unshieldDrain
  wallets:
    - eoa
    - r1
notes:
  - "The destination address should be FRESH — one with no prior on-chain history. Withdrawing to your existing main wallet defeats the entire shielding step."
  - "Use the [fresh-address](../fresh-address/SKILL.md) skill to generate a new EOA or R1 before unshielding."
  - "Relayed unshields (the relayer pays gas) preserve more privacy than self-paid ones, because the self-paid version reveals the destination ETH balance change at the chain level."
---

# unshield-eth — Privacy Pools withdraw

## When to use

* `unshield <amount> ETH to <recipient>`
* `withdraw from the privacy pool to <recipient>`
* `pull out my shielded ETH`
* `unshield to a fresh address` (the model should resolve "fresh" via [fresh-address](../fresh-address/SKILL.md))

This is the **second half** of the canonical rotate workflow. The
preceding `shield-eth` step (in a previous chat turn or via a separate
session) must have already credited the user's shielded balance.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `amount` | user prompt | Decimal ETH. Must be ≤ shielded balance. |
| `recipient` | user prompt | 0x-prefixed; FRESH address preferred for privacy. |
| `chainId` | request context | Must match the chain the shield happened on. |

If the user asks to unshield to their own existing address, this is
not a bug — but the model **should** warn that doing so removes the
privacy benefit of the earlier shield.

## Intent shape

```json
{
  "action": "shielded.withdraw",
  "chainId": <int>,
  "amountWei": <int>,
  "recipient": "0x...",
  "viaRelayer": true | false
}
```

`viaRelayer: true` is the privacy-preserving default. The relayer pays
gas; the recipient address never appears as the gas-paying sender on
chain. Default to `true` unless the user explicitly says
`"self-paid"`, `"no relayer"`, etc.

The chat.draft handler routes `shielded.*` actions through the
privacy sidecar (`bridge/`) — same path as shield-eth.

## Safety

* Refuse if requested amount exceeds the shielded balance (check via
  `shielded.balance` before emitting). Surface as `{error, ask}`.
* Refuse to unshield to the same address that originally shielded —
  that round-trip is a no-op privacy-wise and probably a mistake. If
  the user insists, ask twice.
* Always check whether `recipient` has prior on-chain activity. If it
  does (non-zero nonce, prior transfers), warn the user that this
  address is **already linked** and unshielding here defeats the mix.

## Pairing with `fresh-address`

When the user says `unshield to a fresh address`, the model should:

1. Invoke `fresh-address` to generate a new EOA (BIP-39 default) or R1
   (TPM-hardware opt-in) — the model emits an `action: address.fresh`
   intent for that step.
2. Wait for the daemon to surface the new address.
3. Emit `shielded.withdraw` with that new address as `recipient`.

The chat UI shows each step as a separate turn; the user confirms each.
For EOA fresh wallets, the model MUST also remind the user to write
down the BIP-39 mnemonic before continuing — see
[fresh-address](../fresh-address/SKILL.md).

## Example prompts that should trigger this skill

1. `unshield 0.5 ETH to 0xFreshC0deDeAD…`
2. `withdraw 1 ETH from the privacy pool to vitalik.eth`  (warn — vitalik.eth is *not* fresh)
3. `pull 0.1 ETH out shielded`  (model should ask for a destination)
4. `unshield everything to a new address`  (chain into fresh-address first)
