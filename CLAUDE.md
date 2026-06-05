# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

This repo (`leanCLI/`, GitHub `nconsigny/leanCLI`, formerly `leanKohaku`) is a research-grade Ethereum wallet split between a verified Lean 4 core and a set of untrusted sidecars / native helpers. The Lake package is `leanCLI`, the Lean namespace is `LeanCli.*`, and the wallet CLI/daemon binaries are `leancli` / `leancli-daemon`. The assistant persona ("Kohaku") and the koi mascot keep their original names; the upstream spec project `ethereum/kohaku` and its `@kohaku-eth/*` packages are unrelated to this rename and referenced as-is.

Lean (pinned to `leanprover/lean4:v4.29.1` via `lean-toolchain`) owns network policy, account policy, transaction framing, JSON/RLP encoding, daemon dispatch, intent decoding, simulation orchestration, and the agent loop. Cryptographic primitives, ZK circuits, EVM simulation, ERC-7730 walking, and the natural-language agent's LLM I/O live in process-isolated sidecars or native helper exes. The CLI-first surface talks to a wallet daemon over a Unix domain socket; a separate agent daemon hosts long-running LLM sessions.

Every produced calldata flows through `decode → simulate → user-confirm` before any signature. No signing decision depends on a sidecar's output.

## Build & run

```bash
elan toolchain install $(cat lean-toolchain)   # first-time setup
lake build                                      # builds lib + all executables
```

Artifacts land in `.lake/build/bin/`. The `lean_exe` targets in `lakefile.lean`:

| Lake target | Binary | Role |
|---|---|---|
| `leancli` | `leancli` | CLI (root: `LeanCli/App/Main.lean`). Thin JSON-RPC forwarder. |
| `leancli-daemon` | `leancli-daemon` | Wallet daemon (root: `LeanCli/App/DaemonMain.lean`). UDS at `$XDG_RUNTIME_DIR/leancli/leancli.sock`. |
| `leancli_agent` | `leancli-agent` | One-shot LLM agent (root: `LeanCli/App/AgentMain.lean`). The native LLM path — there is no Node LLM sidecar. |
| `leancli_agentd` | `leancli-agentd` | Persistent agent daemon (root: `LeanCli/App/AgentDaemonMain.lean`). UDS at `$XDG_RUNTIME_DIR/leancli/agent.sock`; SQLite session store via `native/lean_sqlite/`. |
| `leancli-eip712-check` | — | EIP-712 walker smoke check. |
| `leancli-ens-check` | — | ENS resolver smoke check. |
| `leancli-railgun-snapshot` | — | Railgun on-disk snapshot maintenance helper. |
| `leancli-sphincs-test` | — | SPHINCS+ shim roundtrip test. |
| `agent_session_test` | — | SQLite session-store smoke test (Phase 1a prereq). |

Build a single module while iterating on proofs: `lake build LeanCli.Invariants.Wallet`.

CI: `.github/workflows/lean_action_ci.yml` runs `leanprover/lean-action@v1` — same as `lake build`. Proofs ARE the tests; `lake build` fails on any `sorry`. Phase smoke tests live under `ops/tests/agent_phase{0,1a,1b,1c,1d}_smoke.sh`.

Mathlib is intentionally **not** a dependency; add only when starting ZMod / EC algebraic proofs. Lake options set repo-wide: `autoImplicit := false`, `pp.unicode.fun := true`.

## Architecture

Four layers; dependency flows downward. `Invariants/` is the spec root.

1. **Primitives** — `LeanCli/Crypto/` (Hex, Secp256k1 scaffolding, Hacl FFI). Pure, no IO.
2. **Domain** — `LeanCli/Ethereum/`, `LeanCli/Wallet/`, `LeanCli/Keystore/`, `LeanCli/Contract/`, `LeanCli/Sphincs/` (post-quantum hybrid 4337 userOp). Runtime TPM2 integration (master-KEK custody, not an account kind) is isolated in `Keystore/Tpm2Runtime.lean`. Privacy / Clearsign / Helios / Colibri / SafeNode / LlmAgent sidecar wrappers live here too (one Lean module per sidecar boundary).
3. **Surfaces** — `LeanCli/RPC/`, `LeanCli/Daemon/`, `LeanCli/Cli/`, executable roots under `LeanCli/App/`. Wallet daemon serves the CLI/TUI; the agent daemon (below) is a sibling surface.
4. **Agent** — `LeanCli/Agent/` (Loop, Registry, Persona, Prompt, Tools, ToolDefs/, Llm OpenAI-compatible client, Http, Session, Skills, Memory, MemoryPrompts, Compression, DaemonClient). Hosts the LLM loop; talks to the wallet daemon over UDS for chain reads, never for signing decisions.

