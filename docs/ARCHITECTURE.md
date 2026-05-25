# leanKohaku — Architecture

A map of the repository as it actually exists, complementing `README.md`
(goals & user-visible behavior), `INVARIANTS.md` (proof obligations & status),
and `CLAUDE.md` (build & contributor workflow).

The codebase is **140 Lean source files** plus C/Rust FFI helpers. There
are **no `sorry`s** in proofs and no `axiom`s outside the explicit FFI
boundary (opaque `Hacl` / `Tpm2` primitives, plus the `@[extern]`
declarations in `Daemon/Uds.lean`, `Agent/Http.lean`, and the Phase 1a
`Agent/Session.lean` SQLite shim). Every theorem in
`LeanKohaku/Invariants/` is closed.

## Layered structure

```
Entry points        LeanKohaku/App/{Main,DaemonMain,AgentMain,AgentDaemonMain}.lean
                        │
Surfaces            Cli/   RPC/   Daemon/   Agent/
                        │
Domain              Wallet/   Ethereum/   Keystore/   Contract/   Privacy/   Network/
                        │
Primitives          Crypto/   Encoding/
                        │
FFI boundary        c/hacl_helpers   c/secp256k1_helpers   c/lean_uds   c/lean_http
                    c/lean_sqlite    c/rustcrypto_helpers
```

`LeanKohaku.lean` is import-only and re-exports every module; downstream code
writes `import LeanKohaku`. Dependencies flow strictly downward.
`LeanKohaku/Invariants/` sits beside the layers and proves properties about
the abstract models defined alongside it (not about runtime IO).

## Module reference

### Entry points
- `LeanKohaku/App/Main.lean` — CLI executable root; thin wrapper over
  `LeanKohaku.Lib.Client` that dispatches argv via `Cli.Commands`.
- `LeanKohaku/App/DaemonMain.lean` — Daemon executable root; thin wrapper over
  `LeanKohaku.Lib.Core` that loads `Daemon.Config` from env and runs
  `Daemon.Server.run`.
- `LeanKohaku/App/AgentMain.lean` — `kohaku-agent` executable root.
  Phase-0 Lean-native replacement for the `bridge/llm-legacy/` Node
  sidecar. One-shot JSON-RPC over `--rpc '<json>'`; speaks to a local
  loopback LLM via `c/lean_http/` and to the daemon over UDS.
- `LeanKohaku/App/AgentDaemonMain.lean` — `kohaku-agentd` executable
  root. Phase-1a long-running sibling of `kohaku-agent`. Listens on
  `$XDG_RUNTIME_DIR/leankohaku/agent.sock`; persists session history
  in SQLite via `LeanKohaku/Agent/Session.lean`. Wire shape is
  newline-delimited JSON with the op set in `docs/PHASE1A_PLAN.md`.
- `LeanKohaku/Lib/{Client,Core,Spec}.lean` — aggregate library roots
  (CLI surface, daemon/runtime surface, proof/spec surface) consumed by the
  three `lean_lib` targets in `lakefile.lean`.

### `Crypto/` — primitives, no IO above `Hacl`/`Random`
- `Hex.lean` — hex encode/decode.
- `Secp256k1.lean` — pure curve spec (Point, Signature, modular arithmetic).
- `Secp256k1Native.lean` — IO wrapper that shells out to
  `leankohaku-secp256k1-{sign,pubkey,recover,verify}`.
- `Hacl.lean` — 8 `opaque` declarations for keccak256, sha256, hmac-sha256/512,
  ripemd160, pbkdf2, hmac-drbg, chacha20-poly1305 (HACL\*/libsecp256k1).
- `Random.lean` — `/dev/urandom` reader.

### `Encoding/`
- `Json.lean` — dependency-free JSON parser/printer.
- `Rlp.lean` — Ethereum RLP encoder for tx payloads.

