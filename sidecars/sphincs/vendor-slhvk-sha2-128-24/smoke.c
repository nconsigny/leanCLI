// Runtime smoke test for slhvk-sha2-128-24.
// Just init context and attempt keygen; report the first error we hit.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "slhvk.h"

int main(void) {
    fprintf(stderr, "=== build-time params ===\n");
    fprintf(stderr, "N=%d, h=%d, d=%d, h'=%d, a=%d, k=%d, lgw=%d, w=%d\n",
        SLHVK_N, SLHVK_HYPERTREE_HEIGHT, SLHVK_HYPERTREE_LAYERS, SLHVK_XMSS_HEIGHT,
        SLHVK_FORS_TREE_HEIGHT, SLHVK_FORS_TREE_COUNT, SLHVK_LOG_W, SLHVK_WOTS_CHAIN_LEN);
    fprintf(stderr, "WOTS chains: %d (l1=%d, l2=%d)\n",
        SLHVK_WOTS_CHAIN_COUNT, SLHVK_WOTS_CHAIN_COUNT1, SLHVK_WOTS_CHAIN_COUNT2);
    fprintf(stderr, "sig size: %d bytes\n", SLHVK_SIGNATURE_SIZE);
    fprintf(stderr, "msg digest: %d bytes (M1=%d M2=%d FORS=%d)\n",
        SLHVK_MESSAGE_DIGEST_SIZE,
        SLHVK_TREE_ADDRESS_DIGEST_SIZE, SLHVK_KEYPAIR_ADDRESS_DIGEST_SIZE, SLHVK_FORS_DIGEST_SIZE);

    fprintf(stderr, "=== init context ===\n");
    SlhvkContext ctx;
    int err = slhvkContextInit(&ctx);
    if (err) { fprintf(stderr, "ctx init failed: %d\n", err); return 1; }

    fprintf(stderr, "=== init cached tree ===\n");
    SlhvkCachedRootTree cache;
    err = slhvkCachedRootTreeInit(ctx, &cache);
    if (err) { fprintf(stderr, "cache init failed: %d\n", err); return 1; }

    fprintf(stderr, "=== keygen (h=22, will fail if WOTS_CHAIN_BUFFER > 4 GB binding cap) ===\n");
    uint8_t skSeed[SLHVK_N] = {0}, pkSeed[SLHVK_N] = {0}, pkRoot[SLHVK_N];
    // Test seed 2: distinct from the first cross-check.
    for (int i = 0; i < SLHVK_N; i++) { skSeed[i] = 0xa0 + i; pkSeed[i] = 0xb0 + i; }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    err = slhvkKeygen(ctx, skSeed, pkSeed, pkRoot, cache);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double keygen_s = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;

    if (err) {
        fprintf(stderr, "keygen returned %d after %.3fs\n", err, keygen_s);
        return 2;
    }
    fprintf(stderr, "keygen: %.3fs\n", keygen_s);
    fprintf(stderr, "pkSeed = ");
    for (int i = 0; i < SLHVK_N; i++) fprintf(stderr, "%02x", pkSeed[i]);
    fprintf(stderr, "\npkRoot = ");
    for (int i = 0; i < SLHVK_N; i++) fprintf(stderr, "%02x", pkRoot[i]);
    fprintf(stderr, "\n");

    slhvkCachedRootTreeFree(cache);
    slhvkContextFree(ctx);
    return 0;
}
