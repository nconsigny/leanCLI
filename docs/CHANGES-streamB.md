# CHANGES — Stream B (Kohaku flag-driven plugin host)

## Architecture fork — RESOLVED (B)
`@kohaku-eth/provider` is a transport wrapper (its `call`/`estimateGas` proxy to the underlying
client's `request`); the EVM simulation engines are the existing `sidecars/kohaku/helios/`
(`@a16z/helios` + REVM) and `sidecars/kohaku/colibri/` (WASM EVM). Kept those engines; built the flag
surface on the EXISTING `ReadBackend` mechanism. No new registry module, no `Colibri.Persistent` rename.

## Changes
- **Deleted `sidecars/kohaku/llm-legacy/`** (native `leancli-agent`/`leancli-agentd` is the default and
  is independent). Simplified `LlmAgent/Bridge.lean` to `Mode = oneshot|persistent` (removed the
  `LEANCLI_LLM_BRIDGE_LEGACY` branch). Removed the `llm` row in `Daemon/Status.lean`, the stale
  `.gitignore` `llm`/`llm-legacy` lines, and the `leancli-llm-legacy` wrapper row in `leanclispawn`.
- **`sidecars/kohaku/plugins.lock.json`** (new): pinned versions + sha512 integrity for
  `@kohaku-eth/{plugins@0.0.1-alpha.8, railgun@0.0.1-alpha.21, privacy-pools@0.0.2-alpha.9}` + transitive
  `provider@{0.1.0-alpha.7,0.1.0-alpha.8}`, extracted from `package-lock.json` (real hashes).
- **`docs/PLUGIN_ARCHITECTURE.md`** (new): provider registry (helios/colibri/rpc/safenode, single-select
  via `LEANCLI_PROVIDER`), privacy registry (multi-select via `LEANCLI_PRIVACY`), pinned-lazy load model,
  trust boundary.
- **Flag surface (thin, over existing mechanism):**
  - `LEANCLI_PROVIDER` (helios|colibri|rpc|safenode) sets the boot default `ReadBackend` via existing
    `ReadBackend.parse?`/`setReadBackend`; `safenode` → helios + require `LEANCLI_SAFE_NODE_URL`.
    `LEANCLI_READ_BACKEND` kept as back-compat alias (PROVIDER wins). `daemon.readBackend.set` + `backend:`
    param untouched; default stays `helios`.
  - `LEANCLI_PRIVACY` (comma list, default empty) forwarded from `Privacy/Bridge` into the sidecar env;
    `bridge.mjs` gates `shielded.*` per plugin BEFORE lazy `import()`, returning
    `{ok:false,error:"plugin not enabled: <name>"}` for disabled plugins. New `listEnabled` host method
    reports selected provider + enabled privacy; `listProtocols` aliased.

## Invariant 5.7 — COMPLETED (flip 🚧 → ✅ in INVARIANTS.md, Stream-F)
The runtime gate now lives inside `Privacy/Bridge.callGated` (the sole path `shieldedBridgeCall` takes
into the sidecar). Proved in `Invariants/Bridge.lean`:
- `gateDecision_denied_when_policy_denies` — policy-denied ⇒ gate returns `.error (policyDenial req)`.
- `callGated_denied_when_policy_denies` — denied ⇒ `pure (policyDenial req)`, **no spawn** (no-egress).
- `callGated_allowed_proceeds` — allow-arm symmetry ⇒ proceeds to `callWithEnv`.

**Trust-boundary note:** the gate uses `peer := .configuredNode, transport := .direct` — matching the
pre-existing `shieldedBridgeCall` call-site gate exactly (shielded purposes are only ever permitted for
`.configuredNode`; gating as `.localNode` would silently deny every shielded op). The decision moved
*inside* the dispatcher so it cannot be bypassed; no behavior change, posture unchanged.

## Verification
`lake build` 256 jobs green, zero `sorryAx`. `git grep llm-legacy` clean (except CLAUDE.md prose +
historical phase docs — Stream-F). Sidecar JS gating not runtime-tested in the offline sandbox (no
plugin install); Lean side compiles and the gate is proved.

## For Stream-F
- Flip 5.7 to ✅ citing the 3 theorems above.
- `CLAUDE.md` still references `bridge/llm-legacy/` + `LEANCLI_LLM_BRIDGE_LEGACY` and the old sidecar
  table — update to the Kohaku host model (providers + privacy + clearsign + sphincs; no colibri-removal,
  no llm-legacy).