### `Ethereum/`
- `Chain.lean` — chain config (mainnet/sepolia constructors).
- `Address.lean` — 20-byte EIP-55 address with dependent-pair proof of length.
- `Tx.lean` — `TxEip1559` (unsigned) and `SignedTx` with RLP encoding.
- `P256Precompile.lean` — pure model of EIP-7951 / 0x100 (P-256/R1) verify.
- `Abi.lean` — minimal ERC-20 ABI encoding.

### `Wallet/`
- `Account.lean` — `AccountKind` (eoaK1, r1Smart), `KeySource`, `DerivationPath`,
  `AccountPolicy`.
- `Mnemonic.lean`, `Bip39Wordlist.lean`, `Bip44.lean`, `HDKey.lean`,
  `Entropy.lean` — BIP-39/32/44 derivation. Wordlist is compile-time const.
- `Address.lean` — keccak-256 address from secp256k1 uncompressed pubkey.
- `EOA.lean` — EIP-1559 signing helpers (digest, signing, native bridge).
- `EoaStore.lean` — record schema for persisted EOA metadata.

### `Keystore/`
- `Enclave.lean` — abstract backend model (`linuxTpm2`, `fido2SecurityKey`,
  `linuxKernelKeyring`, `enclave`), curve, policy, user-auth.
- `Linux.lean` — vendor/hardware-class detection rules (HP, Lenovo first).
- `Tpm2Runtime.lean` — TPM2 boundary that shells out to `tpm2-tools`
  (`CreateStatus`, `SignStatus`, report types).

### `Contract/`
- `R1Account.lean` — Lean spec of the R1 smart-account contract: `PublicKey`,
  `Signature`, `UserOperation`, `State`, `toPrecompileInput`. Verifier hook is
  abstract over EIP-7951.

### `Privacy/`
- `NetworkPolicy.lean` — deny-by-default `Peer × Purpose × Transport → Bool`.
  `strictCliPolicy` (CLI may only talk to the local daemon),
  `strictDaemonPolicy` (loopback to local node),
  `torDaemonPolicy` (Tor to a configured node).

### `Network/`
- `Provider.lean` — transport-only `Backend` and `RpcMethod` enums.
- `Endpoint.lean` — endpoint descriptor.

### `RPC/`
- `JsonRpc.lean` — JSON-RPC 2.0 client. Methods classified `broadcastTx`
  vs `nodeRead`; calls go through the network policy and `curl`.
- `Server.lean` — inbound JSON-RPC parser skeleton (newline-delimited).

### `Daemon/`
- `Config.lean` — env-backed config (socket path, chain id, network policy).
- `Log.lean` — JSON-line stderr logger.
- `State.lean` — `IO.Ref`-backed state for unlocked EOA slots with TTL purge.
- `Uds.lean` — 9 `@[extern]` Unix-domain-socket FFI bindings (`lk_uds_*`).
- `Server.lean` — accept loop; routes wallet RPC over UDS under policy.
  Phase 1d adds the `wallet.lean_verified_addresses` read-only RPC
  (BIP-44 + R1 enumeration with hardcoded path allowlist and bounded
  per-path count from `Config.trustedRegistryMaxPerPath`, default 5).
  See `docs/PHASE1D_THREAT_MODEL.md`.

### `Cli/`
- `Commands.lean` — `Command` ADT, validation, preflight against the privacy
  policy (~480 lines).
- `DaemonClient.lean` — UDS client.
- `Passphrase.lean` — passphrase prompting.
- `MemoryCmd.lean` — Phase-1c `kohaku memory show / edit /
  refresh / forget` subcommands. All four route through the
  `kohaku-agentd` UDS socket so the daemon stays the sole
  writer of `MEMORY.md`; `show` falls back to a direct file
  read when the daemon is down. `forget` refuses patterns
  shorter than 4 chars (operator-error guard). Deliberately
  does not import `LeanKohaku.Agent.*` to keep the CLI surface
  decoupled from the agent module tree.

