/*
 * SLH-DSA-SHA2-128-24 GPU signer — one-shot CLI.
 *
 *   Usage:  slhdsa-sha2-128-24-gpu <seed_48B_hex> <message_hex>                   # hedged (default)
 *           slhdsa-sha2-128-24-gpu <seed_48B_hex> <message_hex> <optrand_16B_hex> # explicit opt_rand
 *
 * `seed_48B` = sk_seed(16) || sk_prf(16) || pk_seed(16). Mirrors the interface
 * of `signers/sphincsplus-128-24/slhdsa-sha2-128-24` (the FIPS 205 bit-exact
 * CPU reference) so that `script/slh_dsa_sha2_128_24_fast_signer.py` can call
 * either interchangeably.
 *
 * **Default is hedged** (FIPS 205 §9.2 recommendation). The per-signature
 * randomizer (`opt_rand`) is drawn from the kernel CSPRNG (getrandom(2),
 * fallback /dev/urandom). Gives fault-attack resistance and a "no worse than
 * deterministic" guarantee against bad RNGs. The actual `opt_rand` bytes used
 * are printed to stderr so a hedged sig can be reproduced exactly if needed.
 *
 * Pass a 16-byte hex `opt_rand` as the third positional arg to force a
 * specific randomizer (deterministic mode — only useful for KATs, test
 * fixtures, and cross-validation).
 *
 * Output to stdout (one line, hex, no 0x):
 *   pk_seed(16) || pk_root(16) || sig(3856)
 *
 * Exit status 0 on success, non-zero on error.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include "slhvk.h"

#ifdef __linux__
#include <sys/random.h>
#endif

static int hex_nibble(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int hex_decode(const char* hex, uint8_t* out, size_t outLen) {
    size_t hlen = strlen(hex);
    if (hlen >= 2 && hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X')) {
        hex += 2;
        hlen -= 2;
    }
    if (hlen != outLen * 2) return -1;
    for (size_t i = 0; i < outLen; i++) {
        int hi = hex_nibble(hex[2 * i]);
        int lo = hex_nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i] = (uint8_t) ((hi << 4) | lo);
    }
    return 0;
}

static void hex_print(const uint8_t* buf, size_t len) {
    for (size_t i = 0; i < len; i++) printf("%02x", buf[i]);
    putchar('\n');
}

static void hex_fprint(FILE* f, const uint8_t* buf, size_t len) {
    for (size_t i = 0; i < len; i++) fprintf(f, "%02x", buf[i]);
}

/* Fill `out` with `len` cryptographically secure random bytes. Returns 0 on
 * success, -1 on failure. Tries getrandom(2) first, falls back to reading
 * /dev/urandom. */
static int csprng_fill(uint8_t* out, size_t len) {
#ifdef __linux__
    size_t got = 0;
    while (got < len) {
        ssize_t n = getrandom(out + got, len - got, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            break; /* fall through to /dev/urandom */
        }
        got += (size_t) n;
    }
    if (got == len) return 0;
#endif
    FILE* f = fopen("/dev/urandom", "rb");
    if (!f) return -1;
    size_t n = fread(out, 1, len, f);
    fclose(f);
    return (n == len) ? 0 : -1;
}

static void usage(const char* argv0) {
    fprintf(stderr,
        "Usage:\n"
        "  %s <seed_48B_hex> <message_hex>                     (HEDGED, default — opt_rand from kernel CSPRNG)\n"
        "  %s <seed_48B_hex> <message_hex> <optrand_16B_hex>   (explicit opt_rand — for KATs / cross-validation)\n"
        "  seed = sk_seed(16) || sk_prf(16) || pk_seed(16)\n"
        "Output: hex(pk_seed(16) || pk_root(16) || sig(%d))\n"
        "Env vars:\n"
        "  SLHVK_GPU_DUTY=<0..1>   duty-cycle throttle (sleeps between GPU phases)\n",
        argv0, argv0, SLHVK_SIGNATURE_SIZE);
}

