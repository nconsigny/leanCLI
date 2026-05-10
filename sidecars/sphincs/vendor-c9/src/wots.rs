//! WOTS+C: keygen, digest, count grinding, signing.
//!
//! Parameter-driven (W / LOG_W / L / TARGET_SUM read from `params`). C6 used
//! base-16 digits hardcoded into a `[u8; 32]`; this version generalises so the
//! same code drives C9 (base-8, 43 digits, target_sum=208) and C7
//! (base-8, 43 digits, target_sum=151) without algorithmic changes.

use crate::hash::{self, U256};
use crate::params::*;

/// Derive WOTS secret key for chain i.
pub fn wots_secret(sk_seed: U256, layer: u32, tree: u64, kp: u32, chain_idx: u32) -> U256 {
    let mut data = Vec::with_capacity(32 + 4 + 4 + 32 + 4 + 4);
    data.extend_from_slice(&hash::to_bytes32(sk_seed));
    data.extend_from_slice(b"wots");
    data.extend_from_slice(&layer.to_be_bytes());
    data.extend_from_slice(&hash::to_bytes32(hash::u256_from_u32(0))); // tree as u256
    // Actually tree is u64, pack properly
    let mut tree_bytes = [0u8; 32];
    tree_bytes[24..32].copy_from_slice(&tree.to_be_bytes());
    data.truncate(32 + 4 + 4); // rewind
    data.extend_from_slice(&tree_bytes);
    data.extend_from_slice(&kp.to_be_bytes());
    data.extend_from_slice(&chain_idx.to_be_bytes());
    hash::mask_n(hash::keccak256(&data))
}

/// Compute WOTS digest: keccak256(seed || hashAdrs || msgHash || count).
pub fn wots_digest(seed: U256, layer: u32, tree: u64, kp: u32, msg_hash: U256, count: u32) -> U256 {
    let adrs = hash::make_adrs(layer, tree, 0, kp, 0, 0, 0);
    hash::keccak_4x32(seed, adrs, msg_hash, hash::u256_from_u32(count))
}

/// Extract `L` base-`W` digits from digest.
///
/// Mirrors the verifier's per-layer digit decode
/// (`and(shr(mul(ii, LOG_W), d), W_MASK)`): digit `i` is the LOG_W-bit field
/// at bit offset `i*LOG_W` of the 256-bit digest, counted from the least
/// significant end. C6 (W=16, LOG_W=4, L=32), C7 (W=8, LOG_W=3, L=43), and
/// C9 (W=8, LOG_W=3, L=43) all fit because `L * LOG_W <= 256`.
pub fn extract_digits(d: &U256) -> Vec<u8> {
    debug_assert!(L * LOG_W <= 256);
    let bytes = hash::to_bytes32(*d);
    // big-endian view: bytes[0] is the most significant; digit 0 is the
    // least significant LOG_W-bit field, so we walk from the right.
    let mask: u64 = W_MASK;
    let mut digits = Vec::with_capacity(L);
    for i in 0..L {
        let bit = i * LOG_W;
        let byte_idx_from_right = bit / 8;
        let bit_off = bit % 8;
        let lo = bytes[31 - byte_idx_from_right] as u64;
        // A LOG_W-bit field can straddle a byte boundary.
        let hi = if byte_idx_from_right + 1 < 32 {
            bytes[31 - (byte_idx_from_right + 1)] as u64
        } else {
            0
        };
        let combined = lo | (hi << 8); // 16 bits is plenty for LOG_W ≤ 8.
        digits.push(((combined >> bit_off) & mask) as u8);
    }
    digits
}

/// Find counter such that digit sum = TARGET_SUM.
pub fn find_count(seed: U256, layer: u32, tree: u64, kp: u32, msg_hash: U256) -> Result<(u32, U256, Vec<u8>), String> {
    for count in 0..10_000_000u32 {
        let d = wots_digest(seed, layer, tree, kp, msg_hash, count);
        let digits = extract_digits(&d);
        let sum: usize = digits.iter().map(|&x| x as usize).sum();
        if sum == TARGET_SUM {
            return Ok((count, d, digits));
        }
    }
    Err("WOTS+C count grinding failed".into())
}

/// Full WOTS+C keygen: returns (secret_keys, wots_pk).
pub fn keygen(seed: U256, sk_seed: U256, layer: u32, tree: u64, kp: u32) -> (Vec<U256>, U256) {
    let base_adrs = hash::make_adrs(layer, tree, 0, kp, 0, 0, 0);
    let mut sks = Vec::with_capacity(L);
    let mut pk_elements = Vec::with_capacity(L);

    for i in 0..L {
        let sk_i = wots_secret(sk_seed, layer, tree, kp, i as u32);
        sks.push(sk_i);
        let chain_adrs = hash::set_chain_index(base_adrs, i as u32);
        let pk_i = hash::chain_hash(seed, chain_adrs, sk_i, 0, (W - 1) as u32);
        pk_elements.push(pk_i);
    }

    let pk_adrs = hash::make_adrs(layer, tree, 1, kp, 0, 0, 0); // type=WOTS_PK
    let wots_pk = hash::th_multi(seed, pk_adrs, &pk_elements);
    (sks, wots_pk)
}

/// WOTS+C keygen returning only the public key (fast path for tree building).
pub fn keygen_pk_only(seed: U256, sk_seed: U256, layer: u32, tree: u64, kp: u32) -> U256 {
    keygen(seed, sk_seed, layer, tree, kp).1
}

/// Sign: produce (sigma, count).
pub fn sign(seed: U256, sks: &[U256], layer: u32, tree: u64, kp: u32, msg_hash: U256) -> Result<(Vec<U256>, u32), String> {
    let (count, _d, digits) = find_count(seed, layer, tree, kp, msg_hash)?;
    let base_adrs = hash::make_adrs(layer, tree, 0, kp, 0, 0, 0);
    let mut sigma = Vec::with_capacity(L);

    for i in 0..L {
        let chain_adrs = hash::set_chain_index(base_adrs, i as u32);
        let sigma_i = hash::chain_hash(seed, chain_adrs, sks[i], 0, digits[i] as u32);
        sigma.push(sigma_i);
    }

    Ok((sigma, count))
}
