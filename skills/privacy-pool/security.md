# privacy-pool — security

## Trust model

The `@kohaku-eth/privacy-pools` SDK runs inside the kohaku-bridge
Node sidecar. The sidecar is **untrusted** — it computes the
zero-knowledge proof and selects the relayer, but every transaction
it returns is re-decoded by the Lean daemon. Specifically:

* `prepareShield` returns a `PPv1PublicOperation` whose `txns:
  TxData[]` are decoded, simulated, and gated independently.
* `prepareUnshield` returns a `PPv1PrivateOperation` whose `txData`
  is decoded and gated the same way. The relayer is selected by the
  SDK; the daemon does not blindly trust the relayer's fee quote.
* `broadcaster.broadcast(op)` is only invoked after the user
  confirms the gate. The op is single-use.

## Two secret stores

Privacy Pools requires its **own** mnemonic, separate from the EOA
mnemonic the daemon uses for signing. That separation is
non-negotiable: it ensures the EOA private key is never derivable
from the privacy-pools commitment secrets, and vice versa.

* EOA signing: TPM-rooted or local mnemonic, as configured.
* Privacy-pools spending: `LEANKOHAKU_PP_MNEMONIC`, used only inside
  the kohaku-bridge sidecar.

The bridge refuses to start (`buildHost` throws) if either is missing.

## Association Set Provider (ASP) gating

A deposit is **not immediately withdrawable**. The ASP (OxBow on
mainnet/Sepolia) batch-processes deposits and publishes an updated
association tree; until the deposit's commitment appears in that
tree, the SDK's `prepareUnshield` throws `"Leaf not found in the
leaves array"`.

* On Sepolia, OxBow processes in batches and can be hours behind.
  The bridge already surfaces this with a user-friendly message
  (see `shieldedPrepareWithdraw`).
* On mainnet, the cadence is shorter but still asynchronous.
* The agent must mention this delay when the user asks "why can't
  I withdraw right after depositing".

If the user has a deposit that the ASP refuses to approve at all
(e.g. flagged as bad-source), the only escape is **ragequit**: the
SDK's `ragequit(labels[])` produces a `PPv1PublicOperation` that
exits the commitment back to the depositor's public address, paying
on-chain gas in the clear. Ragequit is a privacy regression — the
agent surfaces this trade-off before proposing it.

## Sentinel ETH address

ETH inside Privacy Pools is keyed by the literal address
`0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee` (`E_ADDRESS`). The
agent must NEVER interpret this as a contract; passing the literal
zero address `0x000…000` to the SDK silently mismatches.

## Recipient-redirect awareness

`prepareUnshield(assetAmount, recipient)` allows the recipient
address to be different from the depositor. This is the privacy
feature: a user can deposit from address A and withdraw to address
B. The agent must:

* Surface the recipient address back to the user in the ConfirmGate
  so they confirm it matches their intent.
* Never silently default the recipient to the user's current
  account — that defeats the privacy.

## Relayer fees

The `PPv1Broadcaster` (Fastrelay by default) charges a fee in
basis points (`baseFeeBPS`, dynamic `feeBPS`). The SDK exposes
`getQuote` on the relayer client; the bridge does not yet surface
the quote to the user before broadcast. **TODO(curator):** wire a
pre-confirmation surface that shows the relayer's
`IQuoteResponse.feeBPS` and `detail.relayTxCost` so the user can
sanity-check.

## Persisted state

The plugin's redux store (deposits, withdrawals, ASP leaves, pool
leaves, sync cursor) is serialized to
`LEANKOHAKU_PP_STATE_PATH` after every state change. Loss of this
file forces a full chain resync (the bridge ships
`ppv1-sepolia-state.json` / `ppv1-mainnet-state.json` as bundled
warm-start state). The file is non-secret but expensive to rebuild.

## What the SDK does NOT verify

* That the user intends the recipient address — ConfirmGate's job.
* That the relayer's fee is reasonable — the agent should surface
  the quote so the user can reject.
* That the ASP is the correct ASP — the operator configures it once
  via the bridge env; the agent does not vary it.
* That the user is in a jurisdiction that permits the operation —
  legal scope is the user's, not the wallet's.

## Refusal triggers

* User asks the agent to "build the Privacy Pools calldata directly"
  — refuse, point at the SDK.
* User asks to withdraw to a `0zk…` address — refuse, that is a
  RAILGUN-style transfer and Privacy Pools does not implement it.
* User asks to spend a deposit the SDK reports as unapproved when
  the action is unshield — refuse, wait for ASP (or propose
  ragequit with the privacy-regression caveat).
* User asks to bypass the ASP — refuse, ASP gating is the
  protocol's compliance posture and the SDK enforces it.
