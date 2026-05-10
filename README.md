# leanKohaku

**Research wallet.** A Lean 4 Ethereum wallet daemon with a CLI-first surface
and an Ink-based TUI. Lean owns the orchestration code (network policy,
account policy, transaction framing, JSON/RLP encoding, daemon dispatch,
abstract account/contract models) and a growing set of machine-checked
invariants over it. Cryptographic primitives, ZK circuits, EVM simulation,
ERC-7730 walking, the natural-language drafting agent, and post-quantum
signing live in untrusted sidecars or native helper binaries. Every produced
calldata is gated through a `decode → simulate → user-confirm` pipeline
before any signing.

This README tries to be honest about scope: most of the load-bearing crypto
is *not* in Lean — it lives in vetted external implementations called over
process boundaries. The proof effort is over the orchestration layer, not the
primitives. See [INVARIANTS.md](./INVARIANTS.md) for the proof inventory and
[What is verified vs trusted](#what-is-verified-vs-trusted) below for the
trust surface.

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
  for P-256/R1; never an online keystore, never raw secret import/export.
- **Two account families plus an experimental third.** BIP-39/32 EOAs (k1)
  and local hardware-backed R1 smart accounts; SPHINCS+ hybrid accounts on
  Sepolia as a research third family.
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
  R1 TPM policy and EIP-7702 guardrails.
- Amount arithmetic (Cat 1): checked subtraction never underflows;
  multi-output sends conserve total balance and only debit affordable
  amounts.
- EIP-1559 fee relation and chain-ID match (Cat 2, by definition).
- Account policies are supported-chain and local-only (4.3); JSON
  destructors agree with constructors (4.4).
- Network policy (Cat 6 + 7): CLI only contacts the local daemon; daemon
  policies deny third-party peers; strict mode denies configured-node
  access; Tor mode is transport-scoped; non-broadcast methods classify as
  reads.
- Keystore (Cat 8): accepted requests never export secrets, are local-
  only, require user authorization; Linux HP/Lenovo profiles select TPM2
  first; Apple Secure Enclave accepts the local R1 signing policy.
- EIP-7951 P256VERIFY constants and chain ids (9.1).
- R1 account contract (Cat 10): only supported chains; nonce advances
  only after EIP-7951 verification.
- SPHINCS+ hybrid account contract (Cat 12): nonce monotonicity, hybrid
  signature gate (ECDSA AND SPHINCS+), rotation isolation, key
  supersession after rotation, owner-rotation safety.
- Uniswap V3 swap helper (Cat 11): zero-slippage identity; balances
  candidates are chain-correct.
- Bridge response framing (5.8): the daemon cannot mistake a sidecar
  crash for a successful proof.

### 🚧 Stated but not yet proved

Sketched in `INVARIANTS.md` with a Lean proposition; proof partial or
absent. Treat these as design intent, not guarantees.

- 2.2 Calldata-aware intrinsic gas lower bound — only bare-transfer bound
  is currently in `wellFormed`.
- 3.1 Signed-amount integrity through CLI/TUI — requires threading a
  `UserIntent` type end-to-end.
- 3.2 Deterministic nonce use across restarts.
- 3.3 R1 signature verifiability against the stored public key.
- 4.1 RLP roundtrip — only structural lemmas; full round-trip blocked on
  a non-`partial` decoder.
- 4.2 Hex roundtrip — nibble-level proved; byte-level lift pending.
- 5.1 / 5.2 Railgun double-spend / shield conservation — modeled
  informally only; the Railgun primitives live in the privacy bridge and
  are not re-derived in Lean.
- 5.3 Bridge cannot return spending-key material — by-construction
  inspection of `Privacy/Bridge.lean`, not a machine-checked predicate yet.
- 5.7 Bridge methods are policy-classified — classification + strict/tor
  lemmas proved; the runtime gate that *forces* every `Bridge.call`
  through `policyAllows` is still pending. There is no Lean theorem yet
  saying the daemon cannot bypass the gate.

### 🔒 Cryptographically axiomatized

End-to-end security cannot be proved by Lean alone — collision resistance,
signature unforgeability, AEAD authenticity, KDF/PRF, and ZK soundness are
standard cryptographic *assumptions*. Each is documented in
`INVARIANTS.md` Cat 13 and bound to a specific external implementation:

- Keccak-256, SHA-256, HMAC-SHA-256/512, PBKDF2-HMAC-SHA-512, HMAC-DRBG,
  ChaCha20-Poly1305 → HACL Packages binaries (Project Everest).
- RIPEMD-160 → RustCrypto `ripemd` helper (HASH160 only, never
  Ethereum addresses).
- secp256k1 ECDSA → Bitcoin Core libsecp256k1 helpers.
- P-256 / EIP-7951 P256VERIFY → on-chain precompile + hardware backends.
- SPHINCS+ → vendored `sphincs/sphincsplus` reference (C) for
  SLH-DSA-SHA2-128-24, vendored `nconsigny/SPHINCS-/signer-wasm` (Rust)
  for the C9 parameter set.

A compromised or substituted helper defeats every higher-level invariant
(13.10).

### 🔌 Trusted external code (not modeled in Lean)

The proof corpus does not extend to:

- The Privacy Pools v1 SDK
  (`@kohaku-eth/{plugins,railgun,privacy-pools}`) and its snarkjs witness
  generation.
- The Colibri stateless light client (`@corpus-core/colibri-stateless`)
  used for `colibri_simulateTransaction`.
- The viem ABI walker, ERC-7730 descriptors, and 4-byte selector dict
  used by the clearsign sidecar.
- The LLM tool-use loop in the LLM sidecar (model output is treated as
  adversarial regardless).
- The Solidity contracts deployed on Sepolia: `R1Account`,
  `SphincsAccount` at `0xA941116763AE386a50133c5af40356c9D93b2978`, the
  C9 verifier at `0x18F005EECd41624644AA364bA8857258FEB3C26D`, EntryPoint
  v0.9.
- The 0xBow ASP (third-party Approval Service Provider for Privacy Pools)
  and FastRelay broadcaster.

The mitigation for trusting external code is uniform: nothing the daemon
signs depends on what a sidecar *reports*. Every produced calldata is
re-decoded in Lean and run through `tx.simulate → ConfirmGate` before any
key touches it.

## Layout

```
leanKohaku/
├─ lakefile.lean                  # Lake build config
├─ lean-toolchain                 # pinned Lean version (4.29.1)
├─ flake.nix / default.nix        # Nix scaffold
├─ LeanKohaku.lean                # Root module (re-exports)
├─ LeanKohaku/
│  ├─ App/         CLI / daemon executable roots
│  ├─ Crypto/      Hex, Hacl (opaque + IO helpers), Secp256k1Native
│  ├─ Encoding/    Json, Rlp
│  ├─ Ethereum/    Address, Chain, P256Precompile, Tx, Abi, Eip712, Ens
│  ├─ Privacy/     NetworkPolicy, Bridge (privacy-pools/railgun spawn)
│  ├─ Clearsign/   Bridge (ERC-7730 + EIP-712 spawn)
│  ├─ LlmAgent/    Bridge (NL → tx draft spawn)
│  ├─ Colibri/     Bridge, Persistent (light-client spawn)
│  ├─ Sphincs/     Bridge, UserOp (SPHINCS+ shim spawn, EIP-712 userOpHash)
│  ├─ Network/     Endpoint, Provider (incl. debug_traceCall)
│  ├─ Keystore/    Enclave, Linux, Tpm2Runtime, MasterKey
│  ├─ Contract/    R1Account, SphincsAccount (abstract)
│  ├─ Swap/        UniV3, Tokens (abstract)
│  ├─ Wallet/      Account, Bip39Wordlist, Bip44, HDKey, EOA, EoaStore, …
│  ├─ RPC/         JsonRpc, Outbound, Server
│  ├─ Daemon/      Config, Log, State, TokenMeta, TxJournal, Uds, Server
│  ├─ Cli/         Commands, DaemonClient, Passphrase, NetworkConfig
│  └─ Invariants/  Amount, Wallet, TxWellFormed, Network, R1Account,
│                  SphincsAccount, Swap, Bridge, Encoding, Keystore,
│                  Core, Mainnet, …
├─ Contracts/R1Account/           # Lean source for the deployable R1 contract
├─ solidity/dev/R1AccountDev.sol  # Sepolia dev fallback (not canonical)
├─ bridge/                        # Untrusted Node sidecars
│  ├─ <root>/      Privacy Pools / Railgun (snarkjs, libp2p, viem)
│  ├─ clearsign/   ERC-7730 walker + 4byte fallback + EIP-712 (viem)
│  ├─ llm/         LLM tool-use loop + viem
│  └─ colibri/     Colibri stateless light client (one-shot or --listen)
├─ sidecars/sphincs/              # Untrusted local SPHINCS+ shims (C / Rust)
│  ├─ vendor-slhdsa-sha2-128-24/  vendored sphincsplus reference (C)
│  ├─ vendor-c9/                  vendored signer-wasm (Rust)
│  └─ shim/                       JSON-RPC dispatcher around the C signer
├─ tui/                           # Ink-based TUI (esbuild-bundled)
├─ packaging/arch/                # Arch Linux PKGBUILD scaffold
├─ INVARIANTS.md                  # Living invariant inventory + proof status
├─ SECURITY.md                    # Trust boundary statement
└─ README.md
```

## Build

```bash
elan toolchain install $(cat lean-toolchain)  # installs Lean 4.29.1
lake build                                     # builds lib + both executables
```

Artifacts land in `.lake/build/bin/`:
- `leankohaku`         — CLI
- `leankohaku-daemon`  — daemon

Nix scaffolding is available:

```bash
nix build
nix develop
```

The Arch Linux scaffold lives in `packaging/arch/`. Replace the placeholder
repository URL before publishing a package.

## Quick start

```bash
./.lake/build/bin/leankohaku help
./.lake/build/bin/leankohaku version
./.lake/build/bin/leankohaku policy                  # overview of policy topics
./.lake/build/bin/leankohaku policy privacy          # network privacy summary
./.lake/build/bin/leankohaku policy security         # hard rules + checks
./.lake/build/bin/leankohaku policy keystore         # custody policy
./.lake/build/bin/leankohaku policy accounts         # account families
./.lake/build/bin/leankohaku policy lightclient      # provider-policy plan
./.lake/build/bin/leankohaku policy all              # everything in one print
./.lake/build/bin/leankohaku network                 # current network config
./.lake/build/bin/leankohaku doctor                  # privacy/security status
./.lake/build/bin/leankohaku wallet create r1 work-key
./.lake/build/bin/leankohaku wallet deploy work-key
./.lake/build/bin/leankohaku wallet list
./.lake/build/bin/leankohaku balance 0x0000000000000000000000000000000000000000
./.lake/build/bin/leankohaku send 0x0000000000000000000000000000000000000000 1
./.lake/build/bin/leankohaku from daily send 0x0000000000000000000000000000000000000000 1
./.lake/build/bin/leankohaku debug policy-check strict configured-node broadcast-tx direct
./.lake/build/bin/leankohaku debug rpc-check tor configured tor eth_sendRawTransaction
./.lake/build/bin/leankohaku debug endpoint-check strict local http loopback false
./.lake/build/bin/leankohaku debug decode erc20 0xa9059cbb...
./.lake/build/bin/leankohaku daemon ping
./.lake/build/bin/leankohaku daemon                  # starts the daemon in the foreground
./.lake/build/bin/leankohaku tui                     # opens the Ink TUI
```

## Pre-sign pipeline

Every signing flow goes through the same gate before reaching `eoa.send`,
`r1.send*`, or any SPHINCS+ flow:

```
  build {to, value, data}
        ↓
  tx.decodeIntent  ──→  ERC-7730 descriptor (or 4byte fallback) → human intent
                          + token-decimals prefetched daemon-side
        ↓
  tx.simulate      ──→  eth_call + eth_estimateGas
                          (or colibri_simulateTransaction when enabled)
                          + (opt) debug_traceCall walked daemon-side
                          → token movements rendered with real decimals
        ↓
  ConfirmGate (TUI) ──→ user inspects intent + sim outcome + transfers
        ↓                   Esc bails; Enter advances
  eoa.send / r1.send* / sphincs.*  ──→ daemon signs and broadcasts
```

`SendFlow` and `SendRawFlow` (TUI) implement this pipeline. The LLM agent
in `bridge/llm/` produces drafted candidates that flow through the same
gate via `LlmDraftFlow → SendRawFlow`. Pasted calldata flows through
`DecodeIntentFlow` (read-only) and the same `ConfirmGate` when the user
chooses to sign.

If you're adding a new "produces calldata" surface, wire it through this
gate — never call `eoa.send` directly. The `SendRawFlow` component is the
canonical reusable confirm path.

## Bridges and sidecars

Five untrusted external processes sit at the boundary. Each is spawned
only by its dedicated Lean module, treated as malicious, and never the
final authority on a signing decision.

| Sidecar | Purpose | Lean wrapper | Transport | Trusted for | Never trusted for |
|---|---|---|---|---|---|
| `bridge/` | Privacy Pools v1 / Railgun (snarkjs, libp2p, viem) | `Privacy/Bridge.lean` | one-shot stdio JSON-RPC | producing valid ZK witnesses + relayer broadcast results | transaction structure, asset/amount semantics |
| `bridge/clearsign/` | ERC-7730 walker + 4byte fallback + EIP-712 | `Clearsign/Bridge.lean` | one-shot stdio JSON-RPC | rendering a human-readable intent string | the calldata bytes themselves; the daemon re-decodes |
| `bridge/llm/` | NL → tx draft via rule-based matcher + (optional) LLM tool-use loop | `LlmAgent/Bridge.lean` | one-shot stdio JSON-RPC | proposing draft `{to, value, data}` candidates | any signing decision; every draft re-flows the standard pipeline |
| `bridge/colibri/` | Stateless light-client EVM simulation + `eth_*` proxy | `Colibri/Bridge.lean`, `Colibri/Persistent.lean` | persistent UDS (`--listen`), one-shot fallback | sim outcomes used as confirmation UI | calldata bytes; sim output is informational, daemon still re-decodes |
| `sidecars/sphincs/` | SPHINCS+ post-quantum signer (C and Rust binaries) | `Sphincs/Bridge.lean` | one-shot stdio JSON-RPC | producing a sig blob of the right shape | the signature itself: every `signWithVerify` re-runs verify locally before returning success; size mismatches are rejected |

### Privacy Pools / Railgun (`bridge/`)

Wraps `@kohaku-eth/{plugins,railgun,privacy-pools}`. Methods: `ping`,
`version`, `listProtocols`, `shielded.balance`, `shielded.prepareDeposit`,
`shielded.prepareWithdraw`, `shielded.unshieldDrain`. Spending secrets are
derived from a separate mnemonic (`LEANKOHAKU_PP_MNEMONIC`), never the EOA
mnemonic. Persistent PP state is cached on disk so deposit/note bookkeeping
survives across one-shot invocations.

External dependencies the daemon does *not* re-derive in Lean:
- 0xBow ASP (Approval Service Provider) for deposit approvals.
- FastRelay (default) or a configured broadcaster for unshield relay.
- The PPv1 entrypoint contract on mainnet/Sepolia.

Network egress from this process is policy-classified under the
`shieldedRead` / `shieldedBroadcast` purposes (see invariant 5.7).
`strictDaemonPolicy` denies both; `torDaemonPolicy` permits them only over
Tor to a configured node. *Note:* the runtime gate that forces every
`Bridge.call` through `policyAllows` is not yet a theorem — see 5.7 above.

### Clearsign (`bridge/clearsign/`)

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

### LLM agent (`bridge/llm/`)

Two-tier:

1. **Rule-based matcher** (always on, free, deterministic) — recognizes
   send / approve / Aave supply+withdraw / Aave withdraw patterns.
2. **LLM tool-use loop** — fires only when the rule matcher misses *and*
   an LLM API key is configured in the daemon's environment.

Tools the model can call: `lookup_token`, `lookup_protocol`,
`get_eth_balance`, `get_token_balance`, `get_gas_price`,
`get_uniswap_v3_quote`, `get_uniswap_v3_multi_hop_quote`,
`get_aave_health_factor`, `get_morpho_blue_position`, plus `emit_*` tools
that build calldata via viem. Read tools route back into the daemon over
UDS (`bridge/llm/src/daemon-callback.mjs`) so every chain RPC is policy-
gated identically to CLI/TUI requests.

Adding a new daemon-callback tool: encode calldata via viem, call
`chain.ethCall` (the general policy-gated `eth_call` primitive). No per-
protocol daemon RPC needed — see the existing `get_aave_health_factor`,
`get_uniswap_v3_quote`, and `get_morpho_blue_position` tools under
`bridge/llm/src/` as templates.

The trust model is uniform across both tiers: the agent **never signs**.
Drafts flow through the standard decode → simulate → confirm pipeline. An
adversarial model (or prompt-injected context) can produce nonsense
calldata; the worst case is a confusing simulation the user rejects.

### Colibri light client (`bridge/colibri/`)

Wraps `@corpus-core/colibri-stateless` to give the daemon committee-signed
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
each call. Helpers are built from external sources — leanKohaku does not
reimplement crypto:

| Helper basename | Implementation | Used for |
|---|---|---|
| `leankohaku-hacl-keccak256` | HACL Packages | Ethereum keccak (delimiter `0x01`) |
| `leankohaku-hacl-sha256` | HACL Packages | BIP-39 checksum, BIP-32 fingerprint input |
| `leankohaku-hacl-hmac-sha256` / `-sha512` | HACL Packages | BIP-32 child-key derivation, generic HMAC |
| `leankohaku-hacl-pbkdf2` | HACL Packages | BIP-39 seed, keystore wrapping |
| `leankohaku-hacl-hmac-drbg` | HACL Packages | DRBG for k1 nonce |
| `leankohaku-hacl-chacha20poly1305` | HACL Packages | At-rest keystore encryption |
| `leankohaku-hacl-ripemd160` | RustCrypto `ripemd` | BIP-32 HASH160 fingerprint only |
| `leankohaku-secp256k1-{sign,pubkey,recover,verify}` | Bitcoin Core libsecp256k1 | EOA k1 signing/verify/recovery/pubkey |

Set up the helpers with:

```bash
./script/setup_hacl.sh
./script/setup_secp256k1.sh
export PATH="$PWD/.lake/build/bin:$PATH"
```

`script/check_native_helpers.sh` smoke-tests every helper. A compromised
or substituted helper defeats every higher-level invariant
(see 13.10).

## Network privacy

`LeanKohaku.Privacy.NetworkPolicy` is the deny-by-default boundary:

- CLI traffic is limited to local daemon control over loopback.
- Daemon reads use local/light-client loopback by default.
- Broadcast is limited to `eth_sendRawTransaction`.
- Strict mode denies configured-node traffic, including direct broadcast.
- Tor mode may read and broadcast through a configured node over Tor.
- Third-party APIs (analytics, telemetry, price quotes, fiat/onramp,
  metadata, indexers, crash reports, discovery) remain denied even when
  Tor is enabled.

Daemon-backed commands use the local Unix socket. If systemd socket
activation is not available and the socket is missing, the CLI auto-
spawns `leankohaku-daemon` unless `LEANKOHAKU_NO_AUTOSPAWN=1` is set.
Invalid CLI input still exits before any daemon or network path is
attempted.

The daemon-side chain path is implemented and policy-gated:

- `balance` maps to `eth_getBalance` against the local provider.
- `nonce`, fee, estimate, token balance, and raw broadcast map to
  Ethereum JSON-RPC methods through the daemon.
- `eoa send` derives nonce/fees/gas, signs EIP-1559 locally in the
  daemon, and broadcasts with `eth_sendRawTransaction`.

Endpoint hygiene is modeled separately:

- Strict mode accepts only local, uncredentialed endpoints over loopback.
- Tor mode accepts local loopback endpoints and uncredentialed configured
  endpoints over Tor.
- Credentialed endpoints are denied (rules out API-key hosted services).
- Third-party endpoints are denied in every mode.

Run the local regression checks with:

```bash
./script/check_native_helpers.sh
./script/check_cli_isolation.sh
./script/check_privacy_cli.sh
./script/check_m6_keystore_daemon.sh
./script/check_daemon_config.sh
./script/check_m10_autospawn.sh
./script/check_m8_chain_rpc.sh
```

## Running the daemon with sidecars

Three of the five sidecars are zero-config from the monorepo: when no
env var is set, the daemon walks the working directory upward (≤ 8 hops)
looking for the in-repo entrypoint. The other two need explicit wiring
because they each require their own credential.

| Sidecar | Default behavior with no env var | Explicit override |
|---|---|---|
| Clearsign | walks up for `bridge/clearsign/bridge.mjs`; fallback PATH basename | `LEAN_KOHAKU_CLEARSIGN_BRIDGE` |
| Colibri | walks up for `bridge/colibri/bridge.mjs`; fallback PATH basename | `LEAN_KOHAKU_COLIBRI_BRIDGE` |
| Sphincs (C9, SLHDSA) | walks up for `sidecars/sphincs/bin/sphincs-{c9,slhdsa-128-24}`; fallback PATH basename. Requires you to have run `make` under `sidecars/sphincs/` first. | `LEAN_KOHAKU_SPHINCS_C9` / `LEAN_KOHAKU_SPHINCS_SLHDSA` |
| Privacy Pools / Railgun | basename `leankohaku-kohaku-bridge` on PATH (likely missing) | `LEAN_KOHAKU_BRIDGE` plus `LEAN_KOHAKU_PP_MNEMONIC` (separate spending secret) |
| LLM | basename `leankohaku-llm-bridge` on PATH (likely missing) | `LEAN_KOHAKU_LLM_BRIDGE`; the model tool-use loop only fires when an LLM API key is also configured in the daemon's environment, otherwise the rule-based matcher is the only path |

So the minimal local-dev launch is just:

```bash
.lake/build/bin/leankohaku-daemon
```

…provided you've run `(cd sidecars/sphincs && make)` once. Without that,
SPHINCS+ flows fail with a spawn error; the other surfaces work.

To enable the credentialed sidecars:

```bash
LEAN_KOHAKU_BRIDGE=$PWD/bridge/bridge.mjs                                  \
LEAN_KOHAKU_PP_MNEMONIC="abandon abandon …"                                \
LEAN_KOHAKU_LLM_BRIDGE=$PWD/bridge/llm/bridge.mjs                          \
.lake/build/bin/leankohaku-daemon
```

Any defaulted entry can still be force-overridden by setting the matching
`LEAN_KOHAKU_*` env var explicitly — useful when iterating on a sidecar
under a non-standard path.

The TUI bundle is built separately:

```bash
(cd tui && npm install && npm run build)
kohaku tui
```

## Keystore

`LeanKohaku.Keystore.Enclave` models local-only enclave-backed key custody.
Secret import/export is denied by the accepted policy. Native macOS/iOS
Secure Enclave support is modeled for P-256/R1. Linux TPM, FIDO2, Apple
Secure Enclave, and external hardware signers are local-only P-256/R1
custody options.

`LeanKohaku.Keystore.Linux` prefers TPM2 for common HP business
notebook/workstation and Lenovo ThinkPad/ThinkCentre profiles, falls
back to FIDO2 security keys when TPM2 is absent, and treats the Linux
kernel keyring as a local handle store.

`LeanKohaku.Keystore.Tpm2Runtime` is the local Linux runtime boundary.
It uses local `tpm2-tools` to create TPM-wrapped P-256 keys under
`.leankohaku/keystore/tpm2/<name>/`, writes `public.pem` and
`manifest.txt`, and refuses to overwrite an existing manifest. Key
creation and signing are gated by local `fprintd-verify`, defaulting to
`right-index-finger` with three verification attempts.

Nix and Arch packaging list `tpm2-tools`, `libfido2`, and `fprintd` only
as optional host-integration tools. The Lean wallet does not link to
those libraries or trust them as crypto implementations.

## Accounts

`LeanKohaku.Wallet.Account` defines:

- regular BIP-39/BIP-32 Ethereum EOAs (k1) — proven local-only;
- local hardware-backed P-256/R1 smart accounts — proven local-only;
- *(experimental, Sepolia)* SPHINCS+ hybrid accounts — abstract Lean
  model proved (Cat 12), runtime depends on the Sepolia-deployed
  `SphincsAccount.sol` plus the C9 verifier and EntryPoint v0.9.

Mainnet policies are the defaults; Sepolia policies are available for
explicit dev/testnet use.

## R1 account

`LeanKohaku.Contract.R1Account` is the Lean-level account verifier model:
it stores the P-256 public key, enforces a supported chain id (`1`
mainnet or `11155111` Sepolia), checks nonce equality, constructs the
EIP-7951 `h || r || s || qx || qy` precompile input, and increments
nonce only after successful verification.

`Contracts/R1Account/` contains the Verity-oriented Lean source for the
deployable account. `script/r1_sepolia.sh` keeps the local
digest/sign/execute workflow. For same-day Sepolia testing,
`solidity/dev/R1AccountDev.sol` provides a temporary Solidity fallback;
it is not the canonical source.

Verity is pinned by `script/setup_verity.sh`. It is not imported into the
default Lake graph yet because upstream Verity currently pins Lean 4.22.0
while leanKohaku pins Lean 4.29.1.

## SPHINCS+ hybrid account (experimental, Sepolia)

The on-chain `SphincsAccount.sol` contract is a hybrid ECDSA + stateless
SPHINCS+ ERC-4337 account with rotatable key material. Every UserOp is
gated by **both** ECDSA recovery to a stored `owner` AND a stateless
SPHINCS+ verifier keyed by stored `(pkSeed, pkRoot)`. Rotation goes
through dedicated self-call paths.

The Lean abstract model lives in
`LeanKohaku/Contract/SphincsAccount.lean`; its proofs (Cat 12) cover
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

`LeanKohaku.Network.Provider` models the small JSON-RPC surface the
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
`LeanKohaku.Crypto.Hacl`. Runtime EOA signing depends on those helpers
being on `$PATH`.

## Invariants

See [`INVARIANTS.md`](./INVARIANTS.md) for the full catalogue.
Summary:

| # | Invariant | Status |
|---|-----------|--------|
| 0.1–0.5 | Verified-core properties (no exfil, no raw signing, chain match, approval, R1/EIP-7702 guardrails) | ✅ |
| 1.1, 1.2 | Checked subtraction; multi-output sends conserve total | ✅ |
| 2.1, 2.3 | EIP-1559 fee relation; chain-ID match | ✅ (by definition) |
| 2.2 | Calldata-aware intrinsic gas lower bound | 🚧 |
| 3.1–3.3 | Signed-amount integrity / deterministic nonce / R1 verifiability | 📝 |
| 4.1, 4.2 | RLP / hex roundtrip | 🚧 |
| 4.3, 4.4 | Account policies; JSON destructors | ✅ |
| 5.1, 5.2 | Railgun no-double-spend / shield conservation | 📝 (future) |
| 5.3 | Bridge cannot return spending-key material | 🔒 by-construction |
| 5.7 | Bridge methods policy-classified (runtime gate pending) | 🚧 |
| 5.8–5.11 | Bridge response framing; CLI preflight; modeled provider ops; endpoint hygiene | ✅ |
| 6.1–6.6 | Network policy | ✅ |
| 7.1–7.3 | Provider policy | ✅ |
| 8.1–8.5 | Keystore | ✅ |
| 9.1 | EIP-7951 precompile constants and chain ids | ✅ |
| 10.1, 10.2 | R1 account contract | ✅ |
| 11.1, 11.2 | Uniswap V3 swap helper | ✅ |
| 12.1–12.7 | SPHINCS+ hybrid account contract | ✅ |
| 13.1–13.10 | Cryptographic primitives + helper integrity | 🔒 axiomatized |

## Documentation

- [CLI](./docs/CLI.md)
- [Daemon](./docs/DAEMON.md) — full RPC catalog
- [Architecture](./docs/ARCHITECTURE.md) — module map, sidecars, TUI
- [Security](./SECURITY.md) — trust boundary statement
- [Privacy and Security](./docs/PRIVACY_SECURITY.md)
- [Sepolia R1 account dev flow](./docs/R1_SEPOLIA.md)

## License

TBD.
