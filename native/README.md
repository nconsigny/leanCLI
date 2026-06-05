# `native/` — FFI shims & native crypto helpers

Loopback FFI and single-purpose native helpers for capabilities Lean can't do directly. Wallet
logic stays FFI-free; these are concentrated at runtime boundaries. Two integration styles:

- **`extern_lib`** (linked into every executable via `lakefile.lean`): `lean_uds`, `lean_http`,
  `lean_sqlite`. Built by `lake build` itself.
- **Helper executables** (the daemon shells out to them; built by `ops/scripts/setup_*.sh`, **not**
  `lake build`): the HACL and secp256k1 crypto helpers. See [`docs/CRYPTO_POLICY.md`](../docs/CRYPTO_POLICY.md).

## Every native dependency

| Dir | Upstream / pin | Provides | Consumed by | Integration |
|---|---|---|---|---|
| `lean_uds/` | in-tree C (no external dep) | Unix-domain-socket primitives | wallet + agent daemons | `extern_lib liblean_uds` |
| `lean_http/` | in-tree C over system **libcurl** | loopback HTTP POST | `Agent/Http.lean` (LLM I/O), ENS provider HTTP | `extern_lib liblean_http` |
| `lean_sqlite/` | in-tree C over system **libsqlite3** (FTS5) | SQLite session store | `Agent/Session.lean` | `extern_lib liblean_sqlite` |
| `hacl_helpers/` | **HACL\*** `cryspen/hacl-packages` @ `05c3d8fb…` | Keccak-256, SHA-256, HMAC-SHA-512, PBKDF2-HMAC-SHA-512, ChaCha20-Poly1305 | see CRYPTO_POLICY map | helper exes (`setup_hacl.sh`) |
| `secp256k1_helpers/` | **bitcoin-core/secp256k1** @ `1a53f496…` | ECDSA sign/pubkey/recover/verify | EOA signing | helper exes (`setup_secp256k1.sh`) |
| `rustcrypto_helpers/` | **RustCrypto `ripemd`** `0.1.3` | RIPEMD-160 (BIP-32 HASH160) | `Wallet/HDKey.lean` | helper exe (built within `setup_hacl.sh`) |

System libraries (`libcurl`, `libsqlite3`) are linked via `weakLinkArgs` in `lakefile.lean`.

## Bootstrap

```bash
lake script run setup-helpers     # wraps setup_hacl.sh + setup_secp256k1.sh
# or individually:
ops/scripts/setup_hacl.sh         # HACL helpers + RustCrypto ripemd160
ops/scripts/setup_secp256k1.sh    # libsecp256k1 helpers
```

Each setup script is idempotent (clones once, then `fetch --depth 1` + `checkout --detach` the pinned
rev) and installs helper binaries into `.lake/build/bin/`. The daemon boot precheck refuses to start
if any required helper is missing — running `setup-helpers` is the unblock.

> SPHINCS+ (post-quantum) signer shims live separately under `sidecars/sphincs/` (C/Rust + optional
> Vulkan), built by `lake script run sphincs-shims`. They are not part of `native/`.
