# privacy-pool — interactions

Every recipe below uses the `@kohaku-eth/privacy-pools` SDK as the
calldata source. The leancli-bridge sidecar exposes the SDK over
JSON-RPC; the Lean daemon re-validates every returned transaction
through `decode_calldata → simulate → ConfirmGate` before any
signature. SDK functions in brackets reference
`bridge/node_modules/@kohaku-eth/privacy-pools/dist/index.d.ts`;
bridge methods in `monospace` reference `bridge/bridge.mjs`.

## Wired bridge methods

| Bridge JSON-RPC | SDK call(s) | What it returns |
|---|---|---|
| `shielded.balance` | `sync() → balance([ethAsset])` + `dumpState()` | per-asset approved/unapproved balances |
| `shielded.prepareDeposit` | `sync() → prepareShield({ asset, amount })` | `PPv1PublicOperation.txns: TxData[]` |
| `shielded.prepareWithdraw` | `sync() → prepareUnshield({ asset, amount }, recipient)` then `createPPv1Broadcaster.broadcast(privateOp)` | relay result with txHash |
| `shielded.unshieldDrain` | loop `notes([ethAsset])` → `prepareUnshield(chunk, recipient)` → `broadcaster.broadcast(op)` until target reached | per-iteration relay results |
| `ping`, `version`, `listProtocols` | none (local introspection) | metadata only |

## Deposit ETH

1. **User intent**: deposit `N` ETH into the 0xbow pool from the
   default account.
2. Agent calls `shielded.prepareDeposit` (JSON-RPC) with
   `{ amountEth: "<N>" }` or `{ amountWei: "<wei>" }`.
3. Bridge: `[SDK] sync()` → `[SDK] prepareShield({ asset: ethAsset(), amount })`.
4. Bridge returns `{ chainId, asset, amountWei, txns }`.
5. **Lean daemon** — for each `TxData`: `tx.decodeIntent` →
   `tx.simulate` → `ConfirmGate` shows the deposit amount,
   destination Entrypoint, and the user's depositor address.
6. **On confirmation** — `eoa.send` (TPM-rooted) for each tx.
7. Bridge `[SDK] dumpState()` is persisted to
   `LEANCLI_PP_STATE_PATH` so the deposit's secret↔commitment
   map survives.
8. Agent surfaces: the deposit is now waiting for ASP approval
   (minutes to hours on Sepolia) before it can be withdrawn.

## Deposit ERC-20

Same flow as "Deposit ETH" but the asset is a real ERC-20 address.
The SDK may return an `approve` tx as an earlier entry in `txns[]`;
each is gated independently by `ConfirmGate`.

## Withdraw (single note)

1. **User intent**: withdraw `N` ETH to `recipient` (a public `0x…`
   address that may or may not equal the depositor).
2. Agent calls `shielded.prepareWithdraw` with `{ amountWei,
   recipient }`.
3. Bridge: `[SDK] sync()` → `[SDK] prepareUnshield({ asset:
   ethAsset(), amount }, recipient)`.
4. **If SDK throws `"Leaf not found"`** — bridge re-throws with a
   user-readable wait-for-ASP message; the agent surfaces that to
   the user and refuses to retry until time has passed.
5. Otherwise bridge gets a `PPv1PrivateOperation`. **TODO(curator)**:
   the bridge today calls `broadcaster.broadcast(privateOp)`
   directly after `prepareUnshield`. The Lean daemon must decode
   `privateOp.txData` and run `ConfirmGate` BEFORE broadcast — that
   ordering belongs in `LeanCli/Privacy/Bridge.lean` and the
   `shielded.prepareWithdraw` handler. Document it here so the
   agent flow does not assume the bridge is the gate.
6. Bridge `[SDK] dumpState()` is persisted.

## Withdraw (drain larger than any single note)

1. **User intent**: withdraw `N` ETH to `recipient`, where `N`
   exceeds the size of any individual approved note.
2. Agent calls `shielded.unshieldDrain` with `{ amountWei,
   recipient }`.
3. Bridge: loops while `remaining > 0`:
   * `[SDK] notes([ethAsset()])` → filter approved + non-zero,
     sort descending by balance.
   * `chunk = min(remaining, biggestApprovedNote)`.
   * `[SDK] prepareUnshield({ asset, amount: chunk }, recipient)`
     (handle `"Leaf not found"` as above).
   * `[SDK] broadcaster.broadcast(op)` → record relay result.
4. **Each iteration's** `op.txData` must be gated by `ConfirmGate`
   in the daemon — same TODO as above.
5. On exhaustion, bridge returns `{ targetWei, drainedWei,
   iterations, sent[] }`.

## Inspect balance / notes

1. Agent calls `shielded.balance` with no params.
2. Bridge: `[SDK] sync()` → `[SDK] balance([ethAsset()])` →
   `[SDK] dumpState()`.
3. Bridge returns approved + unapproved bigints. Agent surfaces
   approved as "spendable", unapproved as "waiting for ASP".

`notes()` is not yet exposed as a top-level JSON-RPC method; the
agent reads it transitively through `shielded.unshieldDrain`'s
iteration output. **TODO(curator):** expose `shielded.notes` so the
agent can answer "show me my notes" without proposing a withdrawal.

## Ragequit (escape from ASP refusal)

* The SDK supports `ragequit(labels[])` returning a
  `PPv1PublicOperation`. The bridge does not yet wire this; if a
  user has a stuck deposit, the only path today is to wait for ASP
  or manually invoke the SDK outside the bridge.
* When wired, the agent must surface that ragequit is a
  **privacy regression** — the exit pays public gas from the
  depositor's address.

## Decoding incoming Privacy Pools calldata

If the user pastes raw calldata or asks "what is this transaction":

1. The decoder uses the on-chain ABI in `abi/Entrypoint.json`
   (TODO stub — `decode_calldata` falls back to 4byte directory).
2. The agent identifies the function (`deposit`, `withdraw`, …)
   and explains it.
3. The agent does NOT propose to sign such a tx; if the user wants
   a comparable action, the agent re-builds via the SDK so the
   daemon's pre-sign pipeline runs.

## Anti-patterns

* Drafting Privacy-Pools calldata from the Entrypoint ABI without
  going through the SDK — refused.
* Reusing the EOA mnemonic as the privacy-pools mnemonic — refused
  by the bridge.
* Broadcasting a `PPv1PrivateOperation` without gating its
  `txData` through `ConfirmGate` — TODO to enforce in the daemon
  bridge layer; agent must not skip the gate.
* Treating an unapproved note as withdrawable — the SDK throws and
  the agent must wait for ASP or surface ragequit.
