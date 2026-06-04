# railgun — security

## Trust model

The `@kohaku-eth/railgun` SDK runs inside the leancli-bridge Node
sidecar. That sidecar is **untrusted** by the same model as every
other bridge: snarkjs / WASM / Waku / libp2p ride entirely on the
sidecar side, but every output that crosses back into the Lean
daemon is re-validated. In particular:

* `prepareShield` returns raw `TxData[]` — the Lean daemon parses
  the typed-tx, ABI-decodes the calldata, and `tx.simulate`s before
  any signature. Shielded calldata is opaque to outside observers,
  not to the user signing it.
* `prepareUnshield` / `prepareTransfer` return an
  `RGPrivateOperation` whose `builder` is the SNARK-proved
  transaction. The daemon treats `op.builder.txData` the same way
  it treats any other prepared tx: decode → simulate → ConfirmGate.
* `broadcast(op)` is only invoked after the user has confirmed the
  decoded intent. The op is single-use; replay-on-failure means
  rebuilding from scratch.

## Address-type confusion

A RAILGUN address is `0zk` + base32 payload. An Ethereum address is
`0x` + 40 hex characters. They are not interchangeable.

* `prepareShield` takes a public `AssetAmount` only; the recipient
  is implicit (it is the user's own `0zk…`).
* `prepareUnshield(token, to)` takes a public `to: \`0x${string}\``
  — boundary-crossing out of the shielded set.
* `prepareTransfer(token, to)` takes a `to: RailgunAddress` (`0zk…`)
  — stays inside the shielded set.

If a tool call mixes these up (e.g. tries to unshield to a `0zk…`),
the agent refuses and asks the user to clarify. Confusing the two
is the most common operator footgun.

## Proof of Innocence (POI) gating

RAILGUN enforces a Proof-of-Innocence step asynchronously. A fresh
shield is not immediately spendable from inside the shielded set —
its `PoiStatus` starts as `ShieldBlocked` or `ProofSubmitted` and
flips to `Valid` only after the upstream POI node accepts it. The
SDK's `PoiStatus` enum (`Valid | ShieldBlocked | ProofSubmitted |
Missing`) is the source of truth.

Operational consequence: a user can shield and then be unable to
unshield or transfer for **minutes to hours**. The agent surfaces
this delay before signing a shield. If a user asks "why is my
shielded balance unspendable", the answer is almost always POI.

## Paymaster / 7702 constraints

RAILGUN's bundler path uses EntryPoint 0.8 + a paymaster + an
EIP-7702 delegating account. The hardcoded RAILGUN implementation
address (`0x304a…4b4c` per repo memory) is what the paymaster
expects.

* **The agent does not propose custom 7702 delegates for RAILGUN
  operations.** The paymaster rejects them, the operation fails,
  and the user is left with a UserOperation receipt but no state
  change.
* The SDK's `RailgunPluginConfig.bundler` and
  `BundlerConfig.delegating_account` exist for advanced wiring; the
  agent should leave them at the SDK defaults unless an operator
  explicitly overrides them in configuration.

## Persisted state

The plugin serializes its UTXO set, scanned-commitment cursor, and
internal-signer keys to `host.storage` after every sync and signer
addition. The bridge backs that with a file under
`LEANCLI_PP_STORAGE_PATH` (the storage path is shared with
privacy-pools today; railgun gets its own subpath when wired).

Loss of this state file means the user's `0zk…` is recoverable from
the spending key, but the UTXO map has to be rebuilt by replaying
the chain. Treat the storage path as **non-secret but high-value
operational state**.

## What the SDK does NOT verify

* That the user actually wants to shield this amount — that is the
  ConfirmGate's job.
* That the recipient `0x…` is the user's intended public address —
  the user reads it back from the ConfirmGate's decoded view.
* That the relayer's fee quote is reasonable. RAILGUN's broadcaster
  is a Waku relay; the agent should surface the broadcaster URL
  (`RailgunPlugin.__broadcasterUrl` analogue when wired) so the
  user can confirm.

## Refusal triggers

* User asks the agent to "build the RAILGUN calldata directly" —
  refuse, point at the SDK.
* User asks to unshield to a `0zk…` address — refuse, that is a
  transfer, not an unshield.
* User asks to spend a balance that the SDK reports as
  POI-`Missing` / `ShieldBlocked` / `ProofSubmitted` — refuse, wait
  for POI.
* User asks to deploy a custom 7702 delegate for the RAILGUN flow —
  refuse, paymaster will reject.