`LeanCli.lean` re-exports the lib so downstream code writes `import LeanCli`.

### Kohaku plugin host (`sidecars/`)

Untrusted sidecars hosted under the Kohaku plugin model. Each Lean wrapper is the **only** place that spawns its sidecar. See [`docs/PLUGIN_ARCHITECTURE.md`](docs/PLUGIN_ARCHITECTURE.md) for the full flag surface and the pinned-and-lazy load model.

**Providers (chain reads + simulation) — single-select via `LEANCLI_PROVIDER`** (default `helios`). The provider is the read backend; it maps onto the existing `ReadBackend` mechanism (`daemon.readBackend.set` RPC + per-call `backend:` param).

| `LEANCLI_PROVIDER` | Lean wrapper | What it is | Trusted for? |
|---|---|---|---|
| `helios` (default) | `LeanCli/Helios/{Bridge,Persistent}.lean` | `@a16z/helios` Rust light client + embedded REVM; consensus-verified `eth_call`/`eth_estimateGas` against sync-committee-verified state | UI confirmation copy; **not** signing |
| `colibri` | `LeanCli/Colibri/{Bridge,Persistent}.lean` | Colibri stateless light client (WASM EVM + committee proofs) | UI confirmation copy; **not** signing |
| `rpc` | `LeanCli/RPC/Outbound.lean` | Direct configured RPC endpoint; no light-client verification | UI confirmation copy; **not** signing |
| `safenode` | `LeanCli/SafeNode/Persistent.lean` (+ helios) | Helios fronted by the TDX-attested SafeNode ORAM proxy; requires `LEANCLI_SAFE_NODE_URL` | UI confirmation copy; **not** signing |

`LEANCLI_PROVIDER` is single-select (helios/colibri are mutually exclusive — "one or the other"). `LEANCLI_READ_BACKEND` is a back-compat alias; `LEANCLI_PROVIDER` wins. Unrecognized values fall back to `helios`.

**Privacy plugins (shielded flows) — multi-select via `LEANCLI_PRIVACY`** (comma list, default empty = none enabled). Hosted by `sidecars/kohaku/bridge.mjs`; the Lean wrapper is `LeanCli/Privacy/Bridge.lean`, which forwards the allow-list into the sidecar env.

| `LEANCLI_PRIVACY` entry | npm package | Trusted for? |
|---|---|---|
| `railgun` | `@kohaku-eth/railgun` | Witness generation; **not** tx structure |
| `privacy-pools` | `@kohaku-eth/privacy-pools` | Witness generation; **not** tx structure |
| `tornado` | sidecar-native (decode-only today) | Intent decode; **not** tx structure |

A `shielded.*` method for a plugin not in the enabled list returns `{ok:false,error:"plugin not enabled: <name>"}` **before** lazy-importing it — disabled plugin code is never loaded.

**Other sidecars:**

| Sidecar | Lean wrapper | Purpose | Trusted for? |
|---|---|---|---|
| `sidecars/clearsign/` | `LeanCli/Clearsign/Bridge.lean` | ERC-7730 calldata + EIP-712 walker | UI rendering only |
| `sidecars/sphincs/` | `LeanCli/Sphincs/Bridge.lean` | SPHINCS+ post-quantum signer (C / Rust) | Sig blob shape; every `signWithVerify` re-verifies locally |

The native `leancli-agent` exe is the only LLM path; there is no Node LLM sidecar.

`Helios/Persistent.lean` keeps a long-lived UDS connection to `sidecars/kohaku/helios/bridge.mjs --listen` (same UDS / newline-JSON wire protocol for `Colibri/Persistent.lean` against `sidecars/kohaku/colibri/`). The daemon-wide default `readBackend` is `helios`, so every `tx.simulate` runs through the consensus-verified path unless the caller passes `backend: "rpc"` or flips the toggle via `daemon.readBackend.set`. The helios sidecar injects `executionRpc` and `chainId` from `cfg.rpcEndpoint`; `consensusRpc` (beacon API) is caller-supplied with `operationsolarstorm.org` defaults for mainnet + Sepolia. v0.11.1 supports through Fulu; verified end-to-end with a REVM-backed `eth_call` simulate of `USDT.name() → "Tether USD"`.

