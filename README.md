# leanCLI

**Research wallet.** A Lean 4 Ethereum wallet daemon with a CLI-first surface
and an Ink-based TUI. Lean owns the orchestration code (network policy,
account policy, transaction framing, JSON/RLP encoding, daemon dispatch,
abstract account/contract models) and a growing set of machine-checked
invariants over it. Cryptographic primitives, ZK circuits, EVM simulation,
ERC-7730 walking, the natural-language drafting agent, and post-quantum
signing live in untrusted sidecars or native helper binaries. Every produced
calldata is gated through a `decode → simulate → user-confirm` pipeline
before any signing.

Most of the load-bearing crypto is *not* in Lean it lives in vetted external implementations called over
process boundaries. The proof effort is over the orchestration layer, not the
primitives. See [INVARIANTS.md](./INVARIANTS.md) for the proof inventory and
[What is verified vs trusted](#what-is-verified-vs-trusted) below for the
trust surface.

## Install

One-liner :

```bash
curl -fsSL https://raw.githubusercontent.com/nconsigny/leanCLI/master/ops/scripts/leanclispawn | bash
exec $SHELL -l                                 # pick up PATH
leancli help
```

This downloads `leanclispawn` and runs it. With no checkout in scope, the
script clones the repo into `~/.leancli/checkouts/leanCLI/`, runs `lake
build`, and self-installs into `~/.leancli/bin/`. You'll need `elan`,
`git`, and (for the TUI) `node` ≥ 20 on your `PATH`.

If you'd prefer to clone the repo yourself first:

```bash
git clone https://github.com/nconsigny/leanCLI.git && cd leanCLI
elan toolchain install $(cat lean-toolchain)   # one-time: installs Lean 4.29.1
./ops/scripts/leanclispawn                       # build + install in-tree
exec $SHELL -l
leancli help
```

After install, the `leancli` CLI itself owns install/update/uninstall —
no need to remember a separate `leanclispawn` command:

```bash
leancli install        # rebuild + relink (e.g. after editing source)
leancli update         # git pull + rebuild + relink
leancli uninstall      # remove ~/.leancli/bin symlinks
```

These three subcommands delegate to `ops/scripts/leanclispawn` under the hood,
so any `leanclispawn` flag still works if you call the script directly.

What the bootstrap does:

1. `lake build` (Lean lib + `leancli` + `leancli-daemon`).
2. `npm install && npm run build` under `tui/` for the Ink TUI bundle.
3. Creates `~/.leancli/bin/` with:
   - `leancli`         → symlink to `.lake/build/bin/leancli`
   - `leancli-daemon`  → symlink to `.lake/build/bin/leancli-daemon`
   - `leanclispawn`       → copy of the script (still callable directly)
4. Records the checkout location in `~/.leancli/checkout` so subsequent
   `leancli install` / `leancli update` runs know where to rebuild from.
5. Appends a guarded `export PATH="$HOME/.leancli/bin:$PATH"` block to
   your shell rc (`.zshrc`, `.bashrc`, or `config.fish`). Skip with
   `./ops/scripts/leanclispawn --no-modify-path`.

Direct script flags (when you want finer control than the subcommands):
`--no-build`, `--no-tui`, `--rebuild-tui`, `--force` (overwrite a stale
`leancli` symlink), `--no-modify-path`, `--pull`, `--uninstall`.

Bootstrap-mode env overrides:

| Variable | Default | Purpose |
|----------|---------|---------|
| `LEANCLI_HOME` | `~/.leancli` | Install root (`bin/`, `checkouts/`, `checkout` marker live under it) |
| `LEANCLI_REPO_URL` | `https://github.com/nconsigny/leanCLI.git` | Repo to clone when no checkout is found |
| `LEANCLI_REPO_DIR` | `$LEANCLI_HOME/checkouts/leanCLI` | Where the auto-clone lands; point at an existing clone to skip cloning |
| `LEANCLI_LEANCLISPAWN` | unset | Override the path the `leancli` CLI exec's for `install` / `update` / `uninstall` |

If you'd rather skip the installer entirely:

```bash
lake build
export PATH="$PWD/.lake/build/bin:$PATH"
# binaries are named `leancli` / `leancli-daemon` in this mode
```

Nix scaffolding is available:

```bash
nix build
nix develop
```

The Arch Linux scaffold lives in `ops/packaging/arch/`. Replace the placeholder
repository URL before publishing a package.

### macOS notes

Untested on the author's machine — neither CI nor the author runs macOS
day-to-day — but the build is structured to work there. If something
breaks, this section is the first place to look.

Prereqs (Homebrew):

```bash
brew install elan-init cmake ninja git
# Xcode Command Line Tools provide `cc`/`clang`, libsqlite3, and libcurl:
xcode-select --install
# Optional: only needed for the Ink TUI (`tui/`) and any Node sidecar:
brew install node
```

Then the standard `leanclispawn` / `lake build` flow works the same as
on Linux. systemd-related steps no-op (leanclispawn checks
`command -v systemctl`); the daemons run via autospawn instead.

Runtime-dir behavior: macOS doesn't set `XDG_RUNTIME_DIR`, so the
daemons fall back to `$TMPDIR` (launchd's per-user mode-0700 dir
under `/var/folders/...`). UDS paths become e.g.
`$TMPDIR/leancli/leancli.sock` — same posture as on Linux, just
under a longer prefix. macOS's `sun_path` limit is 104 bytes; if you
ever hit "UDS path is too long", set `LEANCLI_SOCKET` /
`LEANCLI_AGENT_SOCKET` to a shorter absolute path.

Native helpers: the HACL and secp256k1 setup scripts assume `cc`,
`cmake`, `ninja`, and (HACL only) `cargo` on `PATH` — all available
via brew. The Secure Enclave / TPM2 runtime layers are modeled in
the keystore but not wired up; software-fallback keystores work.

## Configure RPC

Two commands cover everything — each one propagates to balance, send,
swap, and (for mainnet) ENS resolution:

```bash
leancli network set-rpc-chain mainnet https://your-mainnet-rpc/
leancli network set-rpc-chain sepolia https://your-sepolia-rpc/
leancli network show       # resolved URLs + source (env vs daemon.json)
```

ENS always resolves against mainnet. Setting the mainnet RPC above is
enough; only use `leancli network set-ens-rpc <url>` if you want a
different mainnet endpoint for ENS than for everything else.

Equivalent `.env` entries — both CLI and daemon autoload `./.env` and
`${XDG_CONFIG_HOME:-$HOME/.config}/leancli/.env`:

```bash
MAINNET_RPC_URL=https://your-mainnet-rpc/
SEPOLIA_RPC_URL=https://your-sepolia-rpc/
```

Shell env beats `.env`. Disable autoload with `LEANCLI_NO_DOTENV=1`.
See `.env.example` for the rest (transport, policy, chain id, Tor mode).

## Quick start

```bash
leancli help
leancli version
leancli policy                  # overview of policy topics
leancli policy privacy          # network privacy summary
leancli policy security         # hard rules + checks
leancli policy keystore         # custody policy
leancli policy accounts         # account families
leancli policy lightclient      # provider-policy plan
leancli policy all              # everything in one print
leancli network                 # current network config (rpc urls + sources)
leancli doctor                  # privacy/security status
leancli wallet create eoa work-key
leancli wallet list
leancli balance 0x0000000000000000000000000000000000000000
leancli send 0x0000000000000000000000000000000000000000 1
leancli from daily send 0x0000000000000000000000000000000000000000 1
leancli debug policy-check strict configured-node broadcast-tx direct
leancli debug rpc-check tor configured tor eth_sendRawTransaction
leancli debug endpoint-check strict local http loopback false
leancli debug decode erc20 0xa9059cbb...
leancli daemon ping
leancli daemon                  # starts the daemon in the foreground
leancli tui                     # opens the Ink TUI (menu → Dashboard for the
                                # multiplexed chat + wallet/RPC/network/llama.cpp view)
```


## Goals

- **CLI-first.** Local CLI talks to a long-running daemon over a Unix socket.
- **Lean orchestration with machine-checked invariants.** CLI/daemon policy,
  abstract wallet/account/contract models, network and keystore policy live
  in Lean alongside their proofs. We grow `INVARIANTS.md` from 📝 *stated*
  → 🚧 *in-progress* → ✅ *proved*; some are 🔒 *axiomatized* at FFI
  boundaries on purpose.
- **Untrusted sidecars at the boundary.** All ZK / EVM / decoder / NL /
  post-quantum work runs in pinned external processes treated as malicious.
  The daemon re-decodes everything they emit and routes every produced
  calldata through `tx.decodeIntent → tx.simulate → ConfirmGate` before
  signing.
- **Privacy and security by default.** Network policy is deny-by-default,
  classified by peer / purpose / transport, with strict and Tor modes
  proved against third-party API access.
- **Local enclave-first key custody.** TPM2 / FIDO2 / Apple Secure Enclave
  for local custody; never an online keystore, never raw secret
  import/export. TPM2 backs the wallet master-KEK (PIN-bound), not an
  account kind.
- **Two account families.** BIP-39/32 EOAs (k1) and, on Sepolia, SPHINCS+
  hybrid accounts as a research post-quantum family.
- **Ethereum mainnet first, Sepolia for dev.**

## Non-goals (for now)

- Production readiness — this is a research wallet.
- Browser / mobile UI.
- WalletConnect / OpenLV. We deliberately bypass dApp integrations: the
  LLM agent drafts calldata in natural language; the ERC-7730 walker
  renders intent for any pasted calldata; Colibri or `eth_call` simulates
  what tokens actually move. The user confirms ground-truth simulated
  effects, not dApp marketing copy.
- Reimplementing crypto, ZK, EVM, or light-client logic in Lean.

## What is verified vs trusted

The trust boundary is concrete. If something is not in the "verified"
column, treat it as trusted code.

### ✅ Lean-verified (machine-checked)

These properties have non-`sorry` Lean proofs. See
[INVARIANTS.md](./INVARIANTS.md) for the full list and theorem names.

- Verified-core properties (Cat 0): no key exfiltration, no raw signing
  oracle, no wrong-chain signing, approval / signer-kind correspondence,
  EIP-7702 delegation guardrails.
- Amount arithmetic (Cat 1): checked subtraction never underflows;
  multi-output sends conserve total balance and only debit affordable
  amounts.
- EIP-1559 fee relation and chain-ID match (Cat 2, by definition).
- Account policies are supported-chain and local-only (4.3); JSON
  destructors agree with constructors (4.4).
- Bridge policy classification AND runtime gate (5.7): every shielded
  method maps to a network purpose, and a policy-denied shielded request
  is refused before the sidecar is spawned (no shielded egress without
  policy permission).
- Network policy (Cat 6 + 7): CLI only contacts the local daemon; daemon
  policies deny third-party peers; strict mode denies configured-node
  access; Tor mode is transport-scoped; non-broadcast methods classify as
  reads.
- Keystore (Cat 8): accepted requests never export secrets, are local-
  only, require user authorization; Linux HP/Lenovo profiles select TPM2
  first.
- SPHINCS+ hybrid account contract (Cat 12): nonce monotonicity, hybrid
  signature gate (ECDSA AND SPHINCS+), rotation isolation, key
  supersession after rotation, owner-rotation safety.
- Uniswap V3 swap helper (Cat 11): zero-slippage identity; balances
  candidates are chain-correct.
- Bridge response framing (5.8): the daemon cannot mistake a sidecar
  crash for a successful proof.
- LLM-agent address resolution (Cat 14): `.verified` witnesses are backed
  by an actual on-disk-seed derivation, not a sidecar claim.

### 🚧 Stated but not yet proved

Sketched in `INVARIANTS.md` with a Lean proposition; proof partial or
absent. Treat these as design intent, not guarantees.

- 2.2 Calldata-aware intrinsic gas lower bound — only bare-transfer bound
  is currently in `wellFormed`.
- 3.1 Signed-amount integrity through CLI/TUI — requires threading a
  `UserIntent` type end-to-end.
- 3.2 Deterministic nonce use across restarts.
- 4.1 RLP roundtrip — only structural lemmas; full round-trip blocked on
  a non-`partial` decoder.
- 4.2 Hex roundtrip — nibble-level proved; byte-level lift pending.
- 5.1 / 5.2 Railgun double-spend / shield conservation — modeled
  informally only; the Railgun primitives live in the privacy bridge and
  are not re-derived in Lean.
- 5.3 Bridge cannot return spending-key material — by-construction
  inspection of `Privacy/Bridge.lean`, not a machine-checked predicate yet.

### 🔒 Cryptographically axiomatized

End-to-end security cannot be proved by Lean alone — collision resistance,
signature unforgeability, AEAD authenticity, KDF/PRF, and ZK soundness are
standard cryptographic *assumptions*. Each is documented in
`INVARIANTS.md` Cat 13 and bound to a specific external implementation:

- Keccak-256, SHA-256, HMAC-SHA-512, PBKDF2-HMAC-SHA-512,
  ChaCha20-Poly1305 → HACL Packages binaries (Project Everest).
- RIPEMD-160 → RustCrypto `ripemd` helper (HASH160 only, never
  Ethereum addresses).
- secp256k1 ECDSA → Bitcoin Core libsecp256k1 helpers.
- SPHINCS+ → vendored `sphincs/sphincsplus` reference (C) for
  SLH-DSA-SHA2-128-24, vendored `nconsigny/SPHINCS-/signer-wasm` (Rust)
  for the C9 parameter set.

See [`docs/CRYPTO_POLICY.md`](./docs/CRYPTO_POLICY.md) for exact pins and
the one-library-per-primitive policy.


### 🔌 Trusted external code (not modeled in Lean)

The proof corpus does not extend to:

- The Privacy Pools v1 SDK
  (`@kohaku-eth/{plugins,railgun,privacy-pools}`) and its snarkjs witness
  generation.
- The Colibri stateless light client (`@corpus-core/colibri-stateless`)
  used for `colibri_simulateTransaction`.
- The viem ABI walker, ERC-7730 descriptors, and 4-byte selector dict
  used by the clearsign sidecar.
- The LLM tool-use loop in the native `leancli-agent` (model output is
  treated as adversarial regardless).
- The Solidity contracts deployed on Sepolia: `SphincsAccount` at
  `0xA941116763AE386a50133c5af40356c9D93b2978`, the C9 verifier at
  `0x18F005EECd41624644AA364bA8857258FEB3C26D`, EntryPoint v0.9.
- The 0xBow ASP (third-party Approval Service Provider for Privacy Pools)
  and FastRelay broadcaster.

The mitigation for trusting external code is uniform: nothing the daemon
signs depends on what a sidecar *reports*. Every produced calldata is
re-decoded in Lean and run through `tx.simulate → ConfirmGate` before any
key touches it.

## Layout

```
leanCLI/
├─ lakefile.lean                  # Lake build config
├─ lean-toolchain                 # pinned Lean version (4.29.1)
├─ flake.nix / default.nix        # Nix scaffold
├─ LeanCli.lean                   # Root module (re-exports)
├─ LeanCli/
│  ├─ App/         CLI / daemon / agent executable roots
│  ├─ Crypto/      Hex, Hacl (opaque + IO helpers), Secp256k1Native
│  ├─ Encoding/    Json, Rlp
│  ├─ Ethereum/    Address, Chain, Tx, Abi, Eip712, Ens
│  ├─ Network/     Policy, Endpoint, Provider (incl. debug_traceCall)
│  ├─ Privacy/     Bridge (kohaku privacy-plugin host spawn)
│  ├─ Clearsign/   Bridge (ERC-7730 + EIP-712 spawn)
│  ├─ Helios/      Bridge, Persistent (light-client provider spawn)
│  ├─ Colibri/     Bridge, Persistent (light-client provider spawn)
│  ├─ SafeNode/    Persistent (TDX-attested ORAM proxy provider spawn)
│  ├─ LlmAgent/    Bridge, IntentParser (NL → tx draft)
│  ├─ Sphincs/     Bridge, UserOp (SPHINCS+ shim spawn, EIP-712 userOpHash)
│  ├─ Keystore/    Enclave, Linux, Tpm2Runtime, MasterKey
│  ├─ Contract/    SphincsAccount (abstract)
│  ├─ Swap/        UniV3, Tokens (abstract)
│  ├─ Wallet/      Account, Bip39Wordlist, Bip44, HDKey, EOA, EoaStore, …
│  ├─ Agent/       Loop, Llm, Session, Skills, Memory, Compression, …
│  ├─ RPC/         JsonRpc, Outbound, Server
│  ├─ Daemon/      Config, Log, State, TokenMeta, TxJournal, Uds, Server
│  ├─ Cli/         Commands, DaemonClient, Passphrase, NetworkConfig
│  └─ Invariants/  Amount, Wallet, TxWellFormed, Network, SphincsAccount,
│                  Swap, Bridge, Encoding, Keystore, Core, Mainnet,
│                  Account, AddressOwnership, …
├─ native/                        # Loopback FFI shims + crypto helper sources
│  ├─ hacl_helpers/    HACL* hashes / HMAC / KDF / AEAD / RIPEMD-160
│  ├─ secp256k1_helpers/  Bitcoin Core libsecp256k1
│  ├─ rustcrypto_helpers/ RustCrypto RIPEMD-160 (HASH160 only)
│  ├─ lean_uds/        Unix-domain socket primitives
│  ├─ lean_http/       loopback-only HTTP (agent LLM I/O, ENS)
│  └─ lean_sqlite/     SQLite shim (agent session store, FTS5)
├─ sidecars/                      # Untrusted sidecars (Kohaku plugin host)
│  ├─ kohaku/      Provider host (helios/, colibri/, safenode/) + privacy
│  │              plugins (@kohaku-eth/{railgun,privacy-pools}); plugins.lock.json
│  ├─ clearsign/   ERC-7730 walker + 4byte fallback + EIP-712 (viem)
│  └─ sphincs/     Local SPHINCS+ shims (C / Rust), vendored signers
├─ vendor/sphincs-minus/          # SPHINCS- signer submodule
├─ ops/                           # scripts/, packaging/, tests/
├─ docs/                          # ARCHITECTURE, DAEMON, CLI, PLUGIN_ARCHITECTURE,
│                                 # CRYPTO_POLICY, PRIVACY_SECURITY, …
├─ tui/                           # Ink-based TUI (esbuild-bundled)
├─ INVARIANTS.md                  # Living invariant inventory + proof status
├─ SECURITY.md                    # Trust boundary statement
└─ README.md
```

## Pre-sign pipeline

Every signing flow goes through the same gate before reaching `eoa.send`
or any SPHINCS+ flow:

```
  build {to, value, data}
        ↓
  tx.decodeIntent  ──→  ERC-7730 descriptor (or 4byte fallback) → human intent
                          + token-decimals prefetched daemon-side
        ↓
  tx.simulate      ──→  eth_call + eth_estimateGas against the selected
                          provider (default helios = consensus-verified REVM;
                          rpc = direct; colibri = stateless light client)
                          + (opt) debug_traceCall walked daemon-side
                          → token movements rendered with real decimals
        ↓
  ConfirmGate (TUI) ──→ user inspects intent + sim outcome + transfers
        ↓                   Esc bails; Enter advances
  eoa.send / sphincs.*  ──→ daemon signs and broadcasts
```

`SendFlow` and `SendRawFlow` (TUI) implement this pipeline. The native
`leancli-agent` produces a structured `Intent` (validated by
`LeanCli/LlmAgent/IntentParser.lean` with hard-rejects) that flows
through the same gate via `LlmChatFlow → SendRawFlow`. Pasted calldata
flows through `DecodeIntentFlow` (read-only) and the same `ConfirmGate`
when the user chooses to sign. Simulation output is informational — the
user's `ConfirmGate` decision is the trust anchor, never the provider.

If you're adding a new "produces calldata" surface, wire it through this
gate — never call `eoa.send` directly. The `SendRawFlow` component is the
canonical reusable confirm path.

## Bridges and sidecars

Untrusted external processes sit at the boundary, hosted under the Kohaku
plugin model. Each is spawned only by its dedicated Lean module, treated as
malicious, and never the final authority on a signing decision. See
[`docs/PLUGIN_ARCHITECTURE.md`](./docs/PLUGIN_ARCHITECTURE.md) for the full
flag surface (`LEANCLI_PROVIDER` / `LEANCLI_PRIVACY`) and the
pinned-and-lazy plugin load model.

**Providers** (chain reads + simulation, single-select via
`LEANCLI_PROVIDER`, default `helios`):

| Provider | Lean wrapper | What it is | Trusted for | Never trusted for |
|---|---|---|---|---|
| `helios` | `Helios/{Bridge,Persistent}.lean` | `@a16z/helios` light client + REVM; consensus-verified state | sim outcomes used as confirmation UI | calldata bytes / signing |
| `colibri` | `Colibri/{Bridge,Persistent}.lean` | Colibri stateless light client (WASM EVM + committee proofs) | sim outcomes used as confirmation UI | calldata bytes / signing |
| `rpc` | `RPC/Outbound.lean` | Direct configured RPC endpoint | sim outcomes used as confirmation UI | calldata bytes / signing |
| `safenode` | `SafeNode/Persistent.lean` (+ helios) | Helios behind a TDX-attested ORAM proxy (`LEANCLI_SAFE_NODE_URL`) | sim outcomes used as confirmation UI | calldata bytes / signing |

**Privacy plugins** (shielded flows, multi-select via `LEANCLI_PRIVACY`,
default none) + the other sidecars:

| Sidecar | Purpose | Lean wrapper | Trusted for | Never trusted for |
|---|---|---|---|---|
| `sidecars/kohaku/` (`railgun`, `privacy-pools`, `tornado`) | `@kohaku-eth/*` shielded flows (snarkjs, libp2p, viem) | `Privacy/Bridge.lean` | producing valid ZK witnesses + relayer broadcast results | transaction structure, asset/amount semantics |
| `sidecars/clearsign/` | ERC-7730 walker + 4byte fallback + EIP-712 | `Clearsign/Bridge.lean` | rendering a human-readable intent string | the calldata bytes themselves; the daemon re-decodes |
| `sidecars/sphincs/` | SPHINCS+ post-quantum signer (C and Rust binaries) | `Sphincs/Bridge.lean` | producing a sig blob of the right shape | the signature itself: every `signWithVerify` re-runs verify locally before returning success; size mismatches are rejected |

The native `leancli-agent` exe handles NL → tx-draft (`LlmAgent/Bridge.lean`
parses its structured `Intent`); there is no Node LLM sidecar.

### Privacy plugins (`sidecars/kohaku/`)

Wraps `@kohaku-eth/{plugins,railgun,privacy-pools}`, multi-selected via
`LEANCLI_PRIVACY` (comma list; default empty = nothing enabled; a
`shielded.*` call for a disabled plugin is refused before its code loads).
Methods: `ping`, `version`, `listProtocols`, `listEnabled`,
`shielded.balance`, `shielded.prepareDeposit`, `shielded.prepareWithdraw`,
`shielded.unshieldDrain`. Spending secrets are derived from a separate
mnemonic (`LEANCLI_PP_MNEMONIC`), never the EOA mnemonic. Persistent PP
state is cached on disk so deposit/note bookkeeping survives across
one-shot invocations.

External dependencies the daemon does *not* re-derive in Lean:
- 0xBow ASP (Approval Service Provider) for deposit approvals.
- FastRelay (default) or a configured broadcaster for unshield relay.
- The PPv1 entrypoint contract on mainnet/Sepolia.

Network egress from this process is policy-classified under the
`shieldedRead` / `shieldedBroadcast` purposes (see invariant 5.7).
`strictDaemonPolicy` denies both; `torDaemonPolicy` permits them only over
Tor to a configured node. The runtime gate now lives in
`Privacy.Bridge.callGated`: a policy-denied shielded request is refused
before the sidecar is spawned — proved in `Invariants/Bridge.lean`
(invariant 5.7, now ✅).

### Clearsign (`sidecars/clearsign/`)

Walks ERC-7730 descriptors (calldata + EIP-712 typed data). Methods:
`ping`, `version`, `tx.decodeIntent`, `eip712.decodeIntent`. Bundled
descriptors today: ERC-20, Uniswap V3 SwapRouter02, Permit2, CowSwap order.
Unmatched contracts fall back to a small `4byte.json` dict (Aave V3 Pool,
Compound V3, Uniswap V2 Router, ENS, Multicall3, ERC-721/1155). When
neither matches, the user sees raw calldata + selector — never a
fabricated intent.

Reachable from the TUI's *More commands* menu as "Decode transaction
(ERC-7730)" and "Decode typed data (EIP-712)", and called internally by
`tx.decodeIntent` / `eip712.decodeIntent` before every confirm screen.

### LLM agent (native `leancli-agent`)

The LLM agent is a Lean-native executable (`leancli-agent` /
`leancli-agentd`), not a Node sidecar. Two-tier:

1. **Rule-based matcher** (always on, free, deterministic) — recognizes
   send / approve / Aave supply+withdraw / Aave withdraw patterns.
2. **LLM tool-use loop** — fires only when the rule matcher misses *and*
   an LLM endpoint is configured in the daemon's environment.

Tools the model can call: `lookup_token`, `lookup_protocol`,
`get_eth_balance`, `get_token_balance`, `get_gas_price`,
`get_uniswap_v3_quote`, `get_uniswap_v3_multi_hop_quote`,
`get_aave_health_factor`, `get_morpho_blue_position`, plus `emit_*` tools
that build calldata. Read tools route back into the wallet daemon over UDS
(`LeanCli/Agent/DaemonClient.lean`) so every chain RPC is policy-gated
identically to CLI/TUI requests.

Adding a new daemon-callback tool: encode calldata, call `chain.ethCall`
(the general policy-gated `eth_call` primitive). No per-protocol daemon RPC
needed — see the existing `get_aave_health_factor`, `get_uniswap_v3_quote`,
and `get_morpho_blue_position` tools under `LeanCli/Agent/ToolDefs/` as
templates.

The trust model is uniform across both tiers: the agent **never signs**.
Drafts flow through the standard decode → simulate → confirm pipeline. An
adversarial model (or prompt-injected context) can produce nonsense
calldata; the worst case is a confusing simulation the user rejects.

### Colibri light client (`sidecars/kohaku/colibri/`)

The `colibri` provider (`LEANCLI_PROVIDER=colibri`) wraps
`@corpus-core/colibri-stateless` to give the daemon committee-signed
EVM simulation locally. Methods: `ping`, `eth.proxy` (raw RPC pass-through),
`tx.simulate` (`colibri_simulateTransaction`). Two modes:

- **`--rpc <json>`** — one-shot, exits after one response. Pays sync-
  committee bootstrap cost on every call.
- **`--listen <socket>`** — long-running, owned by the daemon. Maintains
  one `C4Client` per chainId so bootstrap is paid once per chain per
  process lifetime. Toggled at runtime via `daemon.colibri.toggle`.

The daemon strips synthetic log entries (rows without an `address`, plus
all logs from a 21000-gas transaction) before rendering, since Colibri
surfaces native ETH movements as fake `Transfer`-shaped rows.

### SPHINCS+ shims (`sidecars/sphincs/`)

Local C and Rust binaries — *not* Node sidecars. Two parameter sets:

- **SLH-DSA-SHA2-128-24** (NIST FIPS 205 candidate). C, vendored from the
  `sphincs/sphincsplus` reference. 3856-byte sig.
- **C9** (WOTS+C / FORS+C, h=20 d=2 a=12 k=11 w=8). Rust, vendored from
  `nconsigny/SPHINCS-/signer-wasm @ 63617e1` with `params.rs` retuned to
  match the on-chain Yul verifier `legacy/src/SPHINCs-C9Asm.sol @ 5964b61`.
  3816-byte sig.

Methods (one-shot stdio JSON-RPC, mirrors the Node sidecars): `info`,
`keygen`, `sign`, `verify`. Build under `sidecars/sphincs/` with `make`;
the lake hook copies binaries into `.lake/build/bin/`.

The C9 binary has been cross-checked against the deployed Yul verifier on
the real Sepolia handleOps tx
`0x8366513b096ee53dd1cb105363ab21a52267dd966b822b4bb2cf5492abf1550f`
(block 10617954): the local Rust port and the deployed verifier agree on
that signature. Verifier contract is at
`0x18F005EECd41624644AA364bA8857258FEB3C26D`; the SphincsAccount is at
`0xA941116763AE386a50133c5af40356c9D93b2978` against EntryPoint v0.9.

The Lean side runs `signWithVerify` (sign + verify-after-sign) by default,
so a tampered shim cannot get the daemon to broadcast an unverifiable
signature. Length validation against the parameter-set's expected sizes
runs before any keygen/sign/verify call. The user-facing label is
"SPHINCS-" because both variants are non-standard relative to NIST
SLH-DSA.

### Native crypto helpers

The orchestration layer (`Crypto/Hacl.lean`,
`Crypto/Secp256k1Native.lean`) spawns these as one-shot subprocesses on
each call. Helpers are built from external sources — leanCLI does not
reimplement crypto:

| Helper basename | Implementation | Used for |
|---|---|---|
| `leancli-hacl-keccak256` | HACL Packages | Ethereum keccak (delimiter `0x01`) |
| `leancli-hacl-sha256` | HACL Packages | BIP-39 checksum, BIP-32 fingerprint input |
| `leancli-hacl-hmac-sha512` | HACL Packages | BIP-32 child-key derivation |
| `leancli-hacl-pbkdf2` | HACL Packages | BIP-39 seed, keystore wrapping |
| `leancli-hacl-chacha20poly1305` | HACL Packages | At-rest keystore encryption |
| `leancli-hacl-ripemd160` | RustCrypto `ripemd` | BIP-32 HASH160 fingerprint only |
| `leancli-secp256k1-{sign,pubkey,recover,verify}` | Bitcoin Core libsecp256k1 | EOA k1 signing/verify/recovery/pubkey |

The HMAC-SHA-256 and HMAC-DRBG helpers were pruned (zero consumers). See
[`native/README.md`](./native/README.md) for pins + consumers and
[`docs/CRYPTO_POLICY.md`](./docs/CRYPTO_POLICY.md) for the policy.

Set up the helpers with:

```bash
./ops/scripts/setup_hacl.sh
./ops/scripts/setup_secp256k1.sh
export PATH="$PWD/.lake/build/bin:$PATH"
```

`ops/scripts/check_native_helpers.sh` smoke-tests every helper. A
compromised or substituted helper defeats every higher-level invariant
(see 13.10).

## Running the daemon with sidecars

Most sidecars are zero-config from the monorepo: when no env var is set,
the daemon walks the working directory upward (≤ 8 hops) looking for the
in-repo entrypoint. Privacy plugins need explicit opt-in (`LEANCLI_PRIVACY`)
plus their own spending credential.

| Sidecar | Default behavior with no env var | Explicit override |
|---|---|---|
| Clearsign | walks up for `sidecars/clearsign/bridge.mjs`; fallback PATH basename | `LEANCLI_CLEARSIGN_BRIDGE` |
| Helios (default provider) | walks up for `sidecars/kohaku/helios/bridge.mjs`; fallback PATH basename | `LEANCLI_PROVIDER=helios` (default) |
| Colibri | walks up for `sidecars/kohaku/colibri/bridge.mjs`; fallback PATH basename | `LEANCLI_PROVIDER=colibri` |
| Sphincs (C9, SLHDSA) | walks up for `sidecars/sphincs/bin/sphincs-{c9,slhdsa-128-24}`; fallback PATH basename. Requires you to have run `make` under `sidecars/sphincs/` first. | `LEANCLI_SPHINCS_C9` / `LEANCLI_SPHINCS_SLHDSA` |
| Privacy plugins (Railgun / Privacy Pools / Tornado) | disabled unless listed in `LEANCLI_PRIVACY` | `LEANCLI_PRIVACY=railgun,privacy-pools` plus `LEANCLI_PP_MNEMONIC` (separate spending secret) |

The LLM agent is the native `leancli-agent` exe — no sidecar to wire; the
model tool-use loop fires only when an LLM endpoint is configured in the
daemon's environment, otherwise the rule-based matcher is the only path.

So the minimal local-dev launch is just:

```bash
leancli-daemon
```

…provided you've run `(cd sidecars/sphincs && make)` once. Without that,
SPHINCS+ flows fail with a spawn error; the other surfaces work.

To enable a privacy plugin (opt-in, with its own spending secret):

```bash
LEANCLI_PRIVACY=railgun,privacy-pools                                  \
LEANCLI_PP_MNEMONIC="abandon abandon …"                                \
leancli-daemon
```

Any defaulted entry can still be force-overridden by setting the matching
`LEANCLI_*` env var explicitly — useful when iterating on a sidecar
under a non-standard path. Switch read providers with
`LEANCLI_PROVIDER=helios|colibri|rpc|safenode` (default `helios`).

The TUI bundle is built by `ops/scripts/leanclispawn` (`build_tui`). To rebuild it on its own:

```bash
(cd tui && npm install && npm run build)
leancli tui
```

## Keystore

`LeanCli.Keystore.Enclave` models local-only enclave-backed key custody.
Secret import/export is denied by the accepted policy. Linux TPM2, FIDO2,
Apple Secure Enclave, and external hardware signers are local-only custody
backends. TPM2 in particular backs the wallet **master-KEK** custody path
(`wallet master init` → TPM-bound PIN), not a distinct account kind — the
R1/P-256 smart-account path has been removed; EOAs and the SPHINCS+ hybrid
family are the account kinds.

`LeanCli.Keystore.Linux` prefers TPM2 for common HP business
notebook/workstation and Lenovo ThinkPad/ThinkCentre profiles, falls
back to FIDO2 security keys when TPM2 is absent, and treats the Linux
kernel keyring as a local handle store.

`LeanCli.Keystore.Tpm2Runtime` is the local Linux runtime boundary.
It uses local `tpm2-tools` to create TPM-wrapped P-256 keys under
`.leancli/keystore/tpm2/<name>/`, writes `public.pem` and
`manifest.txt`, and refuses to overwrite an existing manifest. Key
creation and signing are gated by local `fprintd-verify`, defaulting to
`right-index-finger` with three verification attempts.

Nix and Arch packaging list `tpm2-tools`, `libfido2`, and `fprintd` only
as optional host-integration tools. The Lean wallet does not link to
those libraries or trust them as crypto implementations.

`ops/scripts/leanclispawn` ends each install with a TPM2 readiness probe and
prints the exact distro-specific install line (`pacman` / `apt` /
`dnf`) when `tpm2-tools` is missing, plus the `usermod -aG tss $USER`
hint when device permissions block access — so users who want
`wallet master init` → TPM-bound PIN don't have to assemble the
prerequisites themselves. `leancli wallet master status` is the
post-install verification: `tpmHardwareReady: true` means
`wallet master bind-tpm` will succeed.

## Accounts

`LeanCli.Wallet.Account` defines:

- regular BIP-39/BIP-32 Ethereum EOAs (k1) — proven local-only;
- *(experimental, Sepolia)* SPHINCS+ hybrid accounts — abstract Lean
  model proved (Cat 12), runtime depends on the Sepolia-deployed
  `SphincsAccount.sol` plus the C9 verifier and EntryPoint v0.9.

Mainnet policies are the defaults; Sepolia policies are available for
explicit dev/testnet use. (The earlier R1/P-256 smart-account family was
removed; TPM2 now backs master-KEK custody rather than an account kind.)

## SPHINCS+ hybrid account (experimental, Sepolia)

The on-chain `SphincsAccount.sol` contract is a hybrid ECDSA + stateless
SPHINCS+ ERC-4337 account with rotatable key material. Every UserOp is
gated by **both** ECDSA recovery to a stored `owner` AND a stateless
SPHINCS+ verifier keyed by stored `(pkSeed, pkRoot)`. Rotation goes
through dedicated self-call paths.

The Lean abstract model lives in
`LeanCli/Contract/SphincsAccount.lean`; its proofs (Cat 12) cover
nonce monotonicity, the hybrid signature gate, rotation isolation, and
key supersession after rotation. The Solidity contract itself is
trusted external code — the Lean abstract model is a *spec* the on-chain
contract must agree with, not a verified compilation of it.

The verifier contract address is part of the deployed account's
immutable configuration, so SPHINCS+ parameter-set selection (C9 vs
SLH-DSA-SHA2-128-24) lives outside the abstract model: the user's local
signer must produce signatures that match the parameter set the deployed
verifier accepts. The C9 binary at `sidecars/sphincs/vendor-c9/` has
been cross-checked against a real on-chain handleOps tx — see the
SPHINCS+ shim section above.

## Provider policy

`LeanCli.Network.Provider` models the small JSON-RPC surface the
daemon may eventually need. It classifies methods by peer, purpose, and
transport before any runtime networking is implemented.

## EOA and encoding status

The repo includes pure Lean RLP encoding, EIP-1559 typed transaction
payload/transaction encoding, ERC-20 transfer/approval decoding, and
native secp256k1 field/point arithmetic with ECDSA signing over an
already-hashed digest plus explicit nonce. The pure secp256k1 spec
module is *not* used at runtime — runtime ECDSA goes through
`Crypto/Secp256k1Native.lean` and libsecp256k1 (see *Native crypto
helpers*).

Keccak-256 and HMAC-SHA512 are the narrow native helper boundary in
`LeanCli.Crypto.Hacl`. Runtime EOA signing depends on those helpers
being on `$PATH`.

## Invariants

See [`INVARIANTS.md`](./INVARIANTS.md) for the full catalogue.
Summary:

| # | Invariant | Status |
|---|-----------|--------|
| 0.1–0.5 | Verified-core properties (no exfil, no raw signing, chain match, approval, EIP-7702 guardrails) | ✅ |
| 1.1, 1.2 | Checked subtraction; multi-output sends conserve total | ✅ |
| 2.1, 2.3 | EIP-1559 fee relation; chain-ID match | ✅ (by definition) |
| 2.2 | Calldata-aware intrinsic gas lower bound | 🚧 |
| 3.1, 3.2 | Signed-amount integrity / deterministic nonce | 📝 |
| 4.1, 4.2 | RLP / hex roundtrip | 🚧 |
| 4.3, 4.4 | Account policies; JSON destructors | ✅ |
| 5.1, 5.2 | Railgun no-double-spend / shield conservation | 📝 (future) |
| 5.3 | Bridge cannot return spending-key material | 🔒 by-construction |
| 5.7 | Bridge methods policy-classified + runtime gate (no shielded egress without policy permission) | ✅ |
| 5.8–5.11 | Bridge response framing; CLI preflight; modeled provider ops; endpoint hygiene | ✅ |
| 6.1–6.6 | Network policy | ✅ |
| 7.1–7.3 | Provider policy | ✅ |
| 8.1–8.3, 8.5 | Keystore (local-only, no export, user-auth, TPM2 profiles) | ✅ |
| 8.6, 8.7 | Master KEK never leaves daemon; PP/EOA secrets split | 🔒 axiomatized |
| 11.1, 11.2 | Uniswap V3 swap helper | ✅ |
| 12.1–12.7 | SPHINCS+ hybrid account contract | ✅ |
| 14.1 | LLM-agent address resolution (`.verified` is derivation-backed) | ✅ |
| 13.1–13.7, 13.9, 13.10 | Cryptographic primitives + helper integrity | 🔒 axiomatized |

## Documentation

- [CLI](./docs/CLI.md)
- [Daemon](./docs/DAEMON.md) — full RPC catalog
- [Architecture](./docs/ARCHITECTURE.md) — module map, sidecars, TUI
- [Plugin architecture](./docs/PLUGIN_ARCHITECTURE.md) — Kohaku provider/privacy host
- [Crypto policy](./docs/CRYPTO_POLICY.md) — one-library-per-primitive pins
- [Native shims](./native/README.md) — FFI + crypto helper dependencies
- [Security](./SECURITY.md) — trust boundary statement
- [Privacy and Security](./docs/PRIVACY_SECURITY.md)

## License

TBD.
