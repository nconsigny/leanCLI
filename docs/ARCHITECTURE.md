# leanKohaku — Architecture

A map of the repository as it actually exists, complementing `README.md`
(goals & user-visible behavior), `INVARIANTS.md` (proof obligations & status),
and `CLAUDE.md` (build & contributor workflow).

The codebase is **60 Lean source files** plus C/Rust FFI helpers. There are
**no `sorry`s** in proofs and no `axiom`s outside the explicit FFI boundary
(opaque `Hacl` / `Tpm2` primitives). Every theorem in `LeanKohaku/Invariants/`
is closed.

## Layered structure

```
Entry points        LeanKohaku/App/Main.lean    LeanKohaku/App/DaemonMain.lean
                        │                      │
Surfaces            Cli/                  RPC/   Daemon/
                        │                      │
Domain              Wallet/   Ethereum/   Keystore/   Contract/   Privacy/   Network/
                        │
Primitives          Crypto/   Encoding/
                        │
FFI boundary        c/hacl_helpers   c/secp256k1_helpers   c/lean_uds   c/rustcrypto_helpers
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

### `Cli/`
- `Commands.lean` — `Command` ADT, validation, preflight against the privacy
  policy (~480 lines).
- `DaemonClient.lean` — UDS client.
- `Passphrase.lean` — passphrase prompting.

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
| `c/rustcrypto_helpers/` | RustCrypto | optional Rust ripemd160 binary |

Build automation: `script/setup_hacl.sh`, `script/setup_secp256k1.sh`,
`script/setup_uds.sh`. The UDS C lib is linked into the Lean library via
`extern_lib liblean_uds` in `lakefile.lean`. The other helpers are external
binaries invoked at runtime.

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