### `Agent/` — Lean-native LLM agent (Phase 0)
- `State.lean` — `Role`, `ToolCall`, `AgentMessage`, `AgentConfig`,
  `AgentState`. No IO. No crypto imports.
- `Http.lean` — loopback-only HTTP wrapper over `c/lean_http`. The
  string-prefix loopback check is redundant with the C floor.
- `DaemonClient.lean` — one-shot UDS JSON-RPC client used by every
  chain-reading tool. Contains the only `partial def` in the agent
  tree (`drainConn`, tagged `PHASE_N: prove termination`).
- `Tools.lean` — `ToolDecl`/`ToolRegistry`/`dispatch`. Allowlist
  enforced in code before any tool runs.
- `ToolDefs/{Decode,Simulate,Chain,Propose}.lean` — the seven
  default tools mapping to existing daemon RPCs
  (`tx.decodeIntent`, `eip712.decodeIntent`, `tx.simulate`,
  `chain.ethCall`, `chain.nonce`, `chain.gasPrice`); `propose_send`
  is local and emits a draft `{to, value, data, chainId}` envelope.
- `Persona.lean` + `Prompt.lean` — system-prompt assembly: frozen
  persona, operational rules (chain whitelist [1, 11155111], step
  budget, single `propose_send` final-answer shape), auto-generated
  tool docs. Phase-1d section order is
  `Persona → Memory → Trusted Registry → AlwaysOn skills →
   Trigger skills → Operational rules → Tool docs`. The Trusted
  Registry block is omitted when the wallet's seed is locked; the
  operational rules then carry a one-line `lockedSeedAddendum` so the
  LLM does not silently invent ownership claims.
- `Llm.lean` — OpenAI-compatible chat completions client. Pure
  request/response shaping.
- `Loop.lean` — bounded `runOneShot` loop (`partial def`, tagged
  `PHASE_N: prove termination`).
- `Registry.lean` — the default 8-tool registry (Phase-0 seven plus
  Phase-1d `trusted_registry_list`). `defaultWithSkills` extends it
  with the two Phase-1b protocol-lookup tools.
- `Session.lean` — Phase-1a SQLite-backed session/message store
  with FTS5 search. Schema bootstrap is idempotent and version-
  gated. Used by `kohaku-agentd`; one-shot `kohaku-agent` does
  not touch it. No signing or key-material imports — the DB
  carries conversation history only.
- `Skills.lean` — Phase-1b in-process skill registry. Walks
  `skills/<name>/` one level deep at startup, parses YAML
  frontmatter (`name`, `triggers`, `alwaysOn`),
  and exposes trigger matching + compact prompt rendering. The
  registry is held behind an `IO.Ref` so the daemon's `reload`
  op can hot-swap content without restart (Lean 4 v4.29.1 has
  no POSIX signal API, so `reload` is wired as a socket op,
  not a SIGHUP). Pure file IO and string manipulation — same
  forbidden-import gate as the rest of `Agent/`.
- `ToolDefs/Protocols.lean` — `protocol_lookup` and
  `protocol_function_lookup`. Both read-only, both bound to a
  `Skills.RegistryRef` at construction time.
- `ToolDefs/TrustedRegistry.lean` — Phase-1d `trusted_registry_list`.
  Surfaces the daemon's `wallet.lean_verified_addresses` RPC to the
  agent and provides the `Snapshot` shape consumed by
  `AgentDaemonMain.lean`'s `registryRef` cache. The tool is the only
  source of truth for "addresses the user owns" in the system prompt;
  see `docs/PHASE1D_THREAT_MODEL.md`.
