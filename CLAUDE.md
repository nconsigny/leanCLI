# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

This repo (`leanCLI/`, GitHub `nconsigny/leanCLI` — historical name `leanKohaku`) is a research-grade Ethereum wallet split between a verified Lean 4 core and a set of untrusted sidecars / native helpers. The historical name is preserved inside the tree: the Lake package is still `leanKohaku`, the Lean namespace is `LeanKohaku.*`, and the wallet CLI/daemon binaries are `leankohaku` / `leankohaku-daemon`. Only the repo directory and remote moved.

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
| `leankohaku` | `leankohaku` | CLI (root: `LeanKohaku/App/Main.lean`). Thin JSON-RPC forwarder. |
| `leankohaku-daemon` | `leankohaku-daemon` | Wallet daemon (root: `LeanKohaku/App/DaemonMain.lean`). UDS at `$XDG_RUNTIME_DIR/leankohaku/leankohaku.sock`. |
| `kohaku_agent` | `kohaku-agent` | One-shot LLM agent (root: `LeanKohaku/App/AgentMain.lean`). Native replacement for the legacy `bridge/llm/` sidecar. |
| `kohaku_agentd` | `kohaku-agentd` | Persistent agent daemon (root: `LeanKohaku/App/AgentDaemonMain.lean`). UDS at `$XDG_RUNTIME_DIR/leankohaku/agent.sock`; SQLite session store via `c/lean_sqlite/`. |
| `leankohaku-eip712-check` | — | EIP-712 walker smoke check. |
| `leankohaku-ens-check` | — | ENS resolver smoke check. |
| `leankohaku-sphincs-test` | — | SPHINCS+ shim roundtrip test. |
| `agent_session_test` | — | SQLite session-store smoke test (Phase 1a prereq). |

Build a single module while iterating on proofs: `lake build LeanKohaku.Invariants.Wallet`.

CI: `.github/workflows/lean_action_ci.yml` runs `leanprover/lean-action@v1` — same as `lake build`. Proofs ARE the tests; `lake build` fails on any `sorry`. Phase smoke tests live under `tests/agent_phase{0,1a,1b,1c,1d}_smoke.sh`.

Mathlib is intentionally **not** a dependency; add only when starting ZMod / EC algebraic proofs. Lake options set repo-wide: `autoImplicit := false`, `pp.unicode.fun := true`.

## Architecture

Four layers; dependency flows downward. `Invariants/` is the spec root.

1. **Primitives** — `LeanKohaku/Crypto/` (Hex, Secp256k1 scaffolding, Hacl FFI). Pure, no IO.
2. **Domain** — `LeanKohaku/Ethereum/`, `LeanKohaku/Wallet/`, `LeanKohaku/Keystore/`, `LeanKohaku/Contract/`, `LeanKohaku/Sphincs/` (post-quantum hybrid 4337 userOp). Runtime TPM2 integration is isolated in `Keystore/Tpm2Runtime.lean`. Privacy / Clearsign / Colibri / LlmAgent sidecar wrappers live here too (one Lean module per sidecar boundary).
3. **Surfaces** — `LeanKohaku/RPC/`, `LeanKohaku/Daemon/`, `LeanKohaku/Cli/`, executable roots under `LeanKohaku/App/`. Wallet daemon serves the CLI/TUI; the agent daemon (below) is a sibling surface.
4. **Agent** — `LeanKohaku/Agent/` (Loop, Registry, Persona, Prompt, Tools, ToolDefs/, Llm OpenAI-compatible client, Http, Session, Skills, Memory, MemoryPrompts, Compression, DaemonClient). Hosts the LLM loop; talks to the wallet daemon over UDS for chain reads, never for signing decisions.

`LeanKohaku.lean` re-exports the lib so downstream code writes `import LeanKohaku`.

### Sidecars (`bridge/`)

Untrusted Node sidecars. Each Lean wrapper is the **only** place that spawns its sidecar.

