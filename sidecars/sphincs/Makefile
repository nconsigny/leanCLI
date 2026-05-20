# leanKohaku SPHINCS- shim — builds the parameter-set binaries.
#
# Three parameter sets, three build paths:
#   - SLH-DSA-SHA2-128-24: C, links shared shim/shim_main.c against the
#     vendored sphincsplus reference with the SHA-2 thash backend.
#   - JARDIN-Keccak-128-24: C, links the SAME shim/shim_main.c against
#     the vendored JARDIN-keccak fork (same d/h/a/k/w as the SHA-2
#     variant, but keccak256 thash + 32-byte JARDIN ADRS layout).
#   - C9 (WOTS+C / FORS+C, h=20 d=2 a=12 k=11 w=8): Rust, vendored from
#     upstream `nconsigny/SPHINCS-/signer-wasm` @ 63617e1 with `params.rs`
#     retuned against `legacy/src/SPHINCs-C9Asm.sol` @ 5964b61. The Rust
#     binary speaks the same JSON-RPC stdio protocol as the C shim, so
#     the Lean bridge is parameter-set agnostic.
#
# Outputs are written to OUT_DIR (default: ./bin for local dev,
# overridden by the lake hook to .lake/build/bin/).
#
# Usage:
#   make                            # builds all three binaries
#   make slhdsa                     # NIST SHA-2 variant only
#   make jardin                     # JARDIN-Keccak variant only
#   make c9                         # Rust C9 variant only
#   make clean
#
# Cargo is required for `make c9` (or `make all`); the C paths are
# unaffected if cargo is missing.

CC      ?= cc
CFLAGS  ?= -O3 -Wall -Wextra -Wpedantic -std=c99
LDFLAGS ?=

CARGO   ?= cargo

OUT_DIR ?= bin

SHIM    := shim/shim_main.c

VENDOR_SLHDSA := vendor-slhdsa-sha2-128-24
VENDOR_JARDIN := vendor-jardin-keccak-128-24
VENDOR_C9     := vendor-c9

# C-side source files for the SLH-DSA-SHA2 variant. main.c is intentionally
# excluded — it is replaced by shim_main.c.
SLHDSA_SIGNER_SRCS := address.c fors.c hash_sha2.c merkle.c randombytes.c \
                      sha2.c sign.c utils.c utilsx1.c wots.c wotsx1.c \
                      thash_sha2_simple.c

# C-side source files for the JARDIN-Keccak variant. Same shape as the
# SLH-DSA list but the hash backend (hash_keccak/keccak/thash_keccak)
# replaces (hash_sha2/sha2/thash_sha2_simple).
JARDIN_SIGNER_SRCS := address.c fors.c hash_keccak.c keccak.c merkle.c \
                      randombytes.c sign.c thash_keccak.c utils.c \
                      utilsx1.c wots.c wotsx1.c

SLHDSA_SRCS := $(addprefix $(VENDOR_SLHDSA)/,$(SLHDSA_SIGNER_SRCS)) $(SHIM)
JARDIN_SRCS := $(addprefix $(VENDOR_JARDIN)/,$(JARDIN_SIGNER_SRCS)) $(SHIM)

# C9 Rust sources — listed so make can re-invoke cargo when any of them
# change; cargo's own incremental build handles the actual rebuild.
C9_RUST_SRCS := $(VENDOR_C9)/Cargo.toml \
                $(VENDOR_C9)/src/main.rs \
                $(VENDOR_C9)/src/lib.rs \
                $(VENDOR_C9)/src/params.rs \
                $(VENDOR_C9)/src/hash.rs \
                $(VENDOR_C9)/src/wots.rs \
                $(VENDOR_C9)/src/fors.rs \
                $(VENDOR_C9)/src/merkle.rs \
                $(VENDOR_C9)/src/sphincs.rs \
                $(VENDOR_C9)/src/keygen.rs \
                $(VENDOR_C9)/src/verifier.rs

SLHDSA_BIN := $(OUT_DIR)/sphincs-slhdsa-128-24
JARDIN_BIN := $(OUT_DIR)/sphincs-jardin-keccak-128-24
C9_BIN     := $(OUT_DIR)/sphincs-c9
C9_CARGO_OUT := $(VENDOR_C9)/target/release/sphincs-c9

.PHONY: all slhdsa jardin c9 clean
all: slhdsa jardin c9

slhdsa: $(SLHDSA_BIN)
jardin: $(JARDIN_BIN)
c9:     $(C9_BIN)

$(SLHDSA_BIN): $(SLHDSA_SRCS)
	@mkdir -p $(OUT_DIR)
	$(CC) $(CFLAGS) -I$(VENDOR_SLHDSA) \
	  -DPARAM_SET_NAME='"SLH-DSA-SHA2-128-24"' \
	  -DPARAM_SET_STUB=0 \
	  -o $@ $^ $(LDFLAGS)

$(JARDIN_BIN): $(JARDIN_SRCS)
	@mkdir -p $(OUT_DIR)
	$(CC) $(CFLAGS) -I$(VENDOR_JARDIN) \
	  -DPARAM_SET_NAME='"JARDIN-Keccak-128-24"' \
	  -DPARAM_SET_STUB=0 \
	  -o $@ $^ $(LDFLAGS)

# C9: cargo build --release in vendor-c9/, then copy the binary into bin/.
# cargo's incremental rebuild handles "what changed"; the make-level
# C9_RUST_SRCS dependency only triggers re-invocation, not a full rebuild.
$(C9_BIN): $(C9_RUST_SRCS)
	@mkdir -p $(OUT_DIR)
	cd $(VENDOR_C9) && $(CARGO) build --release
	cp $(C9_CARGO_OUT) $@

clean:
	rm -f $(SLHDSA_BIN) $(JARDIN_BIN) $(C9_BIN)
	rm -rf $(OUT_DIR)
	-cd $(VENDOR_C9) && $(CARGO) clean --quiet 2>/dev/null || true