- `Memory.lean` + `MemoryPrompts.lean` — Phase-1c long-term
  memory store. The agent persists a small markdown file
  (`MEMORY.md`, 0600 mode, 0700 parent dir) under
  `$XDG_DATA_HOME/leankohaku/`. The daemon is the sole writer:
  it loads at startup, renders into every system prompt
  (omitted entirely when empty), and updates either on demand
  (`update_memory` op) or via LLM-driven extraction at
  `close_session` (`extract_memory` op). A defence-in-depth
  post-extraction filter drops any line matching a private-key
  shape (`\b0x[a-fA-F0-9]{64}\b`), a BIP-39 mnemonic shape
  (12+ consecutive lowercase ASCII words), or a signing-API
  method name. Output is capped at 8 KiB at the last newline
  boundary. The extraction prompt itself
  (`MemoryPrompts.extractionInstructions`) carries the policy
  the model is asked to honour. Forbidden-import gate still
  empty.
- `Compression.lean` — Phase-1c token-budget transcript
  compression. Before every chat round in the persistent agent
  daemon, the loop estimates the transcript's token count
  (word-count × 1.4; tunable via `KOHAKU_TOKEN_RATIO`) and, if
  it exceeds the trigger threshold (default 6000), asks the
  LLM to summarise the middle of the transcript into a single
  `[Earlier in session, summarised]` system message. The first
  system message and the last `keepLastTurns` user/assistant
  turn pairs are preserved verbatim. Idempotent by
  construction (`targetTokens < triggerTokens`). Failure is a
  graceful no-op — the agent loop never crashes on a
  compression error.

The full trust contract: nothing in `Agent/` imports
`Crypto.Secp256k1Native`, `Crypto.Random`, `Wallet.{EOA,HDKey,
Mnemonic,Entropy}`, `Keystore/**`, or `Daemon.State`. The agent
proposes; the daemon signs. The Phase-1a `AgentDaemonMain.lean`
joins this gated set; the CI grep gate is extended accordingly.

### `Invariants/` — all proofs closed, no `sorry`
- `Core.lean` — top-level safety: no key exfiltration, verified-only signing,
  chain match, approval requirement, signer/path separation, R1 ↔ TPM policy.
- `Amount.lean` — invariant **1.1** (`subChecked_preserves_total`).
- `Wallet.lean` — invariant **1.2** (`apply_some_affordable`,
  `apply_sender_debited`, `apply_non_sender_balance`).
- `TxWellFormed.lean` — invariants **2.1**, **2.3** by definition.
- `Account.lean`, `Keystore.lean`, `Network.lean`, `Nonce.lean`,
  `Mainnet.lean`, `R1Account.lean` — domain-specific safety theorems.

## Native side (`c/`, Rust)

| Path | Wraps | Purpose |
|------|-------|---------|
| `c/hacl_helpers/` | HACL\* | keccak256 (Ethereum, delim 0x01), sha256, hmac-sha256/512, pbkdf2, hmac-drbg, chacha20-poly1305 |
| `c/hacl_helpers/ripemd160_*` | HACL\* | RIPEMD-160 for BIP-32 HASH160 |
| `c/secp256k1_helpers/` | libsecp256k1 | sign / pubkey / recover / verify (hex in/out CLI helpers) |
| `c/lean_uds/lean_uds.c` | POSIX | `bind/accept/connect/read/write/close/shutdown`, peer-uid/current-uid |
| `c/lean_http/lean_http.c` | libcurl | loopback-only HTTP POST for `kohaku-agent`. Refuses non-`http://127.0.0.1`/`http://[::1]`/`http://localhost` URLs at the C layer. 8 MiB response cap. No TLS, no redirects. |
| `c/lean_sqlite/lean_sqlite.c` | libsqlite3 | Phase-1a SQLite shim consumed by `LeanKohaku/Agent/Session.lean`. Links against the system libsqlite3 (Arch + Debian 12+ ship FTS5 enabled). Column-text bytes are copied out before further DB calls. |
| `c/rustcrypto_helpers/` | RustCrypto | optional Rust ripemd160 binary |

