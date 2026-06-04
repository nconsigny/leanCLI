//! leanCLI C13 (WOTS+C / FORS+C, h=22 d=2 a=19 k=7 w=8, 3688-byte sig)
//! signer crate.
//!
//! The cryptographic core (hash, params, keygen, wots, fors, merkle,
//! sphincs) is vendored verbatim from upstream
//! `nconsigny/SPHINCS-/signer-wasm` @ main — which already targets C13
//! (FIPS 205 §11.2.2 uncompressed 32-byte ADRS + keccak256). This
//! `lib.rs` deliberately omits the upstream `wasm-bindgen` exports
//! (leanCLI spawns the binary via stdio JSON-RPC, not via WASM) and adds
//! a `verifier` module for the shim's local verify-after-sign.
//!
//! `keygen::from_seed_bytes` is the leanCLI-local deterministic-seed
//! derivation appended to the upstream keygen module.

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
