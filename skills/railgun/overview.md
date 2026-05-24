# railgun — overview

## What it is

RAILGUN is a zero-knowledge shielding system for ERC-20 and native ETH
on EVM. A user "shields" tokens into a smart-wallet contract; once
inside, balances and transfers are hidden inside a UTXO-style note set.
The user can later "unshield" back to a public Ethereum address, or
"transfer" privately to another RAILGUN address.

RAILGUN addresses are **not** Ethereum addresses. They are encoded with
a `0zk` prefix (the SDK type alias is `RailgunAddress = `0zk${string}`).
The agent must never confuse a `0zk…` recipient with a 20-byte `0x…`
address: shielding/unshielding crosses the boundary, private transfer
does not.

## How RAILGUN fits Kohaku

| Layer | Where it lives |
|---|---|
| Witness generation, plugin state, broadcaster | `@kohaku-eth/railgun` (npm `0.0.1-alpha.12`, installed alpha is `0.0.1-alpha.21`) inside the kohaku-bridge Node sidecar |
| Calldata decode + simulation | Lean daemon (`tx.decodeIntent`, `tx.simulate`) |
| User confirmation | TUI `ConfirmGate` |
| Signing | TPM-rooted `eoa.send` / `r1.send*` after gate |
| Network policy classification | `Privacy.NetworkPolicy` purpose `shieldedRead` / `shieldedBroadcast` |

The agent's job is **always** to invoke the SDK function that produces
the prepared transaction, then surface that transaction through the
pre-sign pipeline. The agent never builds shield/unshield/transfer
calldata by hand. The SDK already handles the EIP-7702 + EIP-4337 +
paymaster wiring; bypassing it is a footgun (see `security.md`).

## SDK surface the agent uses

Source: `bridge/node_modules/@kohaku-eth/railgun/dist/sdk/plugin.d.ts`.

Initialization:

* `createRailgunPlugin(host, config?)` — load or create a plugin
  instance, restoring persisted state from `host.storage` when
  available.
* `ensureInitialized(wasmInput?)` — load the WASM circuit bindings
  once per process.

Reads:

* `RailgunPlugin#instanceId()` — returns the user's `0zk…` RailgunAddress.
* `RailgunPlugin#balance(assets)` — implicit sync + per-asset balance.

Calldata prep (all artifacts MUST be re-decoded by the Lean daemon
before signing):

* `prepareShield(asset)` / `prepareShieldMulti(tokens)` — produce raw
  `TxData[]`; user signs and sends directly (this is the boundary-
  crossing op).
* `prepareUnshield(token, to)` / `prepareUnshieldMulti(tokens, to)` —
  produce an `RGPrivateOperation` (proved tx bundled with a selected
  broadcaster).
* `prepareTransfer(token, toRailgunAddress)` /
  `prepareTransferMulti(tokens, toRailgunAddress)` — same shape as
  unshield, but the recipient is a `0zk…` address.

Broadcast:

* `RailgunPlugin#broadcast(op)` — relay a proved tx through the
  selected Waku broadcaster. The operation is single-use; on failure,
  rebuild from scratch.

## What the agent CAN propose

* Shield ETH or an ERC-20 (boundary-crossing into RAILGUN).
* Private transfer between two `0zk…` RailgunAddresses.
* Unshield to a public `0x…` recipient.

## What the agent CANNOT do

* **Draft raw RAILGUN calldata.** The SDK is the only entry point. If
  the SDK cannot satisfy a request, the agent declines rather than
  rolling its own ABI encoding.
* **Use a custom EIP-7702 delegate.** Per repo memory, the RAILGUN
  paymaster rejects custom delegates. The SDK already targets the
  expected delegate (hardcoded implementation address
  `0x304a…4b4c` in the upstream wiring), EntryPoint 0.8, and the
  RAILGUN POI URL. Replacing any of those is out of scope.
* **Treat freshly-shielded balances as spendable.** RAILGUN's
  Proof-of-Innocence (POI) is asynchronous; new shields are
  `ShieldBlocked` or `ProofSubmitted` for minutes to hours before
  they become `Valid` and spendable in transfers/unshields.

## Bridge wiring status

The bridge's `listProtocols` JSON-RPC currently reports railgun as
`"stub"`. The `@kohaku-eth/railgun` package is installed in
`bridge/node_modules/` and importable, but no `railgun.*` JSON-RPC
methods are wired in `bridge.mjs` yet. Until they are, the agent
should mention this state when a user asks for a railgun action, and
fall back to "the SDK exists, the wallet bridge does not yet expose it".

## Citations

* SDK package — `@kohaku-eth/railgun` `0.0.1-alpha.12` (declared in
  `bridge/package.json`).
* SDK types — `bridge/node_modules/@kohaku-eth/railgun/dist/sdk/plugin.d.ts`,
  `dist/sdk/lib.d.ts`, `dist/pkg/index.d.ts`.
* Contracts — `contracts.json` (Smart Wallet 2.0 proxy + logic,
  mainnet only). ABI files in `abi/` are stubs (`TODO(curator):`);
  the SDK is the source of truth.
* Upstream — <https://github.com/ethereum/kohaku>,
  <https://docs.railgun.org>.