Build automation: `script/setup_hacl.sh`, `script/setup_secp256k1.sh`,
`script/setup_uds.sh`, `script/setup_http.sh`, `script/setup_sqlite.sh`
(Phase 1a; header + FTS5 probe). The UDS, HTTP, and SQLite C libs are
linked into the Lean library via `extern_lib liblean_uds`,
`extern_lib liblean_http`, and `extern_lib liblean_sqlite` in
`lakefile.lean`; the package-level `weakLinkArgs` pins
`/usr/lib/libcurl.so`, `/usr/lib/libsqlite3.so`, and
`-Wl,--allow-shlib-undefined` so the bundled lld accepts libsqlite3's
DT_NEEDED dependencies on libc/libpthread (merged into glibc 2.34+).
The other helpers are external binaries invoked at runtime.

## Companion artifacts outside the main library

- `Contracts/R1Account/` — separate Lean tree for the R1 smart-account
  contract: `R1Account.lean`, `Spec.lean` (Verity formalism: `initializedSpec`,
  `executeAcceptedSpec`, `executeRejectedSpec`), `Invariants.lean`,
  `Proofs/Basic.lean`. Toolchain integration is still being settled.
- `solidity/dev/R1AccountDev.sol` — Solidity dev variant for Sepolia.
- `script/r1_sepolia.sh`, `script/setup_verity.sh`,
  `script/compile_r1_verity.sh`, `script/check_privacy_cli.sh` — provisioning
  and CI helpers.
- `packaging/arch/PKGBUILD` — Arch Linux package (lake build, install both
  binaries plus `docs/`).
- `docs/CLI.md`, `docs/DAEMON.md`, `docs/PRIVACY_SECURITY.md`,
  `docs/R1_SEPOLIA.md`, `SECURITY.md` — user
  documentation.

### Sidecar bridges (`bridge/`) and the Lean-native agent

Phase 0 split the LLM backend into a Lean-native primary (`kohaku-agent`)
and an opt-in legacy Node sidecar. Phase 1a adds a long-running sibling
`kohaku-agentd` selected automatically by `LlmAgent.Bridge.resolveMode`.
The other two bridges remain Node.

Modes:

* **One-shot (Phase 0 default)** — Spawn `kohaku-agent`, pass the
  request as `--rpc <json>` on argv, read one line of stdout, reap.
* **Persistent (Phase 1a, opt-in)** — Talk to a running `kohaku-agentd`
  over `$XDG_RUNTIME_DIR/leankohaku/agent.sock`. Session history is
  persisted in `$XDG_DATA_HOME/leankohaku/sessions.db` with FTS5
  search. Auto-detected: the bridge pings the socket; if `ok`, uses
  persistent, else one-shot.
* **Legacy Node sidecar** — `bridge/llm-legacy/bridge.mjs`, opt-in
  via `LEAN_KOHAKU_LLM_BRIDGE_LEGACY=1`.

Mode resolution order: env override → legacy → socket probe → one-shot.
Persistent mode that explicitly fails to contact the agent does NOT
silently fall back. See `docs/PHASE1A_PLAN.md` for the full wire
shape; `LeanKohaku/LlmAgent/Bridge.lean` is the only path the wallet
daemon takes into either kohaku backend.

Each bridge is treated as untrusted; every output flows through the
existing decode → simulate → ConfirmGate gate before any signing.

