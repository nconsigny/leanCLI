# leanKohaku

A formally-verified Ethereum wallet daemon written entirely in **Lean 4**,
with a CLI-first surface. Zrchitected from the ground up for machine-checked proofs of the
critical signing path.

## Goals

- **CLI-first.** The primary interface is a local command-line tool that
  talks to a long-running daemon over a Unix domain socket.
- **Full Lean.** No FFI to Rust/JS crypto libraries in the wallet path.
  Hex parsing, network policy, account policy, TPM custody, and P-256
  precompile modeling live in Lean so the critical path can be reasoned
  about inside the same type system.
- **Iteratively verified.** We do not aim for 100% proof coverage on day
  one. Instead we grow `INVARIANTS.md` alongside the code, and elevate
  each invariant from 📝 (stated) → 🚧 (in progress) → ✅ (proved).
- **Privacy and security by default.** The CLI is not allowed to contact
  nodes or third-party APIs directly. Network-capable daemon operations
  are classified by peer, purpose, and transport, with a deny-by-default
  policy and Lean invariants for strict and Tor modes. Third-party APIs,
  analytics, price feeds, metadata lookups, fiat/onramp calls, crash
  reports, and discovery are denied.
- **Tor as an explicit transport.** Tor is modeled as a first-class
  transport to a configured node, not as permission to use third-party APIs.
- **Local enclave-first keystore boundary.** Wallet code asks a local
  hardware-backed keystore to create keys, expose public keys, and sign
  digests; it must not use an online keystore or import/export raw secrets
  in normal operation.
- **Linux hardware first.** TPM2 and FIDO2 policy is modeled for common HP
  and Lenovo machines first, with the kernel keyring limited to local handle
  storage rather than signing.
- **Ethereum mainnet first, Sepolia for dev.** The wallet targets Ethereum
  L1 mainnet for production. Sepolia is modeled explicitly for development
  and hardware-signing tests.
- **Two account families.** The CLI models regular BIP-39/BIP-32 Ethereum
  EOAs with k1 signing and local hardware-backed R1 smart accounts.
- **Provider-policy oriented.** Provider operations are modeled as data and
  policy-gated before transport exists.
- **Shielded privacy later.** Railgun-style shielded-note semantics are a
  late-stage target built on top of the stricter network posture.

## Non-goals (for now)

- Browser / mobile UI.
- Multi-LLM agent orchestration
- Production readiness — this is a research wallet.

## Layout

```
leanKohaku/
├─ lakefile.lean                  # Lake build config
├─ lean-toolchain                 # pinned Lean version
├─ flake.nix / default.nix        # Nix package scaffold
├─ LeanKohaku.lean                # Root module (re-exports)
├─ LeanKohaku/
│  ├─ App/        CLI and daemon executable roots
│  ├─ Lib/        Client/Core/Spec aggregate roots
│  ├─ Basic.lean
│  ├─ Crypto/      Hex, Secp256k1 scaffolding
│  ├─ Ethereum/    Address, Chain, P256Precompile, Tx
│  ├─ Privacy/     NetworkPolicy
│  ├─ Network/     Endpoint, Provider
│  ├─ Keystore/    Enclave, Linux
│  ├─ Contract/    R1Account
│  ├─ Wallet/      Account
│  ├─ RPC/         JsonRpc
│  ├─ Daemon/      Server
│  ├─ Cli/         Commands
│  └─ Invariants/  Amount, Nonce, TxWellFormed
├─ INVARIANTS.md                  # Living list of properties + proof status
├─ packaging/arch/                # Arch Linux PKGBUILD scaffold
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

Nix scaffolding is available for Linux:

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
./.lake/build/bin/leankohaku privacy
./.lake/build/bin/leankohaku lightclient
./.lake/build/bin/leankohaku keystore
./.lake/build/bin/leankohaku accounts
./.lake/build/bin/leankohaku wallet create r1 work-key
./.lake/build/bin/leankohaku wallet deploy r1 work-key --chain sepolia
./.lake/build/bin/leankohaku wallet list sepolia
./.lake/build/bin/leankohaku daemon help
./.lake/build/bin/leankohaku daemon daily send sepolia 0x0000000000000000000000000000000000000000 0.001
./.lake/build/bin/leankohaku network
./.lake/build/bin/leankohaku security
./.lake/build/bin/leankohaku doctor
./.lake/build/bin/leankohaku policy-check strict configured-node broadcast-tx direct
./.lake/build/bin/leankohaku rpc-check tor configured tor eth_sendRawTransaction
./.lake/build/bin/leankohaku endpoint-check strict local http loopback false
./.lake/build/bin/leankohaku endpoint-check tor configured onion tor false
./.lake/build/bin/leankohaku decode erc20 0xa9059cbb...
./.lake/build/bin/leankohaku balance 0x0000000000000000000000000000000000000000
./.lake/build/bin/leankohaku eoa send daily 0x0000000000000000000000000000000000000000 1
./.lake/build/bin/leankohaku daemon    # starts the daemon in the foreground
```