| Sidecar | Lean wrapper | Purpose | Trusted for? |
|---|---|---|---|
| `bridge/` | `LeanKohaku/Privacy/Bridge.lean` | Privacy Pools / Railgun (snarkjs, libp2p) | Witness generation; **not** tx structure |
| `bridge/clearsign/` | `LeanKohaku/Clearsign/Bridge.lean` | ERC-7730 calldata + EIP-712 walker | UI rendering only |
| `bridge/colibri/` | `LeanKohaku/Colibri/{Bridge,Persistent}.lean` | Stateless light client (Helios-backed); verified reads + opt-in verified simulation | UI confirmation copy; **not** signing |
| `bridge/helios/` | `LeanKohaku/Helios/{Bridge,Persistent}.lean` | `@a16z/helios` Rust light client + embedded REVM; opt-in local `eth_call` / `eth_estimateGas` simulation against sync-committee-verified state | UI confirmation copy; **not** signing |
| `bridge/llm-legacy/` | `LeanKohaku/LlmAgent/Bridge.lean` | Legacy NL → tx-draft (Anthropic SDK + viem) | UI suggestion only |

The LLM default is now the native `kohaku-agent` exe. The legacy sidecar is reachable via `LEAN_KOHAKU_LLM_BRIDGE_LEGACY=1`.

`Colibri/Persistent.lean` keeps a long-lived UDS connection to `bridge/colibri/bridge.mjs --listen`, so the sync-committee bootstrap is paid once per chainId per daemon lifetime. Toggled at runtime via `daemon.colibri.toggle`; auto-started at daemon boot unless `KOHAKU_COLIBRI_DISABLED=1`.

`Helios/Persistent.lean` is the parallel boundary for `@a16z/helios`. Same UDS / newline-JSON wire protocol; same trust posture (output is rendered to ConfirmGate, never trusted for signing). Toggled via `daemon.helios.toggle`; opt-in at boot via `KOHAKU_HELIOS=1` (since `@a16z/helios` must be installed under `bridge/helios/` first). RPCs: `tx.simulateHelios`, `eth.proxyHelios`, `daemon.helios.status`. Each call carries `executionRpc` — Helios needs an execution-layer fallback for `eth_getLogs` and similar non-light-verifiable methods.

The trust model is uniform: **every sidecar is treated as malicious**. The daemon never signs based on sidecar output. Chain reads from sidecars (and from the agent) are policy-gated by `Privacy.NetworkPolicy` exactly like CLI/TUI requests.

### Agent layer (`LeanKohaku/Agent/` + `kohaku-agentd`)

The agent owns its own daemon (`kohaku-agentd`) because LLM sessions are long-running, stateful, and need an SQLite store. Wire protocol on the agent socket is newline-delimited JSON ops: `ping`, `reload`, `extract_memory`, `update_memory`, `show_memory`, plus chat-shaped session ops (see `LeanKohaku/App/AgentDaemonMain.lean`).

Key modules:
- `Agent/Loop.lean` — one shot of the agent loop (used by both `kohaku-agent` and per-turn from `kohaku-agentd`).
- `Agent/Llm.lean` — OpenAI-compatible chat client (HTTP via `c/lean_http/`).
- `Agent/Session.lean` — SQLite append-log of turns + tool calls, FTS5 search.
- `Agent/Memory.lean` + `Agent/MemoryPrompts.lean` — LLM-driven extraction into a project `MEMORY.md`; post-filter to keep the index tight. Surfaced as `kohaku memory show/edit/refresh/forget` CLI subcommands.
- `Agent/Compression.lean` — token-budget middle-turn summarization for long sessions.
- `Agent/Skills.lean` + `Agent/ToolDefs/Protocols.lean` — trigger-keyed skills registry, loaded from the on-disk `skills/` tree (below).
- `Agent/ToolDefs/TrustedRegistry.lean` (Phase 1d) — wraps the daemon RPC `wallet.lean_verified_addresses`. The daemon caps results per derivation path via `trustedRegistryMaxPerPath`.
- Incognito mode propagates through every memory and session write site (Phase 1c).

