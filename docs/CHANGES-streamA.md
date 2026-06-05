# CHANGES — Stream A (crypto sourcing hygiene)

## What changed
- Added [`docs/CRYPTO_POLICY.md`](CRYPTO_POLICY.md): one-library-per-primitive policy, exact pins,
  helper→consumer map, FFI-free helper-exe architecture.
- Added [`native/README.md`](../native/README.md): every native dependency (3 `extern_lib` shims +
  3 crypto helper sources) with pin, what it provides, and its consumer.
- Pruned two **dead** native crypto helpers (zero consumers anywhere): `HMAC-SHA-256`
  (`leancli-hacl-hmac-sha256`) and `HMAC-DRBG-SHA-256` (`leancli-hacl-hmac-drbg`).
  - `Crypto/Hacl.lean`: removed opaque decls, helper strings, IO wrappers.
  - `Daemon/Server/Connection.lean`: removed the two `requiredNativeHelpers` precheck entries.
  - `ops/scripts/setup_hacl.sh`: removed the two `build_helper` lines + echo lines.
  - Deleted `native/hacl_helpers/hacl_hmac_sha256.c`, `native/hacl_helpers/hacl_hmac_drbg_sha256.c`.

## Evidence-based divergences from the brief
- **RustCrypto kept (not dropped).** `ripemd160IO` backs BIP-32 HASH160 fingerprints
  (`Wallet/HDKey.lean`); HACL doesn't expose RIPEMD-160. So three native bootstrap chains remain
  (HACL, libsecp256k1, RustCrypto-ripemd), not two.
- **HACL build not cmake-scoped.** Helpers dynamically link `libhacl.so`; per-algorithm scoping of
  the library build is a build-time/disk optimization (not attack-surface) and is deferred to avoid
  risking the pinned, working verified-crypto build. Pruning unused *helpers* was the safe win.

## Verification
- HACL @ `05c3d8fb…`, libsecp256k1 @ `1a53f496…`, ripemd `0.1.3` — all pinned to exact revs.
- `lake build`: 263 jobs green, zero `sorryAx`. (Crypto round-trip smoke needs the native helpers
  built — `setup_hacl.sh`/`setup_secp256k1.sh` clone+cmake, not runnable in this offline sandbox;
  the Lean side compiles clean and the precheck list is consistent.)
