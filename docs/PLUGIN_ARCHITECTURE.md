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
| `tornado` | (sidecar-native, decode-only today) | `shielded.tornado.*` |

Enable plugins at daemon boot with **`LEANCLI_PRIVACY`**, a comma list:

```
LEANCLI_PRIVACY=railgun,privacy-pools
```

Default is empty — **no privacy plugin is enabled** unless explicitly
listed. The wallet daemon (`LeanCli/Privacy/Bridge.lean`) forwards the
`LEANCLI_PRIVACY` value into the sidecar spawn env.

When a `shielded.*` method is requested for a plugin that is not in the
enabled list, the host returns a clean

```json
{ "ok": false, "error": "plugin not enabled: <name>" }
```

**before** lazy-importing that plugin — its code is never loaded into the
process. Enabled plugins load on first use as today.

The host exposes a `listEnabled` method reporting the selected provider
and the enabled privacy plugins:

```json
{
  "provider": "helios",
  "enabledPrivacy": ["railgun"],
  "protocols": [
    { "name": "privacy-pools", "status": "live", "chains": [11155111, 1], "enabled": false },
    { "name": "railgun",       "status": "live", "chains": [11155111, 1], "enabled": true },
    { "name": "tornado-cash",  "status": "scaffolded", "chains": [1],    "enabled": false }
  ]
}
```

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
  | `@kohaku-eth/plugins` | 0.0.1-alpha.8 | top-level; also 0.0.1-alpha.7 nested under privacy-pools |
  | `@kohaku-eth/railgun` | 0.0.1-alpha.21 | |
  | `@kohaku-eth/privacy-pools` | 0.0.2-alpha.9 | |
  | `@kohaku-eth/provider` | 0.1.0-alpha.7, 0.1.0-alpha.8 | transport wrapper (transitive) |

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
