---
name: audit-approvals
description: Read-only — list every outgoing ERC-20 allowance for a given wallet on a given chain. The diagnostic step that precedes a `revoke-approval` campaign.
category: hygiene
risk: none
requires:
  daemonRpcs:
    - chain.scanTransfers
    - chain.ethCall
  wallets:
    - eoa
    - r1
notes:
  - "This skill does NOT produce a transaction. It produces a structured report the user reads."
  - "Old allowances are findable via Approval event logs (ERC-20 emits `Approval(owner, spender, amount)`). The daemon's scanTransfers is the right entry point."
  - "There is no on-chain registry of all allowances. The audit is best-effort: it surfaces allowances we have evidence for."
---

# audit-approvals — list outgoing ERC-20 allowances

## When to use

* `what approvals do I have?`
* `audit my approvals on mainnet`
* `show me every allowance I've granted`
* `am I exposed to any dApps?`

This is read-only and produces no Intent JSON. Instead, the model
should ask the daemon to do the scan and present the results as
structured prose to the user.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `owner` | user / current wallet | The wallet to audit. Default to the user's active wallet. |
| `chainId` | request context | Audit is per-chain. If the user wants "all chains", ask which to start with. |
| `tokens` (optional) | user prompt | Restrict to specific tokens. Default: scan known-tokens registry. |

## Output

This skill does NOT emit an Intent. It is the one exception. Instead,
return a `{action: "audit", ...}` shape that the daemon recognizes as
a read-only request. The chat.draft handler will see `action: audit`
and skip `tx.encodeIntent`.

(This skill is documented for future implementation. When the model
sees an "audit my approvals" intent, the right answer **today** is to
return `{error: "auditing approvals is not yet implemented in this build", ask: "Want me to revoke a specific allowance instead?"}` and offer to chain into `revoke-approval`.)

## Composability

The natural follow-up to an audit is a sequence of `revoke-approval`
calls. The model should:

1. Run the audit (when implemented).
2. Surface each allowance as a row: token / spender / amount / how old.
3. Offer to revoke them one at a time. Each revoke is a separate Intent;
   each goes through ConfirmGate independently. No batching that hides
   individual revocations from the user.

## Example prompts that should trigger this skill

1. `audit my approvals`
2. `what dApps can pull my USDC?`
3. `show me my outgoing allowances`
4. `am I exposed to anything risky?`
