# Plugin architecture (Kohaku sidecar host)

This document describes how leanCLI hosts the upstream `@kohaku-eth/*`
plugins, how the provider (read backend) and privacy plugins are
selected at runtime, and the supply-chain pinning that keeps the
untrusted Node dependency tree honest.

The guiding rule is unchanged from `CLAUDE.md`: **every sidecar is
treated as malicious.** The flag surface below decides *which* plugin
code is allowed to load and *which* read backend is the default; it does
not grant any sidecar signing authority. Every produced calldata still
flows through `decode → simulate → ConfirmGate` before a signature, and
all chain reads remain policy-gated by `LeanCli.Network.Policy`.

## Providers (read backends) — single-select

A "provider" is the backend the daemon uses for chain *reads* and
simulation. It is single-select and maps directly onto the existing
`LeanCli.Daemon.State.ReadBackend` mechanism (`daemon.readBackend.set`
RPC, the per-call `backend: rpc|colibri|helios` param, and the default
field in `Daemon/State.lean`).

Select the default at daemon boot with **`LEANCLI_PROVIDER`**:

| `LEANCLI_PROVIDER` | Effect |
|---|---|
| `helios` (default) | `@a16z/helios` light client + embedded REVM. Consensus-verified state via sync-committee proofs. Default backend. |
| `colibri` | Colibri stateless light client (WASM EVM + committee proofs). |
| `rpc` | Direct configured RPC endpoint. No light-client verification. |
| `safenode` | Helios fronted by the TEE-attested SafeNode ORAM proxy. Selects `.helios` and requires `LEANCLI_SAFE_NODE_URL` (+ `LEANCLI_SAFE_NODE_API_KEY`); if that URL is unset, helios reads directly until it is configured. Attestation is GCP Confidential Space (`LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST`, pure Node, current deployment) or Phala TDX quote (`TDX_QUOTE_VERIFIER_BIN`), selected via `LEANCLI_SAFE_NODE_ATTESTATION`. |

`LEANCLI_READ_BACKEND` is still accepted as a back-compat alias;
`LEANCLI_PROVIDER` wins when both are set. Unrecognized values fall back
to `helios` with a stderr warning. The provider can be changed at runtime
with `daemon.readBackend.set` and overridden per call with the `backend:`
param — `LEANCLI_PROVIDER` only sets the initial default.

The real EVM simulation engines live in the existing
`sidecars/kohaku/helios/` (`@a16z/helios` + REVM) and
`sidecars/kohaku/colibri/` (Colibri WASM EVM) sidecars. The
`@kohaku-eth/provider` package is only a transport wrapper — its
`call`/`estimateGas` proxy to the underlying client's `request` — so it
is not itself a simulation backend.

Provider/light-client output is **untrusted relative to the verified
core**: its chain-state proofs are re-validated, and signing decisions
still terminate at `ConfirmGate`.

## Privacy plugins — multi-select

Privacy plugins are the shielded flows hosted by `sidecars/kohaku/bridge.mjs`:

| Plugin name (`LEANCLI_PRIVACY`) | npm package | Methods |
|---|---|---|
| `railgun` | `@kohaku-eth/railgun` | `shielded.railgun.*` |
| `privacy-pools` | `@kohaku-eth/privacy-pools` | `shielded.*` (non-railgun, non-tornado) |
| `tornado` | `@kohaku-eth/tornado-cash` | `shielded.tornado.*` |

Select plugins at daemon boot with **`LEANCLI_PRIVACY`**, a comma list:

```
LEANCLI_PRIVACY=railgun,privacy-pools
```

leanCLI is privacy-first: when `LEANCLI_PRIVACY` is **unset**, the wallet
daemon defaults to **all three plugins** (`railgun,privacy-pools,tornado`,
= `Bridge.defaultEnabledPrivacy`) so a fresh install can shield without
editing `daemon.env`. Set the variable explicitly to narrow the surface
(a value matching no known plugin — e.g. `none` — enables nothing). The
daemon (`LeanCli/Privacy/Bridge.lean`) resolves the effective list once
and forwards it into the sidecar spawn env. The sidecar's **own** fail-safe
default remains empty (deny unless told), so a directly-spawned `bridge.mjs`
with no env still enables nothing — the privacy-first default lives in the
daemon, not the untrusted sidecar.

When a `shielded.*` method is requested for a plugin that is not in the
enabled list, the host returns a clean top-level JSON-RPC error

```json
{ "error": { "code": -32001, "message": "plugin not enabled: <name>",
             "data": { "plugin": "<name>", "hint": "add \"<name>\" to LEANCLI_PRIVACY and restart" } } }
```

**before** lazy-importing that plugin — its code is never loaded into the
process. Enabled plugins load on first use as today. (This must be a
top-level error, not an `{ok:false}` payload inside a successful result:
the Lean bridge maps top-level errors to `RpcError`, whereas a wrapped
result reaches the TUI as a "successful" prepare with zero legs.)

The host exposes a `listEnabled` method reporting the selected provider
and the enabled privacy plugins:

```json
{
  "provider": "helios",
  "enabledPrivacy": ["railgun"],
  "protocols": [
    { "name": "privacy-pools", "status": "live", "chains": [11155111, 1], "enabled": false },
    { "name": "railgun",       "status": "live", "chains": [11155111, 1], "enabled": true },
    { "name": "tornado-cash",  "status": "live", "chains": [1, 11155111], "enabled": false }
  ]
}
```

### Maximum-amount quotes

`max` is never a broadcast-time sentinel in the interactive UI. Native sends call
Lean RPC `eoa.maxSendable`, which subtracts `21000 × capped maxFeePerGas × 1.2`
from the selected EOA balance. Privacy Pools, Railgun, and Tornado expose
`shielded.maxUnshield`, `shielded.railgun.maxUnshield`, and
`shielded.tornado.maxUnshield`; their sidecar results are converted to a concrete
amount before `ConfirmGate`.

