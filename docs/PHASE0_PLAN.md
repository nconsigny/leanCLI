# Phase 0 — Lean-native LLM agent

## Mission

Replace the Node sidecar `bridge/llm/` (Anthropic-SDK / OpenAI-compat
agent loop) with a Lean-native one-shot agent loop. Ship a new
executable `leancli-agent` in the same Lake project. The agent talks to a
local OpenAI-compatible LLM (`llama-server`, vLLM, Ollama `/v1`, …) over
HTTP via a libcurl FFI shim, and to the leanCLI daemon over the
existing UDS JSON-RPC surface. No Python, no Node, no Hermes, no new TS.
The Ink TUI continues to work without source changes; only
`LlmAgent/Bridge.lean`'s default executable path flips.

## Trust model (recap, non-negotiable)

- The daemon is the trust root. **No new daemon RPCs in Phase 0.**
- The Ink `ConfirmGate` (`SendRawFlow`) remains the only signing surface.
  The agent proposes; the human approves; the daemon signs.
- `LeanCli/Agent/**` MUST NOT import any signing or key-material
  module: `Crypto.Secp256k1Native`, `Crypto.Random`, `Wallet.EOA`,
  `Wallet.HDKey`, `Wallet.Mnemonic`, `Wallet.Entropy`, anything under
  `Keystore/`, or `Daemon.State`.
- Tool allowlist is enforced in code before dispatch, not by prompt.
- HTTP transport is loopback-only and enforced in **both** the C shim and
  the Lean wrapper. Permanent. No env override.
- Supported chains: mainnet (`1`) and Sepolia (`11155111`) only. No L2
  names anywhere in `LeanCli/Agent/**` or `LeanCli/App/AgentMain.lean`.

## Daemon RPC mapping for agent tools

Confirmed against `LeanCli/Daemon/Server.lean` during the read pass.
None of these are new — the agent reuses the existing daemon surface.

| Agent tool name   | Daemon RPC method                | Server.lean line |
| ----------------- | -------------------------------- | ---------------- |
| `decode_calldata` | `tx.decodeIntent`                | 5687             |
| `decode_eip712`   | `eip712.decodeIntent`            | 5738             |
| `tx_simulate`     | `tx.simulate`                    | 5454             |
| `chain_read`      | `chain.ethCall`                  | 2671             |
| `nonce`           | `chain.nonce`                    | 2518             |
| `gas_price`       | `chain.gasPrice`                 | 2642             |
| `propose_send`    | — (synthetic; emits to caller)   | n/a              |

`propose_send` never reaches the daemon. It packages
`{to, value, data, chainId}` and returns it via the final agent
response, where the upstream `LlmAgent.Bridge` consumer (the TUI's
`LlmChatFlow.tsx`, via `chat.draft` / `SendRawFlow`) routes the user
through the existing decode → simulate → confirm → sign pipeline.

## Daemon UDS socket source

The agent resolves the daemon socket using the same convention as
`LeanCli.Cli.DaemonClient` and `bridge/llm/src/daemon-callback.mjs`:

1. `LEANCLI_DAEMON_SOCKET` env (explicit override; new name).
2. `LEANCLI_SOCKET` env (existing convention; kept for parity).
3. `${XDG_RUNTIME_DIR:-/tmp}/leancli/leancli.sock`.

`LEANCLI_DAEMON_SOCKET` is the agent-specific name; the agent
prefers it but falls back to `LEANCLI_SOCKET` so a TUI process and
the agent share the same daemon without re-config.

## Stdout wire shape (byte-compatible contract)

The legacy `bridge/llm/bridge.mjs` reads `--rpc '<json>'` from argv and
writes exactly one JSON-RPC 2.0 envelope line to stdout:

```
{"jsonrpc":"2.0","id":<id|null>,"result":<value>}
{"jsonrpc":"2.0","id":<id|null>,"error":{"code":<int>,"message":<str>,"data":<value|absent>}}
```

`LeanCli.LlmAgent.Bridge.parseResponse` accepts both shapes
(see `LeanCli/LlmAgent/Bridge.lean:54-74`). `leancli-agent` MUST
preserve this contract byte-for-byte. Methods served:

- `ping` → `{ ok: true, protocol: "0.0.1" }`
- `version` → `{ protocol, parseIntent: { selector, localBaseUrl, … } }`
- `llm.parseIntent` → the model's raw final-turn JSON as
  `{ raw: <string>, backend: "lean-agent", model, toolTurns, toolTrace }`

## Linux + libcurl ≥ 7.80 assumption

The HTTP FFI shim `c/lean_http/` targets libcurl ≥ 7.80 (released
December 2021; default on every supported distro). It uses the
multi-decade-stable `curl_easy_*` interface — no `mime`, no `ws`. The
shim is Linux-only by design (the rest of the project is too:
`Daemon/Uds.lean` uses `SO_PEERCRED`, etc.).

## Spec divergences (documented up front)

The Phase 0 spec was written before re-reading the tree; the deltas
below are intentional. Where the spec disagrees with the codebase, the
codebase wins.

