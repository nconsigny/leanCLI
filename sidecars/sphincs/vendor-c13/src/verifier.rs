//! Rust port of the C13 on-chain verifier (`src/SPHINCs-C13Asm.sol`).
//!
//! Used for verify-after-sign locally. The on-chain verifier remains the
//! trust anchor for any signature that travels to a chain; this Rust port
//! exists so that `signWithVerify` in the Lean bridge can fail fast if the
//! freshly-produced signature would be rejected on-chain.
//!
//! The verify LOGIC is parameter-driven (every offset computed from the
//! `params::*` constants; layout is the FIPS 205 §11.2.2 uncompressed
//! 32-byte ADRS shared across the C-series), so the same code that backed
//! C9 verifies C13 once compiled against the C13 `params.rs`. C13 layout:
//!   sig[0..16]              R               (FORS+C grinding nonce)
//!   sig[16..128]            FORS secrets    (K * N = 7 * 16 = 112)
//!   sig[128..1952]          FORS auth paths ((K-1) * A * N = 6 * 19 * 16 = 1824)
//!   sig[1952..2640]         HT layer 0 WOTS sigma   (L * N = 43 * 16 = 688)
//!   sig[2640..2644]         HT layer 0 count        (4 bytes, big-endian)
//!   sig[2644..2820]         HT layer 0 auth path    (h' * N = 11 * 16 = 176)
//!   sig[2820..3508]         HT layer 1 WOTS sigma
//!   sig[3508..3512]         HT layer 1 count
//!   sig[3512..3688]         HT layer 1 auth path
//!
//! TODO(on-chain KAT): this port is byte-offset-derived from the C13
//! params and the shared C-series verify shape; it is exercised by the
//! local keygen→sign→verify roundtrip (self-consistent with the upstream
//! signer — exactly what the daemon's verify-after-sign guard needs) but
//! has NOT yet been cross-checked against a known-answer vector from the
//! deployed C13 verifier 0xce176df2…14d23d. Confirm a KAT before treating
//! "the deployed verifier accepts our signature" as proved.
//!
//! `pk_seed` and `pk_root` are passed in as 32-byte values (full U256
//! words), matching how the Solidity entrypoint receives `bytes32`. Both
//! are expected to have their bottom 16 bytes already zero.

use crate::hash::{self, U256};
use crate::params::*;

/// Read a single 16-byte chain element at byte offset `off` of `sig`,
/// returning it as a U256 with the top 128 bits set and bottom 128 zero
/// (matching the verifier's `and(calldataload, N_MASK)`).
fn read_n(sig: &[u8], off: usize) -> U256 {
    let mut buf = [0u8; 32];
    buf[..N].copy_from_slice(&sig[off..off + N]);
    hash::from_bytes32(&buf)
}

/// Match the Solidity h_msg: keccak256(seed || root || R || message ||
/// 0xFF..FF). The Solidity verifier inlines this with `mstore` calls.
fn h_msg(pk_seed: U256, pk_root: U256, r: U256, message: U256) -> U256 {
    hash::h_msg(pk_seed, pk_root, r, message)
}

