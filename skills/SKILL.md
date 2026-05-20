---
name: kohaku-skills
description: Entry point for the kohaku wallet's local-LLM skills pack — privacy-first and wallet-hygiene-first. Each sub-skill maps a class of user intent to concrete daemon RPCs (`tx.encodeIntent`, `shielded.*`, `chain.scanTransfers`, …) and the safety steps that must run before signing.
user-invocable: false
disable-model-invocation: false
trust-model: model-is-untrusted
---

# kohaku skills

This pack is loaded by the local-LLM chat path
(`LeanKohaku/Daemon/Server.lean#chat.draft`). Each skill scopes a class of
intents the user is allowed to ask in natural language; the model's job is
to **match the user's prompt to the right skill** and emit the structured
`Intent` JSON each skill specifies. The skill body documents exactly which
daemon RPCs to call and which to avoid.

## Trust model

Same model as everywhere else in this repo: the **sidecar / model is
treated as malicious**. Skills do not relax that. Every emitted `Intent`
still flows through:

1. `IntentParser.parseIntent` — Lean hard-rejects (v/r/s/RLP/wrong-chain/
   dead-testnet/non-checksummed address).
2. `tx.encodeIntent` — deterministic encoder; refuses structural footguns
   like `minAmountOut = 0` on swaps.
3. `tx.simulate` — eth_call + estimateGas.
4. `ConfirmGate` (TUI) — canonical `Intent` text + simulation shown side
   by side; user presses enter to sign or esc to bail.

A skill cannot bypass any of these. A skill **can** add extra rejections
on top (e.g. `revoke-approval` insists the amount is exactly `0`; nothing
else is a revoke).

## Loading principle

Load only what you need now. The chat path probes the user's prompt with
the regex parser first, identifies the action category, and only the
skills matching that category are loaded into the LLM's context. This
keeps prompts small and the model focused.

## Skill map

| Skill | Category | Risk | Purpose |
|---|---|---|---|
| [send-native](send-native/SKILL.md)        | transfer | low    | Move native ETH from a wallet you control. The baseline transaction. |
| [send-erc20](send-erc20/SKILL.md)          | transfer | low    | Move an ERC-20 token. Always emits a `transfer(address,uint256)`. |
| [approve-erc20](approve-erc20/SKILL.md)    | transfer | medium | Grant an ERC-20 allowance to a spender (any non-zero amount, or unlimited). |
| [revoke-approval](revoke-approval/SKILL.md)| hygiene  | low    | Revoke an existing ERC-20 allowance by setting it to exactly 0. |
| [audit-approvals](audit-approvals/SKILL.md)| hygiene  | none   | Read-only: list current outgoing allowances for a wallet. |
| [shield-eth](shield-eth/SKILL.md)            | privacy  | medium | Deposit native ETH into Privacy Pools so it can be withdrawn later to a fresh address. |
| [unshield-eth](unshield-eth/SKILL.md)        | privacy  | medium | Withdraw shielded ETH to a fresh receiving address. |
| [fresh-address](fresh-address/SKILL.md)      | hygiene  | low    | Generate a new EOA or TPM-backed R1 smart account so the user can move to a fresh identity. |
| [swap-uniswap-v3](swap-uniswap-v3/SKILL.md)  | swap     | medium | Single-pool `exactInputSingle` swap on Uniswap V3 (mainnet, Sepolia). ETH legs wrap to WETH at the encoder boundary. |

Future entries (not yet in this pack):

* `sweep-dust` — drain small token balances back to a main wallet in one
  multicall.
* `migrate-to-r1` — bundled "create R1 + sweep EOA → R1" workflow.

## Naming + frontmatter convention

Every skill is `<name>/SKILL.md` with this frontmatter:

```yaml
---
name: <short-kebab-case>             # matches the directory name
description: <one-line summary>      # surfaced in skills.list
category: transfer | hygiene | privacy | swap | governance
risk: none | low | medium | high
requires:
  daemonRpcs: [list of `module.method` strings the model is allowed to call]
  wallets: [eoa | r1]                # which wallet types the skill supports
notes:
  - free-form caveats the model should respect
---
```

Body convention (every skill follows):

1. `## When to use` — natural-language trigger phrases.
2. `## Required user inputs` — what the model needs from the user before emitting an Intent.
3. `## Intent shape` — the exact JSON the model should produce for `tx.encodeIntent`.
4. `## Safety` — what the skill refuses and why.
5. `## Example prompts` — three or four real prompts that should trigger this skill.

## Privacy + hygiene philosophy

The two priority categories are not arbitrary. They are the categories
that distinguish kohaku from a generic wallet:

* **Privacy** — kohaku integrates Privacy Pools so users can route value
  through a shielded address without leaking the link to the source.
  Skills here normalize the multi-step shape (deposit → wait → withdraw
  to fresh address) so the user never has to think about it.

* **Hygiene** — most wallets accumulate stale ERC-20 approvals,
  long-lived addresses with too much linkage, and dust. The hygiene
  skills are deliberately discoverable in the chat ("revoke all my
  USDC approvals", "give me a fresh address") so the user can act on
  them without leaving the wallet.

The two compose: `shield-eth` → `fresh-address` → `unshield-eth → that
address` is the canonical "rotate" workflow.