int main(int argc, char** argv) {
    int hedged = 0;
    const char* seedHex = NULL;
    const char* msgHex  = NULL;
    const char* optHex  = NULL; /* only used in deterministic (explicit opt_rand) mode */

    if (argc == 3) {
        /* New default: hedged. opt_rand drawn from kernel CSPRNG. */
        hedged  = 1;
        seedHex = argv[1];
        msgHex  = argv[2];
    } else if (argc == 4 && strcmp(argv[1], "--hedged") == 0) {
        /* Backwards-compat: explicit --hedged flag (now redundant — same as
         * omitting the third positional). */
        hedged  = 1;
        seedHex = argv[2];
        msgHex  = argv[3];
    } else if (argc == 4) {
        /* Deterministic mode: explicit opt_rand as third positional. */
        seedHex = argv[1];
        msgHex  = argv[2];
        optHex  = argv[3];
    } else {
        usage(argv[0]);
        return 2;
    }

    uint8_t seed[3 * SLHVK_N]; // sk_seed || sk_prf || pk_seed
    if (hex_decode(seedHex, seed, sizeof(seed)) != 0) {
        fprintf(stderr, "bad seed hex (need %zu bytes)\n", sizeof(seed));
        return 1;
    }
    uint8_t* skSeed = seed;
    uint8_t* skPrf  = seed + SLHVK_N;
    uint8_t* pkSeed = seed + 2 * SLHVK_N;

    size_t msgHexLen = strlen(msgHex);
    if (msgHexLen >= 2 && msgHex[0] == '0' && (msgHex[1] == 'x' || msgHex[1] == 'X')) msgHexLen -= 2;
    if (msgHexLen & 1) { fprintf(stderr, "message hex must have even length\n"); return 1; }

    uint8_t optrand[SLHVK_N];
    if (hedged) {
        if (csprng_fill(optrand, sizeof(optrand)) != 0) {
            fprintf(stderr, "csprng_fill failed: no getrandom and no /dev/urandom\n");
            return 1;
        }
        fprintf(stderr, "  mode: hedged (opt_rand=");
        hex_fprint(stderr, optrand, sizeof(optrand));
        fprintf(stderr, ")\n");
    } else {
        if (hex_decode(optHex, optrand, sizeof(optrand)) != 0) {
            fprintf(stderr, "bad optrand hex (need %d bytes)\n", SLHVK_N);
            return 1;
        }
    }

    SlhvkContext ctx;
    if (slhvkContextInit(&ctx) != SLHVK_SUCCESS) {
        fprintf(stderr, "slhvkContextInit failed\n"); return 1;
    }

    SlhvkCachedRootTree cache;
    if (slhvkCachedRootTreeInit(ctx, &cache) != SLHVK_SUCCESS) {
        fprintf(stderr, "slhvkCachedRootTreeInit failed\n"); return 1;
    }

    uint8_t pkRoot[SLHVK_N];
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int err = slhvkKeygen(ctx, skSeed, pkSeed, pkRoot, cache);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (err) { fprintf(stderr, "slhvkKeygen failed: %d\n", err); return 1; }
    double keygenS = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    fprintf(stderr, "  keygen (GPU, fused):  %.3fs\n", keygenS);

    size_t msgLen = msgHexLen / 2;
    uint8_t* msg = (uint8_t*) malloc(msgLen ? msgLen : 1);
    if (!msg) { fprintf(stderr, "oom\n"); return 1; }
    if (msgLen && hex_decode(msgHex, msg, msgLen) != 0) {
        fprintf(stderr, "bad message hex\n"); free(msg); return 1;
    }

    uint8_t sig[SLHVK_SIGNATURE_SIZE];
    clock_gettime(CLOCK_MONOTONIC, &t0);
    err = slhvkSignPure(
        ctx, skSeed, skPrf, pkSeed, pkRoot, optrand,
        NULL, 0,           /* no context string */
        msg, msgLen,
        cache, sig
    );
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (err) { fprintf(stderr, "slhvkSignPure failed: %d\n", err); free(msg); return 1; }
    double signS = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    fprintf(stderr, "  sign   (GPU):         %.3fs (%d bytes)\n", signS, SLHVK_SIGNATURE_SIZE);

    uint8_t out[2 * SLHVK_N + SLHVK_SIGNATURE_SIZE];
    memcpy(out,              pkSeed,  SLHVK_N);
    memcpy(out + SLHVK_N,    pkRoot,  SLHVK_N);
    memcpy(out + 2 * SLHVK_N, sig, SLHVK_SIGNATURE_SIZE);

    hex_print(out, sizeof(out));
    free(msg);

    slhvkCachedRootTreeFree(cache);
    slhvkContextFree(ctx);
    return 0;
}