/// Verify a C9 signature byte-blob against `(pk_seed, pk_root, message)`.
/// Returns `true` iff the on-chain verifier would accept.
pub fn verify(pk_seed: U256, pk_root: U256, message: U256, sig: &[u8]) -> bool {
    if sig.len() != SIG_SIZE {
        return false;
    }

    // ---- H_msg + tree-index extraction ----
    let r = read_n(sig, 0);
    let digest = h_msg(pk_seed, pk_root, r, message);

    // C9: htIdx := and(shr(132, digest), 0xFFFFF) — bits 132..152 of digest.
    // Bit position is K*A: 132 for C9, 128 for C7. Same expression.
    let ht_idx = (hash::u256_shr(&digest, K * A) & ((1u64 << H) - 1)) as u64;

    // FORS+C forced-zero check: bits (K-1)*A .. K*A of digest must be 0.
    // C9: bits 120..132 (Yul `and(shr(120, dVal), 0xFFF)`).
    if (hash::u256_shr(&digest, K * A - A) & ((1u64 << A) - 1)) != 0 {
        return false;
    }

    // ---- FORS+C: rebuild k roots from secrets + auth paths ----
    //
    // C13 keys the FORS instance by the per-message hypertree leaf (the
    // FIPS 205 §11.2.2 field split): the bottom subtree (idx_tree0 → tree
    // address) and leaf (idx_leaf0 → kp), with the FORS tree number folded
    // into tree_index. This mirrors `fors::sign_fors` / `build_fors_tree`
    // exactly — it is the divergence from the older C9 FORS keying
    // (tree=0, kp=i) that this port must follow.
    let idx_leaf0 = (ht_idx & ((1u64 << SUBTREE_H) - 1)) as u32;
    let idx_tree0 = ht_idx >> SUBTREE_H;
    let mut fors_roots: [U256; K] = [hash::ZERO; K];
    for t in 0..(K - 1) {
        let leaf_idx = (hash::u256_shr(&digest, t * A) & ((1u64 << A) - 1)) as u32;
        let secret = read_n(sig, 16 + t * N);

        // leaf (height 0): tree_index = (t << A) | leaf_idx
        let leaf_adrs =
            hash::make_adrs(0, idx_tree0, 3, idx_leaf0, 0, 0, ((t as u32) << A) | leaf_idx);
        let mut node = hash::th(pk_seed, leaf_adrs, secret);

        // Walk auth path of height A. Height h+1 node: tree_index =
        // (t << (A-1-h)) | parent_idx.
        let mut path_idx = leaf_idx as usize;
        for h in 0..A {
            let sib = read_n(sig, AUTH_START + t * (A * N) + h * N);
            let parent_idx = (path_idx >> 1) as u32;
            let ti = ((t as u32) << (A - 1 - h)) | parent_idx;
            let adrs = hash::make_adrs(0, idx_tree0, 3, idx_leaf0, 0, (h + 1) as u32, ti);
            node = if path_idx & 1 == 0 {
                hash::th_pair(pk_seed, adrs, node, sib)
            } else {
                hash::th_pair(pk_seed, adrs, sib, node)
            };
            path_idx >>= 1;
        }
        fors_roots[t] = node;
    }
    // Last tree (forced-zero): the stored "secret" IS the tree's Merkle
    // root; hash it once under the leaf-keyed ADRS (tree_index = (K-1)<<A).
    {
        let last_secret = read_n(sig, 16 + (K - 1) * N);
        let last_adrs =
            hash::make_adrs(0, idx_tree0, 3, idx_leaf0, 0, 0, ((K - 1) as u32) << A);
        fors_roots[K - 1] = hash::th(pk_seed, last_adrs, last_secret);
    }

    // FORS public key: th_multi over the K roots with type=4 (FORS_ROOTS),
    // ADRS bound to the hypertree leaf (tree=idx_tree0, kp=idx_leaf0).
    let fors_pk = {
        let roots_adrs = hash::make_adrs(0, idx_tree0, 4, idx_leaf0, 0, 0, 0);
        hash::th_multi(pk_seed, roots_adrs, &fors_roots)
    };

    // ---- Hypertree ----
    let mut current = fors_pk;
    let mut idx_tree = ht_idx;
    let mut sig_off = HT_START; // C9: 2112 (C7 was 1936)

    for layer in 0..D {
        let idx_leaf = idx_tree & ((1u64 << SUBTREE_H) - 1);
        idx_tree >>= SUBTREE_H;

        // wotsAdrs: layer || idx_tree || idx_leaf, type=0
        let wots_adrs = hash::make_adrs(layer as u32, idx_tree, 0, idx_leaf as u32, 0, 0, 0);

        // Count is at sigOff + L*N (4 big-endian bytes).
        let count_off = sig_off + L * N;
        let mut count_bytes = [0u8; 4];
        count_bytes.copy_from_slice(&sig[count_off..count_off + 4]);
        let count = u32::from_be_bytes(count_bytes);

        // d = keccak256(seed || wotsAdrs || currentNode || count)
        let d_val = hash::keccak_4x32(pk_seed, wots_adrs, current, hash::u256_from_u32(count));

        // Validate digit sum.
        let digits = crate::wots::extract_digits(&d_val);
        let digit_sum: usize = digits.iter().map(|&x| x as usize).sum();
        if digit_sum != TARGET_SUM {
            return false;
        }

        // Complete each chain: starting from sigma[i], iterate `W-1-digit[i]` steps.
        let mut pk_elements: Vec<U256> = Vec::with_capacity(L);
        for i in 0..L {
            let sigma_i = read_n(sig, sig_off + i * N);
            let chain_adrs = hash::set_chain_index(wots_adrs, i as u32);
            // From the verifier: steps = W - 1 - digit (i.e. (W-1) - digit).
            let pk_i = hash::chain_hash(
                pk_seed,
                chain_adrs,
                sigma_i,
                digits[i] as u32,
                ((W as u32) - 1) - (digits[i] as u32),
            );
            pk_elements.push(pk_i);
        }

        // wotsPk = th_multi(seed, pkAdrs, pk_elements) with type=1 (WOTS_PK).
        let pk_adrs = hash::make_adrs(layer as u32, idx_tree, 1, idx_leaf as u32, 0, 0, 0);
        let wots_pk = hash::th_multi(pk_seed, pk_adrs, &pk_elements);

        // Walk Merkle auth path of height SUBTREE_H.
        let auth_off = count_off + 4;
        let mut node = wots_pk;
        let mut m_idx = idx_leaf as usize;
        for h in 0..SUBTREE_H {
            let sib = read_n(sig, auth_off + h * N);
            let parent_idx = (m_idx >> 1) as u32;
            let adrs = hash::make_adrs(layer as u32, idx_tree, 2, 0, 0, (h + 1) as u32, parent_idx);
            node = if m_idx & 1 == 0 {
                hash::th_pair(pk_seed, adrs, node, sib)
            } else {
                hash::th_pair(pk_seed, adrs, sib, node)
            };
            m_idx >>= 1;
        }

        current = node;
        sig_off = auth_off + SUBTREE_H * N;
    }

    current == pk_root
}