Privacy Pools selects the largest approved unspent note. Tornado selects the largest
spendable fixed-denomination note. Railgun deducts a fixed conservative ERC-4337 gas
budget priced through `pimlico_getUserOperationGasPrice`, then applies the chain's
treasury fee BPS. Railgun recomputes and enforces that cap in the broadcast handler,
so the untrusted quote cannot authorize an amount above the current spendable balance.

### Tornado Cash sidecar (`sidecars/kohaku/tornado.mjs`)

Tornado is live via `@kohaku-eth/tornado-cash@0.0.2-alpha.16`. All privacy
plugins now share `@kohaku-eth/plugins@0.0.1-alpha.11` and its async `Host`
contract. Tornado logic remains in its own lazily-imported module (`tornado.mjs`,
with `tornado-external-sync.mjs` and `tornado-paymaster-gas.mjs`) to isolate its
worker threads, proving artifacts, and protocol-specific persisted state.

The plugin runs comlink **worker threads** (state-manager / merkle-tree / msm)
and, on first withdraw, downloads groth16 proving artifacts. Because Node ignores
the SDK's `stateManagerWorkerUrl`, `ensureTornadoPaymasterGasPatched()` rewrites
the bundled worker gas limits (`preVerificationGas 80000n→85000n`,
`paymasterPostOpGasLimit 10000n→100000n`) in the installed dependency on disk —
idempotent and best-effort; it means the installed worker no longer byte-matches
the npm artifact.

Env surface (set by the daemon's `tornadoBridgeCall`, never Sepolia-pinned —
tornado runs on the caller-selected chain, mainnet or Sepolia):

| Env var | Meaning |
|---|---|
| `LEANCLI_TC_SEED_HEX` | EOA master seed (hex) — the tornado keystore source; the SDK derives note secrets at disjoint BIP-32 paths (`m/29795'/1'`). Default source. |
| `LEANCLI_TC_MNEMONIC` | Alternative dedicated mnemonic (compromise-isolation); `LEANCLI_TC_SEED_HEX` wins. |
| `LEANCLI_TC_STORAGE_PATH` | Per-chain indexer state file (commitments, merkle leaves, our deposit indices). |
| `LEANCLI_TC_BUNDLER_URL` | Optional Pimlico bundler override; default `https://public.pimlico.io/v2/<chainId>/rpc`. |
| `LEANCLI_TC_EXTERNAL_SYNC_DISABLE` | Set to `1` to skip the saga-CDN cold-sync provider (chain-only sync). |

Tornado deposits return UNSIGNED calldata (classified `shieldedRead`); withdraw
quote/execute (`shielded.tornado.quoteWithdraw` / `executeWithdraw`) are
classified `shieldedBroadcast`, so strict-mainnet policy denies them exactly like
Privacy Pools / Railgun.

`listProtocols` is kept working (it returns the full static catalogue,
regardless of enablement) so existing callers do not break.

## Pinned-and-lazy load model

Plugins are **pinned** and **lazy**:

* **Pinned.** Every `@kohaku-eth/*` package and its transitive
  `@kohaku-eth/provider` transport wrapper is version-locked in
  `sidecars/kohaku/package-lock.json` with sha512 subresource-integrity
  hashes. `npm ci` enforces those hashes at install time — a tampered or
  substituted tarball fails the install. The same versions + integrity
  hashes are mirrored into `sidecars/kohaku/plugins.lock.json`, a
  single-screen, human-auditable summary so a reviewer can diff plugin
  versions across releases without parsing the full lockfile.

  Currently pinned (mirrored from the lockfile):

  | Package | Version | Notes |
  |---|---|---|
  | `@kohaku-eth/plugins` | 0.0.1-alpha.11 | unified async Host + note capability API |
  | `@kohaku-eth/railgun` | 0.0.1-alpha.28 | |
  | `@kohaku-eth/privacy-pools` | 0.0.2-alpha.14 | |
  | `@kohaku-eth/provider` | 0.1.0-alpha.8 | deduplicated transport wrapper (transitive) |

* **Lazy.** Each plugin is `import()`-ed only inside its own handler in
  `bridge.mjs` (`loadRailgun` / `loadLeancli`), and only after the
  `LEANCLI_PRIVACY` gate confirms it is enabled. The host does not need to
  re-verify integrity at runtime — npm already pins the bytes via the
  lockfile — so the gate's job is purely to avoid loading disabled plugin
  code into the process at all.

This combination means: a disabled plugin's code is never loaded; an
enabled plugin's code is exactly the version pinned in the lockfile.

## Trust boundary

* The host (`bridge.mjs`) and every plugin it loads are **untrusted**.
* The daemon never signs based on sidecar output. Shielded calldata is
  re-decoded by the Lean RLP / typed-tx / ABI code and gated through the
  pre-sign pipeline (`decodeIntent → simulate → ConfirmGate`) before any
  broadcast. "It's shielded" does not grant signing authority.
* Network egress from the sidecar is classified under the
  `shieldedRead` / `shieldedBroadcast` purposes and runs through
  `LeanCli.Network.Policy`. The runtime gate lives in
  `LeanCli.Privacy.Bridge.callGated` (invariant 5.7): a policy-denied
  shielded request returns a denial **before** the sidecar is spawned, so
  no shielded operation can reach the network when the policy refuses it.
  `callGated` is the only path `shieldedBridgeCall` takes into the
  sidecar; the un-gated `callWithEnv` transport primitive is reserved for
  out-of-band dev tools that run outside the daemon's policy context.