### Skills registry (`skills/`)

On-disk, per-skill directories (`SKILL.md` + supporting JSON/ABI/markdown). Loaded by `Agent/Skills.lean`; surfaced to the LLM as a single `protocols` tool whose payload is gated by trigger keywords in the user message.

Current entries:
- Meta: `kohaku-wallet`, `web3-security`.
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
        ↓                       └→ daemon walks trace, prefetches token meta,
        ↓                          renders "0.1 USDC" in TransfersBlock
   (or tx.simulateColibri) ──→  same shape, executed inside the stateless
        ↓                          light client (WASM EVM + committee proofs).
        ↓                          Opt-in only — see Colibri caveat.
   tx.preflightContext   ──→  display-only: current allowance/balance + recent
        ↓                          Transfer/Approval events between the parties.
  ConfirmGate    ──→  user inspects intent + sim outcome + token movements
        ↓                Esc bails; Enter advances
  eoa.send / r1.send* / sphincs.account.send  ──→ signs and broadcasts
```

`tx.simulate` deliberately uses direct RPC, not Colibri: stateless-light-client validation surfaces spurious reverts on multicall/router calls (`Daemon/Server.lean:5511-5517`). `tx.simulateColibri` is the opt-in path when the user wants consensus-verified simulation.

If you're adding a new "produces calldata" surface, wire it through this gate — never call `eoa.send` / `r1.send*` / `sphincs.account.send` directly. `SendRawFlow` is the canonical reusable confirm path.

### Thin CLI

The CLI is a JSON-RPC forwarder to the wallet daemon. Wallet file I/O, account formatting, and preflight live daemon-side (`account.getDefault/setDefault`, `account.list`, `daemon.preflight`). Memory commands talk to the agent daemon. Only interactive prompts (e.g. Y/N after `tpm.create`) stay CLI-side. Adding a new command: if it manipulates state, the daemon owns it and the CLI prints the result.

### C shims (`c/`)

Loopback FFI for capabilities Lean can't do directly. Wallet logic stays FFI-free; these are concentrated at runtime boundaries.

- `c/hacl_helpers/` — HACL\* crypto helpers (hashes, KDF).
- `c/secp256k1_helpers/` — bitcoin-core secp256k1.
- `c/rustcrypto_helpers/` — additional curves.
- `c/lean_uds/` — Unix domain socket primitives used by both daemons.
- `c/lean_http/` — HTTP client (agent's LLM I/O, ENS provider HTTP).
- `c/lean_sqlite/` — SQLite (agent session store; loopback FFI shim with FTS5).

## Invariants workflow

`INVARIANTS.md` is the living source of truth. Every invariant: 📝 stated → 🚧 in-progress → ✅ proved (or 🔒 axiomatized for FFI). Workflow:

1. State informally in `INVARIANTS.md`.
2. Formalize under `LeanKohaku/Invariants/<Topic>.lean`.
3. Real proof before merge; no `sorry` lands.
4. Flip to ✅ with the theorem name + module path.

Currently proved: **1.1** (`subChecked_preserves_total` in `Invariants/Amount.lean`) and **1.2** (`apply_some_affordable`, `apply_sender_debited`, `apply_non_sender_balance` in `Invariants/Wallet.lean`). **2.1** and **2.3** are `wellFormed`-by-definition in `Invariants/TxWellFormed.lean`.

The `Invariants/Wallet.lean` abstract wallet is deliberately thin (`AccountId : String`, balances `Nat`, no crypto). Operational types in `LeanKohaku/Wallet/` and `LeanKohaku/Ethereum/` will refine these later. Keep the separation: the abstract model exists to make proofs tractable.

Use `Amount.subChecked` rather than raw `Nat.sub` for any balance computation — silent zero-clamping would be a catastrophic accounting bug and invariant 1.1 exists to rule it out.
