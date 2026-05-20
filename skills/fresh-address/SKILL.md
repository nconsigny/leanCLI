---
name: fresh-address
description: Generate a new wallet (BIP-39 EOA by default, or TPM-backed R1 smart account on opt-in) so the user can rotate to a never-used identity. Pairs with `unshield-eth` for the full privacy rotate.
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
  - "Default kind is EOA via BIP-39 (12-word mnemonic). The mnemonic is the user's recovery path — ALWAYS tell them to write it down before they leave the screen."
  - "R1 is the TPM-hardware-key opt-in. Key is generated inside the TPM and never leaves the chip; signing is hardware-bound. Triggered by phrases like 'TPM', 'hardware key', 'hardware-backed', 'secure enclave', or 'smart account' (R1 is an ERC-4337 R1 smart account)."
  - "EOA is the right default for receive-only fresh addresses (e.g. unshield destination): fast, no on-chain deployment, and the seed-at-rest is itself encrypted under the master KEK that the TPM seals."
  - "Do not auto-name the wallet — ask the user. A name like `fresh-2026-05-19` is a privacy leak if the user pastes it anywhere. The validator caps labels at 64 chars."
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
| `kind` | user prompt or default | `eoa` (DEFAULT — BIP-39 mnemonic, software signing, seed encrypted at rest under TPM-sealed master KEK). `r1` is opt-in (TPM hardware key, ERC-4337 smart account). |
| `label` | user prompt | A local nickname for the wallet. ASK the user — do not auto-generate. Keep it opaque (`a`, `b`, `fresh-1`), not descriptive. Validator caps at 64 chars. |
| `deployImmediately` (R1 only) | user prompt | Whether to deploy the R1 smart account now. Default: false. R1 can receive without being deployed; deployment is needed only before the first outbound tx. Ignored for EOA. |

## Intent shape

This skill produces an `address.fresh` intent, NOT a transaction Intent.
The chat.draft handler dispatches it to `eoa.create` (BIP-39 path) or
`tpm.create` (R1 path) — no `tx.encodeIntent` call.

```json
{
  "action": "address.fresh",
  "chainId": <int>,
  "kind": "eoa" | "r1",
  "label": "<user-chosen-opaque-label>",
  "deployImmediately": true | false
}
```

All three of `kind` / `label` / `deployImmediately` are OPTIONAL. The
daemon defaults:
* `kind` → `"eoa"` (BIP-39 EOA, the canonical default)
* `label` → none (TUI prompts the user for one in a follow-up step)
* `deployImmediately` → `false`

For the EOA path, the daemon will generate a 12-word BIP-39 mnemonic
and surface it to the user via the unlock/confirm screen. **The model
MUST tell the user, in the same turn it emits the intent, that they
will be shown a 12-word recovery mnemonic and must write it down** —
that mnemonic is the only recovery path if the encrypted store is ever
lost.

The returned daemon response includes the new wallet's primary
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

1. `give me a fresh address called fresh1` → EOA / BIP-39 (default kind, label `fresh1`)
2. `create a new R1 smart account named work` → R1 (explicit smart-account opt-in)
3. `new EOA, please` → EOA / BIP-39
4. `I need a clean address for an unshield` (chains into unshield-eth) → EOA / BIP-39 default; receive-only doesn't need R1
5. `fresh address backed by the TPM` → R1 (hardware-key trigger)
6. `give me a hardware-backed wallet` → R1
