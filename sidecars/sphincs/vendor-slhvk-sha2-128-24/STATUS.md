# slhvk-sha2-128-24 — Port Status

Fork of [conduition/slhvk](https://github.com/conduition/slhvk) (Vulkan compute-shader
SLH-DSA signer) re-parameterized for **SLH-DSA-SHA2-128-24** (NIST SP 800-230 IPD).

## ✅ Working & validated — fully deterministic, fast

| | Output | Time |
|---|---|---|
| Keygen — CPU reference (`signers/sphincsplus-128-24/`) | `pk_root = 432c5a42c22ed8378bdea3da205c6ba7` | ~2 min |
| Keygen — GPU port | **byte-identical** | **0.61 s** |
| Sign — CPU reference | ~3 min | |
| Sign — GPU port | **byte-identical, 100 % deterministic** | **1.06 s** |

`sha256(sig)` is identical across 16+ consecutive runs. **~50–200× speedup** over the CPU reference.

## Determinism story (lessons learned)

The original symptom was non-deterministic `merkle_path[XMSS_HEIGHT-1]` at h'=22.
Several GLSL-side workarounds (coherent qualifiers, top-level serialization,
event splitting, CPU XMSS overwrite) hid the symptom but didn't address the
cause.

**Root cause** was actually a **missing `vkCmdPipelineBarrier` in keygen**
(`src/keygen.c`) between the XMSS-leaves shader (`COMPUTE_SHADER` /
`SHADER_WRITE`) and the cache copy (`TRANSFER` / `TRANSFER_READ`) operating on
the same buffer. The cache was being read while the leaves shader was still
writing it, so the cached XMSS root tree had race-corrupted leaves. Signing
consumed that racy cache and produced different auth paths each run; the
"NVIDIA driver race in the merkle build" was always a downstream symptom.

Two barriers now in place; both are required:
1. `keygen.c`: `COMPUTE_SHADER` / `SHADER_WRITE` → `TRANSFER` / `TRANSFER_READ`
   between the leaves shader and the cache copy.
2. `signing.c`: `TRANSFER` / `TRANSFER_WRITE` → `ALL_COMMANDS` / `SHADER_READ`
   after the cache → `primaryXmssNodesBuffer` copy.

## What changed vs upstream slhvk

1. **Parameter set** (`include/slhvk.h`, `src/shaders/common.comp`): n=16,
   h=22, d=1, h'=22, a=24, k=6, lgw=2, w=4. Derives sig=3856 B, m=21 B,
   l=68 chains.
2. **`w=4` base-w path** added in both `convert_to_base_w` (GLSL) and
   `hashToBaseW` (C). Upstream only had `w∈{16, 256}`.
3. **Fused `keygen_xmss_leaves.comp`** — computes 68 WOTS chain tips inline
   per XMSS leaf, eliminating the 4.25 GB intermediate `WOTS_CHAIN_BUFFER`
   that would exceed Vulkan's per-descriptor 4 GB cap. ~80 lines of new GLSL.
4. **Missing keygen barrier added** — see above. This is the deterministic-
   output fix.
5. **FORS bit-extraction switched** to FIPS 205 ACVP **MSB-first** `base_2^b`
   in `src/hashing.c`. The CPU reference (`signers/sphincsplus-128-24/fors.c`)
   was updated to match. Repo-wide MSB-first migration is still in progress
   for the Keccak family and on-chain Solidity verifiers.
6. **`SLHVK_GPU_DUTY` throttle + full dispatch chunking** — env var in
   `(0, 1]`. When `< 1.0`, the three heaviest GPU phases are split into N
   sub-dispatches via `vkCmdDispatchBase` on dispatch-base-flagged pipelines,
   each submitted as its own `vkQueueSubmit` with a fence wait + CPU sleep
   between them, so the GPU genuinely idles in the gaps:
   - **WOTS tips precompute** (signing, primary queue)
   - **Keygen XMSS leaves** (one-time per key, primary queue)
   - **FORS leaves gen** (signing, secondary queue)
   Three prebuilt cmd buffer variants pair with these: `presign_with_wots`
   (fast path), `presign_no_wots` (chunked path), `fors_with_leaves` (fast),
   `fors_no_leaves` (chunked). Override chunk count with `SLHVK_GPU_CHUNKS=N`
   (default 8). The first chunk in each path replicates the staging→device
   input copies that the prebuilt cmd buffer would have done; the security
   wipe `vkCmdFillBuffer` is left to the no-leaves cmd buffer's preamble (if
   we wiped in chunk 0, the no-leaves's later copy would propagate zeros).
   Measured on RTX 5080 Laptop, vs CPU reference (sphincsplus-128-24):
   - `SLHVK_GPU_DUTY=1.0` (default, fast path) → sign 1.05 s, ~100 % GPU
   - `SLHVK_GPU_DUTY=0.6` → sign 2.28 s, ~50 % avg GPU
   - `SLHVK_GPU_DUTY=0.4` → sign 3.42 s, **~46 % avg GPU** (nvidia-smi @ 10 Hz)
   **All duty cycles produce signatures bit-identical to the CPU reference**
   (verified 20/20 runs at DUTY=0.4).
7. **CLI binary** (`cli.c` → `slhdsa-sha2-128-24-gpu`) with the same arg
   shape as the CPU reference. The Python wrapper
   (`script/slh_dsa_sha2_128_24_gpu_signer.py`) no longer needs retry-and-dedup
   now that the GPU output is bit-stable.

## Build & test

```bash
cd signers/slhvk-sha2-128-24
make lib/libslhvk.a     # Vulkan signer library
make cli                # CLI binary: slhdsa-sha2-128-24-gpu

# Smoke (one keygen + one sign, deterministic):
./slhdsa-sha2-128-24-gpu \
  000102030405060708090a0b0c0d0e0f00000000000000000000000000000000101112131415161718191a1b1c1d1e1f \
  00 \
  00000000000000000000000000000000
# Expected pk_root: 432c5a42c22ed8378bdea3da205c6ba7
# Expected sha256(sig): 4bd288d50e934993...

# Same, but throttle to 80 % GPU so the desktop stays responsive:
SLHVK_GPU_DUTY=0.8 ./slhdsa-sha2-128-24-gpu <skSeed_hex> 00 <msg_hex>
```

## Performance (NVIDIA RTX 5080 Laptop GPU)

| Operation | CPU reference | GPU (DUTY=1.0) | GPU (DUTY=0.6) |
|---|---|---|---|
| Keygen (h'=22, 2²² leaves) | ~2 min | **0.59 s** | 1.00 s |
| Sign (full bit-exact)      | ~3 min | **1.05 s** | 2.28 s |
| Combined fresh signature   | ~5 min | ~1.7 s     | ~3.3 s |