Beacon-endpoint gotcha: not every consensus RPC supports the light-client API the way helios needs. Ankr Premium's `eth_beacon` endpoint returns `light_client/updates` payloads helios rejects with `sync failed: invalid sync committee period`, while `ethereum.operationsolarstorm.org` (and `sepolia.operationsolarstorm.org`) sync fine. If you point helios at a custom beacon, validate the light-client paths first.

The trust model is uniform: **every sidecar and every loaded plugin is treated as malicious**. The daemon never signs based on sidecar output. Chain reads from sidecars (and from the agent) are policy-gated by `LeanCli.Network.Policy` exactly like CLI/TUI requests.

### Agent layer (`LeanCli/Agent/` + `leancli-agentd`)

The agent owns its own daemon (`leancli-agentd`) because LLM sessions are long-running, stateful, and need an SQLite store. Wire protocol on the agent socket is newline-delimited JSON ops: `ping`, `reload`, `extract_memory`, `update_memory`, `show_memory`, plus chat-shaped session ops (see `LeanCli/App/AgentDaemonMain.lean`).

Key modules:
- `Agent/Loop.lean` — one shot of the agent loop (used by both `leancli-agent` and per-turn from `leancli-agentd`).
- `Agent/Llm.lean` — OpenAI-compatible chat client (HTTP via `native/lean_http/`).
- `Agent/Session.lean` — SQLite append-log of turns + tool calls, FTS5 search.
- `Agent/Memory.lean` + `Agent/MemoryPrompts.lean` — LLM-driven extraction into a project `MEMORY.md`; post-filter to keep the index tight. Surfaced as `leancli memory show/edit/refresh/forget` CLI subcommands.
- `Agent/Compression.lean` — token-budget middle-turn summarization for long sessions.
- `Agent/Skills.lean` + `Agent/ToolDefs/Protocols.lean` — trigger-keyed skills registry, loaded from the on-disk `skills/` tree (below).
- `Agent/ToolDefs/TrustedRegistry.lean` (Phase 1d) — wraps the daemon RPC `wallet.lean_verified_addresses`. The daemon caps results per derivation path via `trustedRegistryMaxPerPath`.
- Incognito mode propagates through every memory and session write site (Phase 1c).

### Skills registry (`skills/`)

On-disk, per-skill directories (`SKILL.md` + supporting JSON/ABI/markdown). Loaded by `Agent/Skills.lean`; surfaced to the LLM as a single `protocols` tool whose payload is gated by trigger keywords in the user message.

Current entries:
- Meta: `leancli-wallet`, `web3-security`.
- DeFi: `aave`, `morpho`, `uniswap`, `cowswap`, `bold-liquity`, `fxusd`.
- Privacy: `railgun`, `privacy-pool`, `tornado-cash` (last is decode-only today; SDK and drafting coming soon).
- Worked ops: `approve-erc20`, `audit-approvals`, `fresh-address`, `revoke-approval`, `send-erc20`, `send-native`, `shield-eth`, `swap-uniswap-v3`, `unshield-eth`.

Adding a new protocol: drop a skill directory (use `uniswap` as the worked template), declare triggers in its `SKILL.md`, point `Agent/ToolDefs/Protocols.lean` at the new directory if a new selector handler is needed. No daemon RPC change required for read-only operations — they go through `chain.ethCall` like every other policy-gated read.

### Pre-sign pipeline

Every signing flow (TUI Send, SendRawFlow, manual Decode, agent-drafted tx) goes through the same gate:

```
  build {to, value, data}
        ↓
  tx.decodeIntent  ──→  ERC-7730 descriptor (or 4byte fallback) → human intent
        ↓
  tx.simulate           ──→  eth_call + eth_estimateGas + (opt) debug_traceCall
        ↓                       run against the selected provider; daemon walks
        ↓                       trace, prefetches token meta, renders "0.1 USDC"
        ↓                       in TransfersBlock
   tx.preflightContext   ──→  display-only: current allowance/balance + recent
        ↓                          Transfer/Approval events between the parties.
  ConfirmGate    ──→  user inspects intent + sim outcome + token movements
        ↓                Esc bails; Enter advances
  eoa.send / sphincs.account.send  ──→ signs and broadcasts
```

