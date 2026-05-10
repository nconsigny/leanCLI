//! leanKohaku C9 (WOTS+C / FORS+C) signer crate.
//!
//! Cryptographic core (hash, wots, fors, merkle, sphincs) is a copy of
//! upstream `nconsigny/SPHINCS-/signer-wasm` @ 63617e1, with `params.rs`
//! retuned to C9 (h=20 d=2 a=12 k=11 w=8) against the on-chain verifier
//! `legacy/src/SPHINCs-C9Asm.sol` @ 5964b61. This `lib.rs` deliberately
//! omits the upstream `wasm-bindgen` exports — leanKohaku spawns the
//! binary via stdio JSON-RPC, not via WASM.

pub mod hash;
pub mod params;
pub mod keygen;
pub mod wots;
pub mod fors;
pub mod merkle;
pub mod sphincs;
pub mod verifier;

/// Convert 32 big-endian bytes to [u64; 4] (big-endian word order: [0] = MSW).
pub fn u256_from_be(bytes: &[u8; 32]) -> [u64; 4] {
    [
        u64::from_be_bytes(bytes[0..8].try_into().unwrap()),
        u64::from_be_bytes(bytes[8..16].try_into().unwrap()),
        u64::from_be_bytes(bytes[16..24].try_into().unwrap()),
        u64::from_be_bytes(bytes[24..32].try_into().unwrap()),
    ]
}

pub fn u256_to_be(val: &[u64; 4]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[0..8].copy_from_slice(&val[0].to_be_bytes());
    out[8..16].copy_from_slice(&val[1].to_be_bytes());
    out[16..24].copy_from_slice(&val[2].to_be_bytes());
    out[24..32].copy_from_slice(&val[3].to_be_bytes());
    out
}