## Network Privacy

`LeanKohaku.Privacy.NetworkPolicy` is the deny-by-default boundary:

- CLI traffic is limited to local daemon control over loopback.
- Daemon reads use local/light-client loopback by default.
- Broadcast is limited to `eth_sendRawTransaction`.
- Strict mode denies configured-node traffic, including direct broadcast.
- Tor mode may read and broadcast through a configured node over Tor.
- Third-party APIs remain denied even when Tor is enabled.

Denied categories include peer discovery, analytics, telemetry, price
quotes, fiat/onramp calls, metadata/indexer APIs, crash reports, and any
unclassified transport path.

Daemon-backed commands use the local Unix socket. If systemd socket activation
is not available and the socket is missing, the CLI auto-spawns
`leankohaku-daemon` unless `LEANKOHAKU_NO_AUTOSPAWN=1` is set. Invalid CLI input
still exits before any daemon or network path is attempted.

The daemon-side chain path is implemented and policy-gated:

- `balance` maps to `eth_getBalance` against the local provider.
- `nonce`, fee, estimate, token balance, and raw broadcast map to Ethereum
  JSON-RPC methods through the daemon.
- `eoa send` derives nonce/fees/gas, signs EIP-1559 locally in the daemon, and
  broadcasts with `eth_sendRawTransaction`.

Endpoint hygiene is modeled separately:

- Strict mode accepts only local, uncredentialed endpoints over loopback.
- Tor mode accepts local loopback endpoints and uncredentialed configured
  endpoints over Tor.
- Credentialed endpoints are denied to prevent API-key hosted services.
- Third-party endpoints are denied in every mode.

Run the main local regression checks with:

```bash
./script/check_native_helpers.sh
./script/check_cli_isolation.sh
./script/check_privacy_cli.sh
./script/check_m6_keystore_daemon.sh
./script/check_daemon_config.sh
./script/check_m10_autospawn.sh
./script/check_m8_chain_rpc.sh
```

More detail:

- [CLI](./docs/CLI.md)
- [Daemon](./docs/DAEMON.md)
- [Security](./SECURITY.md)
- [Privacy And Security](./docs/PRIVACY_SECURITY.md)
- [Sepolia R1 Account Dev Flow](./docs/R1_SEPOLIA.md)

## Provider Policy

`LeanKohaku.Network.Provider` models the small JSON-RPC surface the daemon
may eventually need. It classifies methods by peer, purpose, and transport
before any runtime networking is implemented.

## Keystore

`LeanKohaku.Keystore.Enclave` models local-only enclave-backed key custody.
Secret import/export is denied by the accepted policy. Native macOS/iOS
Secure Enclave support is modeled for P-256/R1. Linux TPM, FIDO2, Apple
Secure Enclave, and external hardware signers are local-only P-256/R1
custody options.

`LeanKohaku.Keystore.Linux` prefers TPM2 for common HP business
notebooks/workstations and Lenovo ThinkPad/ThinkCentre profiles, falls back
to FIDO2 security keys when TPM2 is absent, and treats the Linux kernel
keyring as a local handle store.

`LeanKohaku.Keystore.Tpm2Runtime` is the local Linux runtime boundary.
It uses local `tpm2-tools` to create TPM-wrapped P-256 keys under
`.leankohaku/keystore/tpm2/<name>/`, writes `public.pem` and `manifest.txt`,
and refuses to overwrite an existing manifest. Key creation and signing are
gated by local `fprintd-verify`, defaulting to `right-index-finger` with
three verification attempts.

Nix and Arch packaging list `tpm2-tools`, `libfido2`, and `fprintd` only as
optional host-integration tools. The Lean wallet does not link to those
libraries or trust them as crypto implementations.