| Backend | Lean wrapper | Executable env var | Purpose |
|---|---|---|---|
| `kohaku-agent` (in-tree Lean, one-shot) | `LeanKohaku/LlmAgent/Bridge.lean` | `LEAN_KOHAKU_LLM_BRIDGE` (override) | Phase 0 primary. Spawn-per-call. Loopback HTTP via `c/lean_http`; talks to wallet daemon over UDS. |
| `kohaku-agentd` (in-tree Lean, persistent) | `LeanKohaku/LlmAgent/Bridge.lean` | `LEAN_KOHAKU_AGENT_MODE`, `KOHAKU_AGENT_SOCKET` | Phase 1a opt-in. Long-running UDS sidecar; persists session history in `$XDG_DATA_HOME/leankohaku/sessions.db` via FTS5. Auto-detected. |
| `bridge/llm-legacy/` (Node fallback) | `LeanKohaku/LlmAgent/Bridge.lean` | `LEAN_KOHAKU_LLM_BRIDGE_LEGACY=1` | Opt-in fallback. Anthropic SDK + viem; `ANTHROPIC_API_KEY` enables the model fallback. Kept for parity tests. |
| `bridge/` | `LeanKohaku/Privacy/Bridge.lean` | `LEAN_KOHAKU_BRIDGE` | Privacy Pools / Railgun (snarkjs, libp2p) |
| `bridge/clearsign/` | `LeanKohaku/Clearsign/Bridge.lean` | `LEAN_KOHAKU_CLEARSIGN_BRIDGE` | ERC-7730 calldata + EIP-712 walker |

The clearsign sidecar bundles ERC-7730 descriptors under
`bridge/clearsign/registry/` (ERC-20, Uniswap V3 SwapRouter02, Permit2,
CowSwap order EIP-712, plus a `4byte.json` fallback dict). The Lean
agent's chain-context surface lives in `LeanKohaku/Agent/ToolDefs/Chain.lean`
and routes every read through the daemon's `chain.ethCall` /
`chain.nonce` / `chain.gasPrice` RPCs under the standard
`Privacy.NetworkPolicy` gate — same trust model as the legacy sidecar's
`daemon-callback.mjs`, but no Node process involved.

### Skills pack (`skills/`)

Two parallel skills layers share the `skills/` root:

* **Action skills** (verb-named: `send-native`, `approve-erc20`,
  `swap-uniswap-v3`, etc.) belong to `LeanKohaku/Daemon/SkillsStore.lean`
  and are exposed via the daemon RPCs `skills.list` and
  `skills.get`. They were the pre-Phase-1b layer.
* **Protocol + meta skills** (`uniswap`, `aave`, `railgun`,
  `tornado-cash`, `cowswap`, `morpho`, `fxusd`, `bold-liquity`,
  `privacy-pool`, plus `kohaku-wallet` and `web3-security`) belong
  to `LeanKohaku/Agent/Skills.lean` and are consumed at LLM-prompt
  assembly time. The two meta-skills are always-on; protocol
  skills activate by trigger-keyword match against the latest user
  message + tool outputs.

Both layers read from the same directory tree; their parsers tolerate
each other's frontmatter (the action-skill parser ignores
`triggers`/`alwaysOn`; the Phase-1b parser ignores
`category`/`risk`). See `docs/PHASE1B_PLAN.md` for the divergence
record.

The agent daemon resolves the skills directory in this order:

1. `KOHAKU_AGENT_SKILLS_DIR` env override.
2. `$XDG_DATA_HOME/leankohaku/skills` if present (user override).
3. `/usr/share/leankohaku/skills` (PKGBUILD-installed location).
4. `<cwd>/skills` (dev fallback — the in-tree path).

`reload` over the daemon socket re-walks the resolved path and
swaps the in-memory registry atomically under all active readers.

### Incognito mode (Phase 1c)

Setting `LEAN_KOHAKU_INCOGNITO=1` (e.g. via `kohaku tui
--incognito`, which sets the env for the TUI subprocess) flips
the LLM bridge into incognito mode for the duration of that
process. Behaviour:

- The bridge propagates `{"incognito": true}` in the
  `create_session` metadata when it opens a new agent session.
- `kohaku-agentd` registers the returned `session_id` in an
  in-memory incognito set. For the lifetime of that session,
  `appendMessage` is a no-op (zero rows in `sessions.db`).
- On `close_session`, the daemon skips the memory-extraction
  auto-trigger for incognito sessions.
- The per-turn response carries an `incognito` boolean back so
  downstream UIs can render a marker. Visual marker design is
  not part of the verified core.

