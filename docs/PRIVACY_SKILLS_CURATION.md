# Privacy skills curation (Phase 1b follow-up)

This doc records the curation of `skills/{railgun,privacy-pool,tornado-cash}/`
content. It complements `docs/PROTOCOL_SKILLS_CURATION.md` (the six DeFi
protocol skills) with the three privacy-protocol skills Phase 1b also
scaffolded.

The mandate that drove these three is unusual: **the agent must always
direct callers to use the `@kohaku-eth/*` SDK packages and never draft
raw shielded calldata**. Two of the three skills (railgun, privacy-pool)
do have an upstream Kohaku SDK; the third (tornado-cash) does not — that
asymmetry shapes the curation.

## Approach

1. Enumerate the public SDK surface of `@kohaku-eth/railgun` and
   `@kohaku-eth/privacy-pools` directly from the installed package
   under `bridge/node_modules/@kohaku-eth/`. Every function name in
   the skill files traces back to a `.d.ts` declaration in that tree.
   No invention.
2. Cross-reference each SDK function against the actual call sites in
   `bridge/bridge.mjs` so the skill content reflects what is wired vs.
   what is "SDK-available, bridge does not invoke yet". The bridge
   wires the privacy-pools surface aggressively (deposit/unshield/notes/
   sync/balance) and does not yet wire railgun.
3. For tornado-cash: no `@kohaku-eth/tornado-cash` package ships yet
   (upstream Kohaku has not landed one). Drafting Tornado Cash
   transactions through the agent is **coming soon**. The skill is
   loaded today for decode context — the agent recognizes Tornado Cash
   calldata in incoming flows and explains it through ConfirmGate.
4. Trust model unchanged: every privacy operation still flows through
   `decode_calldata → simulate → ConfirmGate` before any signing. The
   SDK helps generate calldata; it does not bypass the gate. Shielded
   calldata is opaque to outside observers, not to the user signing it.

## SDK package versions

These come from `bridge/package.json` exactly (the declared dependency
range). The installed transitive resolutions under
`bridge/node_modules/@kohaku-eth/` can be newer alpha drops — when that
is the case it is called out below; the skill content cites the
`bridge/package.json` pinned version so the user-facing material does
not change every time `pnpm install` resolves a new alpha.

| SDK package | bridge/package.json | installed in bridge/node_modules | bridge.mjs uses? |
|---|---|---|---|
| `@kohaku-eth/plugins` | `0.0.1-alpha.7` | `0.0.1-alpha.8` | indirectly (host / provider plumbing) |
| `@kohaku-eth/railgun` | `0.0.1-alpha.12` | `0.0.1-alpha.21` | no — present, not yet wired |
| `@kohaku-eth/privacy-pools` | `0.0.2-alpha.9` | `0.0.2-alpha.9` | yes — primary surface |
| `@kohaku-eth/provider` | (transitive) | `0.1.0-alpha.7` / `.8` | yes (`provider.viem`) |

Both packages remain `0.0.x-alpha`. Surface drift between drops is
expected; skill content treats SDK calls as the canonical contract and
defers raw-calldata details to the underlying contract ABI files.

## SDK API enumeration

### `@kohaku-eth/railgun` (entry `dist/sdk/lib.js`)

Source files: `dist/sdk/lib.d.ts`, `dist/sdk/plugin.d.ts`,
`dist/pkg/index.d.ts` (WASM bindings re-exported).

| Function / class | Source file | Called by `bridge.mjs`? |
|---|---|---|
| `createRailgunPlugin(host, config?)` | `dist/sdk/plugin.d.ts` | no |
| `ensureInitialized(wasmInput?)` | `dist/sdk/lib.d.ts` | no |
| `RailgunPlugin#instanceId()` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#balance(assets)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#prepareShield(asset)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#prepareShieldMulti(tokens)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#prepareUnshield(token, to)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#prepareUnshieldMulti(tokens, to)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#prepareTransfer(token, to)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#prepareTransferMulti(tokens, to)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#broadcast(op)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#addInternalSigner(spending, viewing)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#setBundler(bundler?)` | `dist/sdk/plugin.d.ts` | no |
| `RailgunPlugin#setDelegatingSigner(signer?)` | `dist/sdk/plugin.d.ts` | no |
| `chainConfigMainnet()` / `chainConfigSepolia()` | `dist/pkg/index.d.ts` | no |
| `erc20(address)` | `dist/pkg/index.d.ts` | no |
| `RailgunProvider`, `TransactionBuilder`, `Signer`, `Bundler`, … | `dist/pkg/index.d.ts` | no |