`tx.simulate` runs against the **selected provider** (`LEANCLI_PROVIDER`, default `helios` → consensus-verified REVM). Direct RPC is the `rpc` provider, also reachable per-call via `backend:"rpc"`; the Colibri stateless light client is the `colibri` provider. Provider/light-client simulation output is informational only — the user's confirmation in `ConfirmGate` is the trust anchor, never the simulation result.

If you're adding a new "produces calldata" surface, wire it through this gate — never call `eoa.send` / `sphincs.account.send` directly. `SendRawFlow` is the canonical reusable confirm path.

### Thin CLI

The CLI is a JSON-RPC forwarder to the wallet daemon. Wallet file I/O, account formatting, and preflight live daemon-side (`account.getDefault/setDefault`, `account.list`, `daemon.preflight`). Memory commands talk to the agent daemon. Only interactive prompts (e.g. Y/N after `tpm.create`) stay CLI-side. Adding a new command: if it manipulates state, the daemon owns it and the CLI prints the result.

### Native shims (`native/`)

Loopback FFI for capabilities Lean can't do directly. Wallet logic stays FFI-free; these are concentrated at runtime boundaries. See [`native/README.md`](native/README.md) for pins + consumers, and [`docs/CRYPTO_POLICY.md`](docs/CRYPTO_POLICY.md) for the one-library-per-primitive policy.

- `native/hacl_helpers/` — HACL\* crypto helpers (hashes, KDF). RIPEMD-160 backs BIP-32 HASH160 only.
- `native/secp256k1_helpers/` — bitcoin-core secp256k1.
- `native/rustcrypto_helpers/` — RustCrypto RIPEMD-160 (kept: HACL does not expose it).
- `native/lean_uds/` — Unix domain socket primitives used by both daemons.
- `native/lean_http/` — HTTP client (agent's LLM I/O, ENS provider HTTP).
- `native/lean_sqlite/` — SQLite (agent session store; loopback FFI shim with FTS5).

## Invariants workflow

`INVARIANTS.md` is the living source of truth. Every invariant: 📝 stated → 🚧 in-progress → ✅ proved (or 🔒 axiomatized for FFI). Workflow:

1. State informally in `INVARIANTS.md`.
2. Formalize under `LeanCli/Invariants/<Topic>.lean`.
3. Real proof before merge; no `sorry` lands.
4. Flip to ✅ with the theorem name + module path.

Currently proved (✅): Cat 0 verified-core (`no_key_exfiltration`, `no_silent_7702_delegation`, the `verified_*`/`signEOA_*` family in `Invariants/Core.lean`); **1.1** (`subChecked_preserves_total`) and **1.2** (`apply_some_affordable`, `apply_sender_debited`, `apply_non_sender_balance`); account policy (4.3), JSON destructors (4.4); the bridge policy-classification + runtime gate (**5.7** — `gateDecision_denied_when_policy_denies`, `callGated_denied_when_policy_denies`, `callGated_allowed_proceeds` in `Invariants/Bridge.lean`) and 5.8–5.11; network/provider policy (Cat 6/7); keystore (Cat 8, EOA + SPHINCS hybrid, no R1); swap (Cat 11); SPHINCS hybrid account (Cat 12); LLM address resolution (Cat 14). **2.1**/**2.3** are `wellFormed`-by-definition in `Invariants/TxWellFormed.lean`. Cat 13 is 🔒 axiomatized crypto. The R1/P-256 account path and its invariants (former Cat 9/10, 8.4, 3.3) were removed — EOA + SPHINCS hybrid remain.

The `Invariants/Wallet.lean` abstract wallet is deliberately thin (`AccountId : String`, balances `Nat`, no crypto). Operational types in `LeanCli/Wallet/` and `LeanCli/Ethereum/` will refine these later. Keep the separation: the abstract model exists to make proofs tractable.

Use `Amount.subChecked` rather than raw `Nat.sub` for any balance computation — silent zero-clamping would be a catastrophic accounting bug and invariant 1.1 exists to rule it out.