Incognito is a hard switch: the daemon does not "downgrade" the
flag mid-session, and the bridge does not "fall through" to a
non-incognito session if the daemon is unreachable. If the user
asked for incognito, an unreachable daemon is a failure.

### Terminal UI (`tui/`)

`tui/` is an Ink-based TUI bundled with esbuild to a single
`dist/index.mjs`. Reachable via `kohaku tui`; the launcher in
`Cli/Runtime.lean` resolves the bundle from `<bin>/../share/leankohaku/tui/`
or the local dev path. Notable screens:

- **MainMenu** — Wallets / Create / Import / Privacy Pools / Daemon / More.
- **Wallets → ActionPicker** — Send / Shield / History / Lock-toggle / etc.
- **SendFlow** — EOA send goes unlock → simulate → `ConfirmGate` → sign.
  TPM/R1 send routes through `r1.sendEthSepolia`. Both render token
  movements via `widgets/TransfersBlock.tsx` (parses `tx.simulate`'s trace).
- **SendRawFlow** — generic confirm-and-sign for arbitrary `{to, value,
  data}`; reused by the LLM agent's "approve & sign" handoff.
- **DecodeIntentFlow** / **DecodeTypedDataFlow** — paste calldata or
  EIP-712 JSON, see the rendered intent + simulator output. Read-only.
- **LlmDraftFlow** — natural-language prompt → drafts → review with decode +
  sim → "Approve & sign" pushes to `SendRawFlow`.

## Trust boundary summary

Inside Lean and provable: hex/RLP/JSON encoding, address derivation logic,
EIP-1559 tx structure, P-256 precompile shape, network-policy decisions,
abstract wallet accounting, nonce monotonicity, R1 account state machine.

Trusted (not proved in Lean):
- HACL\* hash/MAC/AEAD primitives (`Crypto/Hacl.lean` — `opaque`).
- libsecp256k1 sign/verify/recover (`Crypto/Secp256k1Native.lean` — IO via
  helper binaries).
- TPM2 hardware operations (`Keystore/Tpm2Runtime.lean` — `tpm2-tools` shell-out).
- POSIX UDS syscalls (`Daemon/Uds.lean` — `@[extern]`).
- The loopback HTTP shim (`Agent/Http.lean` + `c/lean_http/` — `@[extern]`).
  Trusted as an *opaque transport* only: the loopback restriction is
  C-enforced and re-checked in Lean, and the agent treats every byte the
  LLM returns as adversarial input that must traverse the standard
  decode → simulate → ConfirmGate pipeline before any signing.
- The SQLite shim (`Agent/Session.lean` + `c/lean_sqlite/` — `@[extern]`)
  used only by `kohaku-agentd`. Trusted as an *opaque local store* —
  it never sees key material (the agent import graph forbids signing
  modules) and DB content never authorises signing.
- The MEMORY.md file (`Agent/Memory.lean`, Phase 1c). Same trust
  shape as the session DB: an opaque local store, written
  exclusively by `kohaku-agentd` via atomic `tmpfile + rename`,
  mode 0600 under a 0700 parent dir. The post-extraction filter
  in `Memory.postFilter` is the second line of defence against
  the LLM proposing key-shaped or mnemonic-shaped content; the
  prompt itself (`MemoryPrompts.extractionInstructions`) is the
  first. Memory content is read into every new session's system
  prompt; it never authorises signing.
- The C/Rust helpers in `c/` and the binaries on `$PATH`.

The split is deliberate: the wallet's signing path is reasoned about in Lean,
while the underlying field/group/hash math is delegated to audited C libraries
behind a narrow opaque interface.

## Known gaps

- Daemon config supports JSON files plus env overrides; systemd unit
  installation still needs packaging verification on target distros.
- No Mathlib dependency, so secp256k1 group-law proofs are out of scope until
  it is added (see `lakefile.lean` comment).
- Verity-based R1 contract proofs depend on toolchain settlement.
- No separate test runner; `lake build` is the test suite (proofs as tests,
  per `CLAUDE.md`).
