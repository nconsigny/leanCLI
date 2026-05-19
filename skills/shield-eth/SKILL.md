---
name: shield-eth
description: Deposit native ETH into Privacy Pools so it can later be withdrawn to a fresh address with privacy properties. The first half of the canonical "rotate to a fresh identity" workflow.
category: privacy
risk: medium
requires:
  daemonRpcs:
    - shielded.prepareDeposit
    - shielded.deposit
    - shielded.balance
  wallets:
    - eoa
    - r1
notes:
  - "Privacy Pools is not 'private' in the absolute sense — it provides plausible deniability via a mixing set. Tell the user that explicitly if they seem to expect Tornado-style anonymity."
  - "The anonymity set is users who shielded *in the same epoch*. Shielding dust right before withdrawing breaks the set."
  - "Shielding requires gas paid from the source EOA — the act of paying ETH gas links the source to the deposit timing."
---

# shield-eth — Privacy Pools deposit

## When to use

* `shield <amount> ETH`
* `deposit <amount> into the privacy pool`
* `route this through Privacy Pools`
* `make this anonymous` (this is a UX hint; the model should clarify that "anonymous" means "shielded via Privacy Pools" before proceeding)

For the full rotate workflow ("send 1 ETH to a fresh address privately"),
this is step 1 of 3:

1. **`shield-eth`** — deposit to Privacy Pools (THIS skill).
2. [`fresh-address`](../fresh-address/SKILL.md) — generate a new receiving address.
3. [`unshield-eth`](../unshield-eth/SKILL.md) — withdraw to the fresh address.

The model **should** offer to chain these when the user says "send this
privately to a new wallet", "rotate", or similar.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `amount` | user prompt | Decimal ETH. Privacy Pools may have denomination constraints (specific note sizes); the daemon's `shielded.prepareDeposit` will validate. |
| `chainId` | request context | Privacy Pools deployment is mainnet-first. Some testnets may not be supported. |

## Intent shape

Shielding does **not** use `tx.encodeIntent`. It uses the dedicated
`shielded.deposit` daemon RPC, which composes the deposit transaction
including the witness commitment.

The model should emit:

```json
{
  "action": "shielded.deposit",
  "chainId": <int>,
  "amountWei": <int>
}
```

The chat.draft handler routes `shielded.*` actions through the privacy
sidecar (`bridge/`) — not through `tx.encodeIntent`. This is a different
trust surface than the leaf-action encoder: the privacy sidecar generates
a snarkjs witness; the daemon mediates every chain read; the resulting
deposit tx still flows through simulate + ConfirmGate.

## Safety

* Refuse to shield dust (`< 0.001 ETH`). The anonymity set for dust is empty.
* Warn loudly if the user is shielding right before withdrawing — the
  timing correlates the deposit and withdraw on-chain. The model should
  encourage waiting before unshielding.
* If `chainId` is a testnet without a Privacy Pools deployment, return
  `{error: "Privacy Pools is not deployed on chain <id>", ask: "switch to mainnet for shielding?"}`.

## Anonymity set caveats (surface to the user)

When emitting the Intent or just before, tell the user (in the
`rationale` field of the Intent or as a chat-side note):

> "Your privacy depends on how many others shielded around the same
> time. Shielding alone does not anonymize you; the mixing set does.
> Wait at least a few hours before unshielding, ideally a day."

## Example prompts that should trigger this skill

1. `shield 1 ETH`
2. `deposit 0.5 ETH into the privacy pool`
3. `make this 2 ETH private`
4. `start the shielded rotation with 1 ETH` (chained: shield → fresh → unshield)