1. **`bridge/llm/src/index.mjs` does not exist.** The entry point is
   `bridge/llm/bridge.mjs`. The legacy stdout contract was lifted from
   `bridge.mjs` + `clients/local-openai.mjs`.
2. **`bridge/llm/src/daemon-callback.mjs`** *does* exist (read).
3. **No `tx.nonce` or `tx.gasPrice` RPC.** The daemon exposes
   `chain.nonce` and `chain.gasPrice` — the agent maps to those.
4. **`LeanCli/Encoding/Json.lean` exists** and is the JSON layer; we
   use it (no need to introduce `Lean.Json`).
5. **`tui/src/screens/LlmDraftFlow.tsx` does not exist.** The TUI flow
   is `tui/src/screens/LlmChatFlow.tsx`, and it consumes the daemon's
   `chat.draft` / `llm.parseIntent` RPC — NOT the agent stdout
   directly. So the only consumer of `leancli-agent`'s stdout is
   `LeanCli.LlmAgent.Bridge.parseResponse`, and the byte-compatible
   target is the JSON-RPC envelope that module already parses.
6. **`ARCHITECTURE.md` says 60 Lean files; actual count is 111.** The
   doc update in step 14 rewrites the count line; spec acceptance
   command runs `find LeanCli -name '*.lean' | wc -l` against the
   final state.
7. **Spec's "extern_lib liblean_http" name** is preserved exactly; the
   pattern mirrors `extern_lib liblean_uds` in `lakefile.lean:29`.
8. **The C UDS shim uses `@[extern] opaque`**, not `axiom`. We follow
   that same pattern in `Agent/Http.lean` (the spec says "approved
   defaults: `@[extern] opaque` (not `axiom`)").
9. **`LlmAgent/Bridge.lean` default switch**: the spec says default to
   the installed `leancli-agent` with a dev fallback to
   `.lake/build/bin/leancli_agent` (lake's underscore form). The legacy
   path stays reachable via `LEANCLI_LLM_BRIDGE_LEGACY=1` →
   `bridge/llm-legacy/`. The existing `LEANCLI_LLM_BRIDGE` env
   override remains the highest-priority knob for either binary.

## Order of work (15 steps)

Mirrors the spec exactly. Each step ends with green `lake build` OR a
passing test. Commits land per step (commit subject prefixed
`phase0:`), authored as `nconsigny`, no Claude co-author.

1. Read pass + this `docs/PHASE0_PLAN.md` + commit.
2. `c/lean_http/{lean_http.h,lean_http.c}` + `script/setup_http.sh` +
   `extern_lib liblean_http` wiring. `lake build` clean.
3. `LeanCli/Agent/Http.lean` + tests. Build + tests pass.
4. `LeanCli/Agent/State.lean`. Build.
5. `LeanCli/Agent/Persona.lean` + `Prompt.lean`. Build.
6. `LeanCli/Agent/Tools.lean` + `ToolDefs/Decode.lean` + unit test.
7. Remaining `ToolDefs/*.lean`, one commit per tool.
8. `LeanCli/Agent/Llm.lean` + unit test.
9. `LeanCli/Agent/Loop.lean` + `LeanCli/App/AgentMain.lean` +
   `lean_exe leancli_agent`. Smoke step (a) works manually.
10. `LeanCli/LlmAgent/Bridge.lean` default switch + legacy env var.
11. Run smoke (or document deferred portions).
12. Rename `bridge/llm/` → `bridge/llm-legacy/`. Update build scripts.
13. Update `packaging/arch/PKGBUILD`.
14. Update `docs/ARCHITECTURE.md` (Module reference, entry points,
    native side table, sidecar bridges, trust boundary, file count).
15. Add `tests/agent_phase0_smoke.sh`.

## Acceptance gates (post step 15)

Run as real Bash tool calls; paste raw output:

```
git log --oneline master..HEAD
lake build
find LeanCli/Agent LeanCli/App/AgentMain.lean LeanCli/App/AgentDaemonMain.lean -type f 2>/dev/null \
  | xargs grep -lE "Crypto\\.Secp256k1Native|Crypto\\.Random|Wallet\\.(EOA|HDKey|Mnemonic|Entropy)|^import LeanCli\\.Keystore|^import LeanCli\\.Daemon\\.State" 2>/dev/null
find LeanCli c -type f \( -name '*.py' -o -name '*.ts' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.js' \) 2>/dev/null
grep -rniE "arbitrum|optimism|polygon|zksync|scroll|linea|blast" LeanCli/Agent LeanCli/App/AgentMain.lean LeanCli/App/AgentDaemonMain.lean 2>/dev/null
find LeanCli -name '*.lean' | wc -l
grep -E "^axiom" LeanCli/Agent/*.lean LeanCli/Agent/ToolDefs/*.lean LeanCli/App/AgentMain.lean LeanCli/App/AgentDaemonMain.lean 2>/dev/null
ls -la c/lean_http/ c/lean_sqlite/ LeanCli/Agent/ LeanCli/App/AgentMain.lean LeanCli/App/AgentDaemonMain.lean .lake/build/bin/leancli_agent .lake/build/bin/leancli_agentd 2>&1
```
