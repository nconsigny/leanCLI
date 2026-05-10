//! Deterministic key derivation from a 32-byte seed.
//!
//! The upstream `signer-wasm` keygen pulled in BIP-39, BIP-32, and k256.
//! That responsibility lives in the daemon (TPM-sealed seed → 32-byte
//! shim input). This module only does the parameter-set-specific KDF
//! and the top-layer subtree build.
//!
//! Derivation matches the upstream `from_private_key` shape with the
//! domain tag updated to `"sphincs-c9-v1"` (parameter-set-distinct, so
//! a given 32-byte seed yields different keys under C9 vs C7). The
//! signer is the only party that needs to reproduce these exact bytes;
//! the on-chain verifier consumes the resulting `(pkSeed, pkRoot)`
//! opaquely.

use crate::hash::{self, U256};
use crate::merkle;

/// Derive `(pk_seed, sk_seed, pk_root)` from a raw 32-byte secret seed.
///
/// Both `pk_seed` and `sk_seed` are stored as [u64; 4] (=U256). `pk_seed`
/// is `mask_n`-truncated to its top 128 bits, matching how the on-chain
/// verifier reads it (`bytes32` argument with bottom 16 bytes zero).
/// `sk_seed` keeps full 256 bits because it never leaves the signer.
pub fn from_seed_bytes(seed: &[u8; 32]) -> (U256, U256, U256) {
    let entropy_input = [&seed[..], b"c9"].concat();
    let keygen_msg = hash::keccak256(
        &[b"sphincs_keygen".as_slice(), &entropy_input].concat(),
    );

    let entropy = hash::keccak256(
        &[
            b"sphincs_signer_v1".as_slice(),
            &hash::to_bytes32(keygen_msg),
        ]
        .concat(),
    );
    let pk_seed = hash::mask_n(hash::keccak256(
        &[b"pk_seed".as_slice(), &hash::to_bytes32(entropy)].concat(),
    ));
    let sk_seed = hash::keccak256(
        &[b"sk_seed".as_slice(), &hash::to_bytes32(entropy)].concat(),
    );

    let pk_root = merkle::build_subtree_root(pk_seed, sk_seed, 1, 0);
    (pk_seed, sk_seed, pk_root)
}
