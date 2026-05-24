# privacy-pool — overview

## What it is

Privacy Pools v1 (0xbow) is a compliant-by-design shielded pool on
Ethereum. Users deposit through an `Entrypoint` contract; each
deposit is committed into a Merkle tree, and the depositor receives
a secret note (`nullifier`, `salt`, `precommitment`,
`nullifierHash`). Withdrawal requires a zero-knowledge proof that the
note is in the pool's Merkle tree **and** that its commitment is in
the **Association Set Provider (ASP)** tree — the latter is the
mechanism that lets the protocol exclude commitments associated with
known-bad sources without revealing which depositor any given
withdrawer is.

There is no native-Ethereum "wrap"; ETH is handled via the sentinel
asset address `0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee` (the
`E_ADDRESS` constant the SDK re-exports).

## How Privacy Pools fits Kohaku

| Layer | Where it lives |
|---|---|
| Witness generation, ASP tree fetch, relayer client | `@kohaku-eth/privacy-pools` (`0.0.2-alpha.9`) inside the kohaku-bridge Node sidecar |
| Calldata decode + simulation | Lean daemon (`tx.decodeIntent`, `tx.simulate`) |
| User confirmation | TUI `ConfirmGate` |
| Signing | TPM-rooted `eoa.send` after gate |
| Network policy | `Privacy.NetworkPolicy` purpose `shieldedRead` / `shieldedBroadcast` |
| Storage | File-backed `host.storage` under `LEANKOHAKU_PP_STORAGE_PATH` so the per-account secret↔commitment map survives across sidecar invocations |
| Secret derivation | `LEANKOHAKU_PP_MNEMONIC` — a dedicated mnemonic separate from the EOA mnemonic |

The bridge wires this skill **live** on chains `[11155111, 1]` per
`bridge.mjs:listProtocols`. Concretely the bridge exposes:

* `shielded.balance`
* `shielded.prepareDeposit`
* `shielded.prepareWithdraw`
* `shielded.unshieldDrain` (loops `prepareUnshield` + broadcast to
  drain a target larger than any single note — v1 has no
  `prepareUnshieldMulti`)

Every one of those calls into the SDK; none of them hand-builds
calldata.

## SDK surface the agent uses

Source: `bridge/node_modules/@kohaku-eth/privacy-pools/dist/index.d.ts`.

Initialization:

* `createPPv1Plugin(host, { accountIndex, entrypoint, broadcasterUrl,
  aspServiceFactory?, initialState? })` — construct the plugin. The
  bridge already wires this in `buildPlugin`.
* `PrivacyPoolsV1_0xBow` — deployment table keyed by chainId
  (`1`, `11155111`). The bridge reads `entrypoint` from here.
* `OxBowAspService({ network, aspUrl })` — Sepolia ASP factory used
  by the bridge when `chainId === 11155111`.
* `IPFSAspService` — alternative ASP source.
* `SecretManager({ host, accountIndex })` — derives deposit /
  withdrawal secrets from the keystore (default factory).

Reads:

* `PrivacyPoolsV1Protocol#instanceId()` — returns `"0x1"` for v1.
* `PrivacyPoolsV1Protocol#balance(assets?)` — array of approved /
  unapproved balances per asset.
* `PrivacyPoolsV1Protocol#notes(assets?, includeSpent?)` — the per-
  deposit note list (`label`, `precommitment`, `value`, `balance`,
  `approved`, …). Used by `unshieldDrain` to pick the biggest
  approved note each iteration.
* `PrivacyPoolsV1Protocol#sync()` — syncs the local store against
  on-chain events (called implicitly by balance() per upstream
  contract; the bridge calls it explicitly for clarity).
* `PrivacyPoolsV1Protocol#dumpState()` — serializes the redux store
  for persistence; the bridge atomically writes it to
  `LEANKOHAKU_PP_STATE_PATH` after every state change.

Calldata prep (every artifact MUST be re-decoded by the Lean daemon
before signing):

* `prepareShield(assetAmount)` — returns a `PPv1PublicOperation`
  whose `txns: TxData[]` go through the pre-sign pipeline.
* `prepareUnshield(assetAmount, recipientEthAddress)` — returns a
  `PPv1PrivateOperation` (relay-ready). Throws `"Leaf not found"`
  when the deposit's commitment is not yet in the ASP tree — the
  bridge surfaces this as a user-readable wait-for-OxBow-ASP error.
* `ragequit(labels[])` — exits a note set when ASP refuses
  approval; returns a `PPv1PublicOperation`.

Broadcast:

* `createPPv1Broadcaster(host, { broadcasterUrl })` returns a
  broadcaster instance; the bridge defaults
  `broadcasterUrl = "https://fastrelay.xyz/relayer"` (overridable
  via `LEANKOHAKU_PP_BROADCASTER_URL`).
* `broadcaster.broadcast(privateOp)` relays through the fastrelay
  endpoint.

## What the agent CAN propose

* Deposit ETH or supported ERC-20 into the pool (via
  `prepareShield`).
* Withdraw to a public Ethereum address (via `prepareUnshield`,
  optionally chained for drain).
* Inspect pool state (`balance`, `notes`) without producing any
  transaction.
* Ragequit a stuck commitment (SDK supports it; bridge does not
  yet wire `shielded.ragequit`).

## What the agent CANNOT do

* **Draft raw Privacy-Pools calldata.** The SDK is the only entry
  point; the on-chain ABI in `abi/Entrypoint.json` is for decode
  only.
* **Withdraw a deposit whose commitment is not in the ASP tree.**
  OxBow processes approvals in batches; on Sepolia this can take
  hours. The bridge already surfaces the SDK's `"Leaf not found"`
  error as a wait-for-ASP message.
* **Use a different ASP than the configured OxBow service** without
  an operator-side override. The agent never picks an ASP at runtime.

## Bridge wiring status

`bridge/bridge.mjs:listProtocols` reports privacy-pools as `"live"`
on chains `[11155111, 1]`. The wired JSON-RPC methods are listed in
`interactions.md`.

## Citations

* SDK package — `@kohaku-eth/privacy-pools` `0.0.2-alpha.9` (declared
  in `bridge/package.json`).
* SDK types — `bridge/node_modules/@kohaku-eth/privacy-pools/dist/index.d.ts`.
* Bridge wiring — `bridge/bridge.mjs` (`buildPlugin`, `shieldedBalance`,
  `shieldedPrepareDeposit`, `shieldedPrepareWithdraw`,
  `shieldedUnshieldDrain`).
* Contracts — `contracts.json` (mainnet Entrypoint, Sepolia
  Entrypoint). ABI in `abi/Entrypoint.json` is a `TODO(curator):`
  stub; the SDK is the source of truth for prep.
* Upstream — <https://github.com/ethereum/kohaku>,
  <https://docs.privacypools.com>.