## Accounts

`LeanKohaku.Wallet.Account` defines regular BIP-39/BIP-32 Ethereum EOAs and
local hardware-backed P-256/R1 smart accounts. Mainnet policies are the
defaults; Sepolia policies are available for explicit dev/testnet use.

## R1 Account

`LeanKohaku.Contract.R1Account` is the Lean-level account verifier model:
it stores the P-256 public key, enforces a supported chain id (`1` mainnet
or `11155111` Sepolia), checks nonce equality, constructs the EIP-7951
`h || r || s || qx || qy` precompile input, and increments nonce only after
successful verification.

`Contracts/R1Account/` contains the Verity-oriented Lean source for the
deployable account. `script/r1_sepolia.sh` keeps the local digest/sign/execute
workflow. For same-day Sepolia testing, `solidity/dev/R1AccountDev.sol`
provides a temporary Solidity fallback; it is not the canonical source.

Verity is pinned by `script/setup_verity.sh`. It is not imported into the
default Lake graph yet because upstream Verity currently pins Lean 4.22.0
while leanKohaku pins Lean 4.29.1.

## EOA And Encoding Status

The repo includes pure Lean RLP encoding, EIP-1559 typed transaction
payload/transaction encoding, ERC-20 transfer/approval decoding, and native
secp256k1 field/point arithmetic with ECDSA signing over an already-hashed
digest plus explicit nonce.

Keccak-256 and HMAC-SHA512 are modeled as a narrow HACL* boundary in
`LeanKohaku.Crypto.Hacl`. The intended implementation is HACL's raw
Keccak-with-delimiter API using Ethereum delimiter `0x01`, plus HMAC-SHA512
for BIP32. Runtime EOA signing is not complete until that HACL binding is
wired.

HACL Packages is the only accepted external crypto dependency. Set it up with:

```bash
./script/setup_hacl.sh
export PATH="$PWD/.lake/build/bin:$PATH"
```

## Invariants

See [`INVARIANTS.md`](./INVARIANTS.md). The current proved inventory:

| # | Invariant | Status |
|---|-----------|--------|
| 0.1 | Verified core cannot exfiltrate keys | ✅ |
| 0.2 | Verified core is not a raw signing oracle | ✅ |
| 0.3 | Verified intents cannot sign wrong-chain payloads | ✅ |
| 0.4 | Approval and R1/EOA signer paths correspond to signatures | ✅ |
| 0.5 | R1 TPM policy and EIP-7702 guardrails are enforced | ✅ |
| 1.1 | Checked subtraction preserves totals | ✅ |
| 1.2 | Multi-output send — refuse-insufficient + exact-debit + recipient crediting | ✅ |
| 2.1 | EIP-1559 fee relation | ✅ (by definition) |
| 2.3 | Chain-ID match | ✅ (by definition) |
| 4.3 | Account policies are supported-chain/local-only | ✅ |
| 5.9 | CLI wallet actions preflight only through local daemon | ✅ |
| 5.10 | Daemon action plans stay inside modeled provider operations | ✅ |
| 5.11 | Endpoint hygiene rejects credentialed and third-party endpoints | ✅ |
| 6.1 | CLI only talks to local daemon | ✅ |
| 6.2 | Daemon policies never allow third-party API peers | ✅ |
| 6.3 | Strict mode denies configured-node access | ✅ |
| 6.4 | Third-party purposes are denied; Tor configured-node access must use Tor transport | ✅ |
| 7.1 | Provider non-broadcast methods are reads | ✅ |
| 7.2 | Default mainnet Helios log bypass disabled | ✅ |
| 7.3 | Tor provider access is transport-scoped | ✅ |
| 8.1 | Accepted keystore requests never export secrets | ✅ |
| 8.2 | Accepted keystore requests are local-only | ✅ |
| 8.3 | Accepted signing requires user authorization | ✅ |
| 8.4 | Apple Secure Enclave accepts local Ethereum R1 signing policy | ✅ |
| 8.5 | Linux HP/Lenovo profiles select TPM2 signing first | ✅ |
| 9.1 | P256VERIFY precompile constants and chain ids are modeled | ✅ |
| 10.1 | R1 account accepts only supported-chain operations | ✅ |
| 10.2 | R1 account increments nonce only after EIP-7951 verification | ✅ |
| everything else | — | 📝 / 🚧 |


## License

TBD.
