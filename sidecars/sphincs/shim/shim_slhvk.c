/*
 * shim_slhvk.c — Vulkan-GPU backend adapter for the SLH-DSA-SHA2-128-24
 * stdio JSON-RPC shim.
 *
 * Implements the three sphincsplus reference entry points that
 * `shim_main.c` calls — `crypto_sign_seed_keypair`, `crypto_sign_signature`,
 * `crypto_sign_verify` — in terms of the vendored Vulkan signer
 * (`vendor-slhvk-sha2-128-24/`, API in `slhvk.h`). Linking this against the
 * SAME `shim_main.c` yields `sphincs-slhdsa-128-24-vk`, which speaks the
 * identical wire protocol as the CPU `sphincs-slhdsa-128-24` binary — so the
 * Lean bridge (`LeanCli/Sphincs/Bridge.lean`) drives the GPU signer with no
 * protocol change, purely via `SignerBackend.vulkan` executable selection.
 *
 * Key/seed layout is identical to the CPU reference (that is WHY this is a
 * drop-in backend, not a new param set):
 *   seed = sk_seed(16) || sk_prf(16) || pk_seed(16)            (48 B)
 *   pk   = pk_seed(16) || pk_root(16)                          (32 B)
 *   sk   = sk_seed(16) || sk_prf(16) || pk_seed(16) || pk_root(16)  (64 B)
 *
 * ───────────────────────────────────────────────────────────────────────
 * STATUS: UNTESTED IN THIS TREE — requires a Vulkan device + libvulkan +
 * glslangValidator to build (`make slhvk`), neither of which is available in
 * the CI/sandbox that produced this file. The logic is transcribed from the
 * vendored `cli.c` (the upstream reference invocation) and the slhvk.h
 * contract; it has NOT been compiled or run here. Validate on GPU hardware
 * against `vendor-slhvk-sha2-128-24/kat-counter0.json` before trusting it.
 *
 * SAFETY: even if this backend is wrong, the daemon never broadcasts a bad
 * signature — `Sphincs.signWithVerify` always re-verifies on the CPU
 * reference backend, so a GPU/envelope mismatch fails closed (no signature
 * leaves the daemon) rather than producing an invalid on-chain tx.
 * ───────────────────────────────────────────────────────────────────────
 */

#include <string.h>
#include <stddef.h>
#include <stdint.h>

#include "api.h"      /* SPX_N, SPX_BYTES, SPX_PK_BYTES, SPX_SK_BYTES */
#include "slhvk.h"

/* Lazily-initialised process-global Vulkan context. The shim is a one-shot
 * process (one JSON-RPC call per spawn), so a single context for the
 * lifetime of the process is sufficient; it is never freed explicitly
 * (process exit reclaims it). */
static SlhvkContext g_ctx = NULL;

static int ensure_ctx(void) {
    if (g_ctx) return 0;
    return slhvkContextInit(&g_ctx) == SLHVK_SUCCESS ? 0 : -1;
}

/* `shim_main.c` injects the caller-supplied `optrand` (deterministic /
 * KAT-counter mode) through this hook — the CPU reference routes it into
 * its `randombytes`. Here we capture it and use it as the slhvk `addrnd`
 * randomizer, so `sphincs-slhdsa-128-24-vk` is bit-reproducible per
 * (key, message, optrand) exactly like the CPU shim and the GPU `cli.c`.
 * When no optrand is supplied (len 0) signing falls back to deterministic
 * addrnd = pk_seed. */
static unsigned char g_optrand[SPX_N];
static int           g_have_optrand = 0;

void set_rng_buffer(const unsigned char *buf, unsigned long long len) {
    if (buf && len >= (unsigned long long)SPX_N) {
        memcpy(g_optrand, buf, SPX_N);
        g_have_optrand = 1;
    } else {
        g_have_optrand = 0;
    }
}

