# railgun — interactions

Every recipe below assumes the agent has the `@kohaku-eth/railgun` SDK
loaded via the kohaku-bridge sidecar. The bridge does not yet expose
`railgun.*` JSON-RPC methods (see `overview.md`); the recipes describe
the intended flow so that when the bridge is wired the agent already
knows the shape. SDK functions in brackets reference
`bridge/node_modules/@kohaku-eth/railgun/dist/sdk/plugin.d.ts`.

## Shield ETH (public → shielded, boundary-crossing)

1. `[SDK] createRailgunPlugin(host, config?)` — load or create the
   plugin instance. The plugin's `host.storage` carries persisted
   UTXO state across sidecar invocations.
2. `[SDK] RailgunPlugin#instanceId()` — surface the user's `0zk…`
   RailgunAddress so they see the shielded destination.
3. `[SDK] RailgunPlugin#prepareShield({ __type: "erc20", contract: <asset>, amount })`
   returns `TxData[]`.
4. **Lean daemon** — for each `TxData`: `tx.decodeIntent` →
   `tx.simulate` (eth_call + estimateGas + optional debug_traceCall) →
   `ConfirmGate` shows the decoded intent and resulting token
   movements.
5. **On user confirmation** — `eoa.send` (TPM-rooted signing) for
   each tx in the returned array, in order.
6. Surface POI delay: shielded balances do NOT become spendable
   immediately. The user is told to expect minutes-to-hours before
   `prepareTransfer` / `prepareUnshield` will succeed with this
   shield as a source.

## Shield an ERC-20

Same as "Shield ETH" but the asset is a real ERC-20 contract
address. The SDK's `prepareShield` handles the approval/permit
internally; if a separate approval tx is required it appears as one
of the entries in the returned `TxData[]` — each is gated
independently by `ConfirmGate`.

## Private transfer (`0zk` → `0zk`, stays shielded)

1. `[SDK] createRailgunPlugin(host)` — load.
2. `[SDK] RailgunPlugin#balance([asset])` — confirm the user has
   POI-Valid balance ≥ requested amount.
3. `[SDK] RailgunPlugin#prepareTransfer(assetAmount, toRailgunAddress)`
   — returns `RGPrivateOperation` (proved tx + broadcaster).
4. **Lean daemon** — decode `op.builder.txData`, simulate, gate.
5. **On confirmation** — `[SDK] RailgunPlugin#broadcast(op)` relays
   through the bundler's Waku broadcaster. The `op` is consumed; on
   failure, restart from step 3.

## Unshield (`0zk` → `0x`, boundary-crossing)

1. `[SDK] createRailgunPlugin(host)`.
2. `[SDK] RailgunPlugin#balance([asset])` — verify POI-Valid balance.
3. `[SDK] RailgunPlugin#prepareUnshield(assetAmount, toEthAddress)`
   — returns `RGPrivateOperation`.
4. **Lean daemon** — decode the boundary-crossing tx that pays the
   unshielded amount to `toEthAddress`. The ConfirmGate must show
   the recipient address back to the user.
5. **On confirmation** — `[SDK] RailgunPlugin#broadcast(op)`.

## Multi-asset variants

`prepareShieldMulti(tokens[])`, `prepareTransferMulti(tokens[], to)`,
and `prepareUnshieldMulti(tokens[], to)` exist for batched
operations. Decode + simulate + gate runs **per resulting transaction**,
not per logical batch — the user confirms each on-chain action
independently.

## Internal signers (consolidation)

When recovered funds are spread across multiple RAILGUN keypairs:

1. `[SDK] addInternalSigner(spendingKey, viewingKey)` — adds a
   secondary signer to the plugin's signer pool.
2. The plugin's `buildMultiSigner` automatically drains UTXOs across
   all signers (primary first, then internal signers in insertion
   order) to satisfy `prepareTransfer` / `prepareUnshield`.
3. State (including the new signer's keys) is persisted to
   `host.storage` after `addInternalSigner` returns.

This is a recovery / consolidation flow; the agent surfaces it only
on explicit user request.

## Decoding incoming RAILGUN calldata

If the user pastes raw calldata or asks "what is this transaction":

1. The decoder uses the on-chain ABI in `abi/` (currently stubs;
   the SDK is canonical for prep, the on-chain ABI for decode).
2. The agent identifies the function (e.g. `shield`, `unshield`,
   `transact`) and explains it.
3. The agent does NOT propose to sign such a tx; if the user wants
   to perform a comparable action, the agent re-builds via the SDK
   so the daemon's pre-sign pipeline runs.

## Anti-patterns

* Drafting RAILGUN calldata from the on-chain ABI without going
  through the SDK — refused.
* Calling `eoa.send` directly on the output of the SDK without
  first going through `decodeIntent` + `simulate` + `ConfirmGate` —
  forbidden; reuse `SendRawFlow`.
* Using a custom EIP-7702 delegate — the paymaster rejects.
* Treating a freshly shielded balance as spendable inside the
  shielded set — POI gating delays this.
