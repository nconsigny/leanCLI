---
name: register-ens-name
description: Register an .eth name on ENS through the commit/reveal flow. Two transactions separated by a ~60-second commit-age gate; the wallet handles the timing so the user only sees two signing prompts.
category: identity
risk: medium
requires:
  daemonRpcs:
    - ens.prepareCommit
    - ens.prepareRegister
    - tx.simulate
    - tx.decodeIntent
  wallets:
    - eoa
    - r1
notes:
  - "ENS uses commit/reveal to prevent frontrunning of name purchases. Skipping the commit step (or revealing before the commit-age elapses) reverts."
  - "Commitment includes: name, owner, duration, secret (32 random bytes), resolver, data[], reverseRecord, ownerControlledFuses. The wallet persists these between the two txs so the user's register call matches what they committed to."
  - "Duration is denominated in seconds. RuleParser captures it as years (default 1); the encoder multiplies by 31_536_000."
  - "If the wallet drops between commit and register, the secret is lost and the commitment is unredeemable — the user pays gas for nothing. We surface this risk before the commit tx."
---

# register-ens-name — ENS commit/reveal registration

## When to use

* `register vitalik.eth`
* `register vitalik.eth for 2 years`
* `register newname.eth for 5 years from leanWallet`

## Status

Chat-recognition is wired through `RuleParser.matchEns`:
`Intent.ensRegister` is produced with the user's name + duration. The
two-transaction orchestration (commit → wait → register) is **not yet
implemented daemon-side** — that's the open follow-up tracked by
issue (TODO: open).

## Pipeline (target shape)

1. User types `register vitalik.eth for 2 years`.
2. RuleParser yields `.ensRegister` with `name=vitalik.eth`,
   `durationYears=2`.
3. Skill card asks the user:
   - Confirm name + duration + owner (defaults to current wallet)
   - Note the commit gas cost is non-refundable if the user drops out
4. Daemon `ens.prepareCommit` builds the commitment hash + persists
   the secret keyed by (chainId, name, owner).
5. First tx: `commit(commitment)` → flows through
   `tx.decodeIntent → tx.simulate → ConfirmGate → eoa.send`.
6. Skill card displays the commit-age countdown (~60s mainnet) and
   prompts the user when it's safe to proceed.
7. Daemon `ens.prepareRegister` loads the persisted secret + arguments
   and builds the `register(...)` calldata.
8. Second tx: `register(...)` → same gate, signed by the user.

## Why not bundle both txs as a single intent?

The 60-second commit-age gate is wall-clock. Modelling it as a single
intent would either:
- Force the wallet to block on the gate (bad UX, stale RPC connections)
- Or require a two-step Intent with state that survives daemon restarts

The skill card explicitly walks the user through both steps so they
understand the gas charged on commit isn't lost if they back out
before register (the commit is wasted but no on-chain damage is done).

## Renew is one-shot

`renew vitalik.eth for 1 year` produces `Intent.ensRenew` and goes
through a single `renew(name, duration)` tx — no commit phase.

## Open follow-ups (clearly bounded)

1. `LeanCli/Ens/Prepare.lean` — analogous to `Swap/Prepare.lean`
   and `Aave/Prepare.lean`. Pure IO orchestration; computes
   `commitment = keccak256(abi.encode(name, owner, duration, secret,
   resolver, data, reverseRecord, ownerControlledFuses))` via the
   existing `c/hacl_helpers/` Keccak path.
2. `LeanCli/Daemon/EnsState.lean` — SQLite-backed persistence of
   pending commitments keyed by `(chainId, name, owner)`. Mirrors
   `Agent/Session.lean`'s shape.
3. Daemon RPCs `ens.prepareCommit` + `ens.prepareRegister` — wire
   through `Server.lean`.
4. TUI screen for the commit-age countdown (`tui/src/screens/EnsRegisterFlow.tsx`).
