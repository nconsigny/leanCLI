# Crypto sourcing policy

**Policy.** For each cryptographic primitive, use **one** reputable, audited library —
preferring formally-verified implementations where they already exist — and import **only** the
specific primitive needed. No library is pulled in for an algorithm it is not the chosen source of.
Every native dependency is pinned to an exact upstream revision.

**Architecture.** Crypto is invoked via small single-purpose **helper executables** that the wallet
daemon shells out to (`runHexHelper` in `LeanCli/Crypto/Hacl.lean`), **not** linked into the Lean
binary as FFI. This keeps `lake build` lightweight (no CMake/Ninja/cargo in incremental Lean
compilation) and keeps wallet logic FFI-free and reasoned-about. The helpers are built by
`ops/scripts/setup_hacl.sh` + `ops/scripts/setup_secp256k1.sh`; the daemon boot precheck
(`requiredNativeHelpers` in `Daemon/Server/Connection.lean`) refuses to listen if any are missing.
Each helper exe dynamically links the installed `libhacl.so` / `libsecp256k1.so` (via rpath), so the
full library is present at runtime; what is scoped per-helper is which functions each calls. Scoping
the HACL *library build* down to individual algorithms would require HACL cmake feature flags and is
deferred (it is a build-time / on-disk-size optimization, not an attack-surface one — the daemon only
ever invokes the specific helper exes it needs). Pruning unused *helpers* (done in this refactor —
see below) shrinks the precheck dependency set and the audit surface.

## Sources (pinned)

| Library | Upstream | Pinned rev | Pinned in | Source for |
|---|---|---|---|---|
| **HACL\*** (Project Everest — formally verified C) | `github.com/cryspen/hacl-packages` | `05c3d8fb321ed65e3db3a6a8b853019e86fb40a2` | `ops/scripts/setup_hacl.sh` (`HACL_REV`) | Keccak-256, SHA-256, HMAC-SHA-512, PBKDF2-HMAC-SHA-512, ChaCha20-Poly1305 |
| **libsecp256k1** (bitcoin-core — the reference impl) | `github.com/bitcoin-core/secp256k1` | `1a53f4961f337b4d166c25fce72ef0dc88806618` | `ops/scripts/setup_secp256k1.sh` (`SECP_REV`) | ECDSA sign / pubkey / recover / verify (secp256k1) |
| **RustCrypto `ripemd`** | crates.io `ripemd` | `0.1.3` (`native/rustcrypto_helpers/Cargo.lock`) | `native/rustcrypto_helpers/Cargo.toml` | RIPEMD-160 (BIP-32 HASH160 fingerprint only) |

RustCrypto is kept (not dropped) because RIPEMD-160 is a **live** dependency: HACL does not expose
RIPEMD-160, and BIP-32 fingerprints (`Wallet/HDKey.lean::fingerprintIO`) require HASH160 =
RIPEMD-160(SHA-256(·)). This is a deliberate, evidence-based divergence from the refactor brief's
"drop RustCrypto → two bootstrap chains": there is a live consumer, so three chains remain.

## Primitive → helper → consumer map

| Primitive | Helper binary | Lean wrapper | Consumers |
|---|---|---|---|
| Keccak-256 (Ethereum) | `leancli-hacl-keccak256` | `keccak256EthereumIO` | Address, Eip712, Ens, Sphincs (Send/UserOp/Rpc), Wallet/EOA, Daemon/Helpers |
| SHA-256 | `leancli-hacl-sha256` | `sha256IO` | HDKey (HASH160 inner), Mnemonic |
| HMAC-SHA-512 | `leancli-hacl-hmac-sha512` | `hmacSha512IO` | HDKey (BIP-32 CKD) |
| RIPEMD-160 | `leancli-hacl-ripemd160` (RustCrypto) | `ripemd160IO` | HDKey (BIP-32 fingerprint) |
| PBKDF2-HMAC-SHA-512 | `leancli-hacl-pbkdf2` | `pbkdf2HmacSha512IO` | MasterPassphrase, EoaStore, SphincsHybridStore, Mnemonic (BIP-39 seed + keystore KDF) |
| ChaCha20-Poly1305 | `leancli-hacl-chacha20poly1305` | `chacha20Poly1305{Seal,Open}IO` | MasterPassphrase, EoaStore, SphincsHybridStore (keystore AEAD) |
| ECDSA secp256k1 | `leancli-secp256k1-{sign,pubkey,recover,verify}` | `Secp256k1Native.*IO` | EOA signing path |
| SPHINCS+ (SLH-DSA) | `sphincs-*` shims (PQ signer) | `Sphincs/Bridge.lean` | SPHINCS+ hybrid 4337 accounts — see `sidecars/sphincs/` |

## Removed in this refactor (Stream A)

`HMAC-SHA-256` (`leancli-hacl-hmac-sha256`) and `HMAC-DRBG-SHA-256` (`leancli-hacl-hmac-drbg`) were
built and listed in the daemon precheck but had **zero consumers** anywhere in the tree (BIP-32 uses
HMAC-SHA-512; libsecp256k1 does its own RFC-6979 nonce internally). They were pruned — opaque decls +
helper strings + IO wrappers in `Crypto/Hacl.lean`, the two `requiredNativeHelpers` precheck entries,
the two `setup_hacl.sh` build lines, and `native/hacl_helpers/hacl_hmac_{sha256,drbg_sha256}.c`.
Re-add from upstream HACL if a future feature needs them.