/* pk = pk_seed || pk_root ; sk = sk_seed || sk_prf || pk_seed || pk_root */
int crypto_sign_seed_keypair(unsigned char *pk, unsigned char *sk,
                             const unsigned char *seed) {
    if (ensure_ctx()) return -1;
    const unsigned char *sk_seed = seed;
    const unsigned char *sk_prf  = seed + SPX_N;
    const unsigned char *pk_seed = seed + 2 * SPX_N;

    SlhvkCachedRootTree cache;
    if (slhvkCachedRootTreeInit(g_ctx, &cache) != SLHVK_SUCCESS) return -1;

    unsigned char pk_root[SPX_N];
    int e = slhvkKeygen(g_ctx, sk_seed, pk_seed, pk_root, cache);
    slhvkCachedRootTreeFree(cache);
    if (e) return -1;

    memcpy(pk,             pk_seed, SPX_N);
    memcpy(pk + SPX_N,     pk_root, SPX_N);
    memcpy(sk,             sk_seed, SPX_N);
    memcpy(sk + SPX_N,     sk_prf,  SPX_N);
    memcpy(sk + 2 * SPX_N, pk_seed, SPX_N);
    memcpy(sk + 3 * SPX_N, pk_root, SPX_N);
    return 0;
}

/* Detached signature over the raw message `m` (the 32-byte userOpHash).
 * `slhvkSignPure` applies the FIPS 205 external envelope (empty context
 * string) internally, matching the on-chain verifier and the CPU reference's
 * external mode. opt_rand is deterministic (= pk_seed): SLH-DSA verification
 * does not depend on the randomizer, so any value yields a valid signature;
 * we avoid kernel CSPRNG so the shim stays reproducible. */
int crypto_sign_signature(unsigned char *sig, size_t *siglen,
                          const unsigned char *m, size_t mlen,
                          const unsigned char *sk) {
    if (ensure_ctx()) return -1;
    const unsigned char *sk_seed = sk;
    const unsigned char *sk_prf  = sk + SPX_N;
    const unsigned char *pk_seed = sk + 2 * SPX_N;
    const unsigned char *pk_root = sk + 3 * SPX_N;

    SlhvkCachedRootTree cache;
    if (slhvkCachedRootTreeInit(g_ctx, &cache) != SLHVK_SUCCESS) return -1;
    /* Rebuild the cached XMSS root tree (not persisted across the per-call
     * process boundary); also re-derives pk_root, which must equal sk's. */
    unsigned char chk_root[SPX_N];
    if (slhvkKeygen(g_ctx, sk_seed, pk_seed, chk_root, cache)) {
        slhvkCachedRootTreeFree(cache); return -1;
    }
    if (memcmp(chk_root, pk_root, SPX_N) != 0) {
        slhvkCachedRootTreeFree(cache); return -1;  /* sk inconsistent */
    }

    unsigned char addrnd[SPX_N];
    memcpy(addrnd, g_have_optrand ? g_optrand : pk_seed, SPX_N);

    int e = slhvkSignPure(g_ctx, sk_seed, sk_prf, pk_seed, pk_root, addrnd,
                          NULL, 0,            /* empty context string */
                          m, mlen, cache, sig);
    slhvkCachedRootTreeFree(cache);
    if (e) return -1;
    *siglen = SPX_BYTES;
    return 0;
}

/* Verify a detached signature. `pk = pk_seed || pk_root`. Batch size 1. */
int crypto_sign_verify(const unsigned char *sig, size_t siglen,
                       const unsigned char *m, size_t mlen,
                       const unsigned char *pk) {
    if (siglen != SPX_BYTES) return -1;
    if (ensure_ctx()) return -1;
    const unsigned char *pk_seed = pk;
    const unsigned char *pk_root = pk + SPX_N;

    const uint8_t *ctx_strs[1]  = { NULL };
    uint8_t        ctx_sizes[1] = { 0 };
    const uint8_t *pk_seeds[1]  = { pk_seed };
    const uint8_t *pk_roots[1]  = { pk_root };
    const uint8_t *sigs[1]      = { sig };
    const uint8_t *msgs[1]      = { m };
    size_t         msg_sizes[1] = { mlen };
    int            results[1]   = { 0 };

    if (slhvkVerifyPure(g_ctx, 1, ctx_strs, ctx_sizes, pk_seeds, pk_roots,
                        sigs, msgs, msg_sizes, results) != SLHVK_SUCCESS) {
        return -1;
    }
    return results[0] ? 0 : -1;
}