Status in `bridge.mjs`: railgun is **declared in `listProtocols` as
`"stub"`** and there is no `railgun.*` JSON-RPC method implemented. The
skill content lists railgun SDK functions as `[SDK]` "available; not
yet wired in `bridge.mjs`".

### `@kohaku-eth/privacy-pools` (entry `dist/index.js`)

Source file: `dist/index.d.ts`.

| Function / class | Source file | Called by `bridge.mjs`? |
|---|---|---|
| `createPPv1Plugin(host, params)` | `dist/index.d.ts` | yes — `buildPlugin` |
| `createPPv1Broadcaster(host, params)` | `dist/index.d.ts` | yes — `shieldedPrepareWithdraw`, `shieldedUnshieldDrain` |
| `PrivacyPoolsV1Protocol#balance(assets?)` | `dist/index.d.ts` | yes — `shieldedBalance` |
| `PrivacyPoolsV1Protocol#prepareShield(asset)` | `dist/index.d.ts` | yes — `shieldedPrepareDeposit` |
| `PrivacyPoolsV1Protocol#prepareUnshield(asset, to)` | `dist/index.d.ts` | yes — `shieldedPrepareWithdraw`, `shieldedUnshieldDrain` |
| `PrivacyPoolsV1Protocol#notes(assets?, includeSpent?)` | `dist/index.d.ts` | yes — `shieldedUnshieldDrain` |
| `PrivacyPoolsV1Protocol#ragequit(labels)` | `dist/index.d.ts` | no |
| `PrivacyPoolsV1Protocol#sync()` | `dist/index.d.ts` | yes — every shielded handler |
| `PrivacyPoolsV1Protocol#dumpState()` | `dist/index.d.ts` | yes — `persistState` |
| `SecretManager(params)` | `dist/index.d.ts` | no (default factory) |
| `IPFSAspService` | `dist/index.d.ts` | no |
| `OxBowAspService({ network, aspUrl })` | `dist/index.d.ts` | yes — Sepolia ASP factory in `buildPlugin` |
| `PrivacyPoolsV1_0xBow` (deployment table) | `dist/index.d.ts` | yes — `entrypointFor` |
| `E_ADDRESS` (`0xee…ee`) | `dist/index.d.ts` | yes — `shieldedBalance` (asset id for ETH) |
| `createPPv2Plugin` | `dist/index.d.ts` | no (v2 is `foo: 'bar'` placeholder upstream) |

Status in `bridge.mjs`: privacy-pools is **`"live"`** on chains `[11155111, 1]`. The
skill content references this wiring.

### `@kohaku-eth/tornado-cash` (coming soon)

There is no upstream Kohaku SDK for Tornado Cash yet. Drafting Tornado
Cash transactions through the agent is coming soon. Until then, the
skill is loaded for decode-context only: the agent recognizes Tornado
Cash calldata in incoming flows and explains it through the standard
ConfirmGate. For shielded ETH today the agent uses Privacy Pool or
Railgun.

## Follow-ups (not in this PR)

* `skills/shield-eth/` and `skills/unshield-eth/` are task-skills that
  exist alongside the protocol skills. They are out of scope for this
  curation pass per the directive, but should be audited in a follow-up
  to confirm they reference the kohaku SDK rather than drafting raw
  shielded calldata. Filed here so it does not get lost.
* `bridge.mjs` exposes `shielded.{balance,prepareDeposit,prepareWithdraw,unshieldDrain}`
  but no `railgun.*`. If/when railgun is wired, the `skills/railgun/interactions.md`
  table of "[SDK] not yet wired" entries flips to live and the curation
  here gets updated.
* `contracts.json` for railgun lists the mainnet Smart Wallet 2.0 proxy
  + logic; the ABI files are TODO stubs. The mandate here is "use the
  SDK"; the ABIs are decoder support, not a signing surface. We do not
  fabricate ABIs.
* Address `0x9D8D4cdfeD605293DC8826BC2D2A2c7Fb867Edd0` in
  `skills/privacy-pool/contracts.json` is Phase 1b's scaffolded
  Sepolia Entrypoint guess. The SDK ships `PrivacyPoolsV1_0xBow[11155111].entrypoint`
  which the bridge uses at runtime — we have not cross-checked the
  scaffold value against the SDK's compiled-in address, so the existing
  `_note: TODO(curator)` stays.
