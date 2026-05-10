//! C9 parameter constants: W+C_F+C h=20, d=2, a=12, k=11, w=8.
//!
//! Cross-checked against the on-chain verifier
//! `legacy/src/SPHINCs-C9Asm.sol` at upstream commit
//! 5964b61d9912f7fa510b07e0bf63e529148b304a:
//!   - sig length:        3816 bytes        (Yul `eq(sig.length, 3816)`)
//!   - hypertree height:  20 bits           (Yul `and(shr(132, digest), 0xFFFFF)`)
//!   - layers:            d = 2             (Yul `lt(layer, 2)`)
//!   - subtree height:    h' = 10           (Yul `and(idxTree, 0x3FF)`, H/D)
//!   - WOTS chains:       l = 43            (Yul `lt(i, 43)`)
//!   - WOTS digit width:  3 bits, w = 8     (Yul `and(shr(mul(ii,3),d), 0x7)`)
//!   - WOTS target sum:   208               (Yul `iszero(eq(digitSum, 208))`)
//!   - FORS trees:        k = 11 (last one forced-zero)
//!   - FORS tree height:  a = 12            (Yul `lt(h, 12)` for auth path)
//!   - FORS forced-zero:  bits 120..131     (Yul `and(shr(120, dVal), 0xFFF)`)
//!   - hash truncation:   N_MASK = 16 bytes (Yul `0xFF..00..` upper half)
//!
//! The cryptographic core (hash.rs, wots.rs, fors.rs, merkle.rs, sphincs.rs)
//! is identical to upstream C6; only the constants below differ. The same
//! grinding-chain construction (digit-sum target for WOTS+C, forced-zero
//! last tree for FORS+C) applies to all parameter sets.
//!
//! Parameter rationale relative to C7 (h=24, a=16, k=8): C9 raises k from
//! 8 to 11 and lowers a from 16 to 12, trading a slightly larger sig
//! (+112 bytes) for ~16x faster keygen (FORS leaves per tree go from
//! 65536 to 4096) and a 4337 verify-gas budget (~300K) that fits modern
//! userOp limits. h drops from 24 to 20 because d stays at 2 and h' is
//! halved relative to the legacy spec.

pub const N: usize = 16; // hash output bytes (128 bits, top half of keccak)
pub const H: usize = 20;        // C9: 20 (was 24 in C7)
pub const D: usize = 2;
pub const SUBTREE_H: usize = 10; // C9: H / D = 10 (was 12 in C7)
pub const A: usize = 12;        // C9: 12 (was 16 in C7)
pub const K: usize = 11;        // C9: 11 (was 8 in C7); last tree forced-zero
pub const W: usize = 8;
pub const LOG_W: usize = 3;     // log2(W); base-W digits are 3 bits wide
pub const L: usize = 43;        // 43 chains post-checksum-elimination (same as C7)
pub const TARGET_SUM: usize = 208; // C9: 208 (was 151 in C7)
pub const W_MASK: u64 = 0x7;    // 3-bit digit mask

// Signature layout (R = N = 16 bytes)
pub const FORS_START: usize = N;
pub const AUTH_START: usize = N + K * N;                       // 16 + 11*16 = 192
pub const HT_START:   usize = AUTH_START + (K - 1) * A * N;    // 192 + 10*12*16 = 2112
pub const LAYER_SIZE: usize = L * N + 4 + SUBTREE_H * N;       // 43*16 + 4 + 10*16 = 852
pub const SIG_SIZE:   usize = HT_START + D * LAYER_SIZE;       // 2112 + 2*852 = 3816

// Compile-time consistency assertion: a future edit that desyncs L/SIG_SIZE
// from the on-chain verifier's `eq(sig.length, 3816)` must fail to build.
const _: () = {
    assert!(SIG_SIZE == 3816, "SIG_SIZE must equal 3816 to match SphincsC9Asm.verify");
    assert!(K * A == 132, "FORS digest occupies bits 0..132 of msg digest (K=11, A=12)");
    assert!(L * LOG_W >= 128, "WOTS+C must cover the full 128-bit message hash");
};
