---
name: audit-approvals
description: Read-only — list every outgoing ERC-20 allowance for a given wallet on a given chain. The diagnostic step that precedes a `revoke-approval` campaign.
category: hygiene
risk: none
requires:
  daemonRpcs:
    - daemon.approvals.list
  wallets:
    - eoa
    - sphincs
notes:
  - "This skill does NOT produce a transaction. It produces a structured report the user reads."
  - "Three approval surfaces are scanned via their event logs and each re-read live so stale/revoked entries drop out: ERC-20 `allowance` (in `approvals`), ERC-721/1155 `ApprovalForAll` operator grants (in `nftApprovals`), and Uniswap Permit2 grants (in `permit2Approvals`)."
  - "Known spenders/operators are labelled (`spenderLabel`/`operatorLabel`) — e.g. `Uniswap Permit2`, `Aave V3 Pool`. Unknown addresses are left unlabelled (mainnet-canonical list; testnet deployments are not labelled)."
  - "There is no on-chain registry of all allowances, and `eth_getLogs` windows are bounded by the provider. The audit is best-effort over a recent block window: it surfaces allowances we have evidence for, and reports the `fromBlock`/`toBlock` it scanned."
---

# audit-approvals — list outgoing ERC-20 allowances

## When to use

* `what approvals do I have?`
* `audit my approvals on mainnet`
* `show me every allowance I've granted`
* `am I exposed to any dApps?`

This is read-only and produces no Intent JSON. Instead, the model
should call the **`audit_approvals`** tool (which runs the daemon's
cross-dApp `Approval`-log scan) and present the results as structured
prose. NEVER guess a spender list and check `allowance()` against it by
hand — that misses every dApp you didn't think of and is exactly what
`audit_approvals` exists to replace. For a single known owner→spender
pair, use **`check_allowance`** instead.

If the user names a token but not a spender, still use `audit_approvals`
for the owner wallet and filter/report rows for that token. Do not pick
the default wallet, `mainEOA/0`, or any other local wallet as an implied
spender. A phrase like `check allowances for SPHINCS1 USDC sepolia`
means “discover outgoing USDC allowances owned by SPHINCS1”, not
“check SPHINCS1 allowance to mainEOA/0”.

## Required user inputs

| Field | Source | Notes |
|---|---|---|
| `owner` | user / current wallet | The wallet to audit. Default to the user's active wallet. |
| `chainId` | request context | Audit is per-chain. If the user wants "all chains", ask which to start with. |
| `tokens` (optional) | user prompt | Restrict to specific tokens. Default: scan known-tokens registry. |

## Intent shape

This skill emits a read-only `approvals.audit` intent. The chat.draft
handler recognizes the action tag and routes to the daemon-side scan
(`daemon.approvals.list` — `Approval` event logs over a configurable
block window, then a live `allowance()` re-read per spender), bypassing
`tx.encodeIntent` entirely. No signing path.

```json
{
  "action": "approvals.audit",
  "chainId": <int>,
  "wallet": "0x..."
}
```

`wallet` is OPTIONAL — when omitted, chat.draft fills it with the active
default wallet's address. The response shape is a list of records:

```json
[
  {"token": "0x...", "spender": "0x...", "amount": "<uint256 string>",
   "amountHuman": "unlimited (max uint256)", "tokenSymbol": "USDC", "lastSeenBlock": <int>},
  ...
]
```

`amountHuman`/`tokenSymbol` are best-effort enrichment (empty when token
metadata couldn't be fetched). Pairs whose current allowance is 0 are
omitted — they are not actionable.

The model presents the results as a structured list (one row per
allowance) and offers to chain into `revoke-approval` per row.

## Composability

The natural follow-up to an audit is a sequence of `revoke-approval`
calls. The model should:

1. Run the audit.
2. Surface each allowance as a row: token / spender / amount / how old.
3. Offer to revoke them one at a time. Each revoke is a separate Intent;
   each goes through ConfirmGate independently. No batching that hides
   individual revocations from the user.

## Example prompts that should trigger this skill

1. `audit my approvals`
2. `what dApps can pull my USDC?`
3. `show me my outgoing allowances`
4. `am I exposed to anything risky?`
