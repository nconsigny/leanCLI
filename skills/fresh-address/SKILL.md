---
name: fresh-address
description: Generate a new wallet (EOA or TPM-backed R1 smart account) so the user can rotate to a never-used identity. Pairs with `unshield-eth` for the full privacy rotate.
category: hygiene
risk: low
requires:
  daemonRpcs:
    - eoa.create
    - tpm.create
    - tpm.deploy
  wallets:
    - eoa
    - r1
notes:
  - "EOA is fast (no on-chain deployment); R1 is TPM-bound (key cannot leave the chip) but needs a deployment tx if the user wants to actively send from it."
  - "For receive-only fresh addresses (e.g. unshield destination), EOA is fine and cheaper."
  - "Do not auto-name the wallet — ask the user. A name like `fresh-2026-05-19` is a privacy leak if the user pastes it anywhere."
---

# fresh-address — generate a new receiving wallet

## When to use

* `give me a fresh address`
* `make a new wallet for this`
* `I want a clean receiving address`
* implicit step in the rotate workflow: `unshield to a fresh address` →
  this skill, then `unshield-eth` with the resulting address.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `walletType` | user prompt or default | `eoa` (default, cheap, key on disk) or `r1` (TPM-backed, key sealed to chip). |
| `name` | user prompt | A local label for the wallet. ASK the user — do not auto-generate. |
| `deployImmediately` (R1 only) | user prompt | Whether to deploy the R1 smart account now. Default: false. R1 can receive without being deployed; deployment is needed only before the first outbound tx. |

## Intent shape

This skill produces a `createWallet` intent, not a transaction Intent.
The chat.draft handler dispatches it to `eoa.create` or `tpm.create`:

```json
{
  "action": "createWallet",
  "walletType": "eoa" | "r1",
  "name": "<user-chosen-label>",
  "deployImmediately": true | false
}
```

The returned daemon response will include the new wallet's primary
address, which the model can then carry into the next chat turn (e.g.
pass to `unshield-eth` as `recipient`).

## Safety

* The `name` is local. It does not leak on-chain. But it's stored in
  the daemon's wallet directory — the user might share screenshots.
  Encourage opaque labels (`a`, `b`, `fresh-1`) over descriptive ones
  (`alice-tornado-laundered-funds`).
* For EOA: the mnemonic is generated fresh and encrypted with a
  passphrase the user provides separately. **Never** emit the
  passphrase in an Intent — it's prompted out-of-band by the daemon.
* For R1: the keypair is generated inside the TPM. The public key
  goes on chain when deployed; the private key never leaves the
  chip.

## Composability — the rotate workflow

The canonical "rotate" sequence is three skills chained:

1. **shield-eth** — deposit current ETH to Privacy Pools.
2. **fresh-address** — generate a new wallet (this skill).
3. **unshield-eth** — withdraw to the new wallet's address.

The model is encouraged to volunteer this sequence when the user says
things like "I want to start fresh", "rotate", "give me a new identity",
"split my funds privately".

## Example prompts that should trigger this skill

1. `give me a fresh address called fresh1`
2. `create a new R1 smart account named work`
3. `new EOA, please`
4. `I need a clean address for an unshield` (chains into unshield-eth)
