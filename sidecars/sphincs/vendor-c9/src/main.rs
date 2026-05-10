//! C9 stdio JSON-RPC dispatcher.
//!
//! Wire-protocol-identical to `sidecars/sphincs/shim/shim_main.c` so the
//! Lean bridge in `LeanKohaku/Sphincs/Bridge.lean` is unchanged across
//! parameter sets. Methods:
//!   info    {}                                  -> { paramSet, sigBytes,
//!                                                    pkBytes, skBytes,
//!                                                    seedBytes, stub }
//!   keygen  { seedHex }                         -> { pkSeed, pkRoot, sk }
//!   sign    { sk, digest, optrand? }            -> { sig }
//!   verify  { pkSeed, pkRoot, digest, sig }     -> { ok }
//!
//! Invocation:
//!   sphincs-c9 --rpc '<json-line>'              (one-shot via argv)
//!   echo '<json>' | sphincs-c9                  (one-shot via stdin)
//!
//! Trust model is identical to the C shim: untrusted by the daemon, every
//! output's length is re-validated Lean-side, and `signWithVerify` reruns
//! `verify` locally before returning success.
//!
//! Wire shape for `pkSeed` / `pkRoot` is 32 hex bytes each (full U256
//! words, with the meaningful 16 bytes in the high half), matching the
//! `bytes32` ABI of the on-chain `SphincsC9Asm.verify` entrypoint. `sk`
//! is `pkSeed||skSeed||pkRoot` = 96 bytes, mirroring how the upstream
//! `sphincs::sign` consumes its triple. `seedHex` is 32 raw entropy
//! bytes (the daemon's responsibility to hand in TPM-sealed material).

use sphincs_c9_signer::{hash, keygen, sphincs, u256_from_be, verifier};
use sphincs_c9_signer::params::*;

use std::io::{self, Read, Write};
use std::process::ExitCode;

const PARAM_SET_NAME: &str = "C9";
const DIGEST_BYTES: usize = 32;

// ---------- minimal JSON helpers ----------
//
// We parse just enough to extract top-level fields ("method", "id",
// "params"), and within `params` we pull flat string/number values.
// Anything unexpected becomes a -32700 / -32600 error; the daemon
// re-validates everything anyway.

/// Walk to the matching closing brace, respecting strings (with \\ escapes
/// only). Returns the byte index AFTER the closing `}`.
fn skip_object(s: &str) -> Option<usize> {
    let bytes = s.as_bytes();
    if bytes.is_empty() || bytes[0] != b'{' {
        return None;
    }
    let mut depth = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        match bytes[i] {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i + 1);
                }
            }
            b'"' => {
                i += 1;
                while i < bytes.len() && bytes[i] != b'"' {
                    if bytes[i] == b'\\' && i + 1 < bytes.len() {
                        i += 2;
                        continue;
                    }
                    i += 1;
                }
                if i >= bytes.len() {
                    return None;
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Find a top-level field of the JSON object `obj` by `key`, returning the
/// raw substring of the value (trimmed of leading whitespace, untrimmed at
/// the trailing comma/brace).
fn find_field<'a>(obj: &'a str, key: &str) -> Option<&'a str> {
    let bytes = obj.as_bytes();
    if bytes.is_empty() || bytes[0] != b'{' {
        return None;
    }
    let mut i = 1usize;
    while i < bytes.len() {
        // skip whitespace
        while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b'\n' | b'\r') {
            i += 1;
        }
        if i >= bytes.len() {
            return None;
        }
        if bytes[i] == b'}' {
            return None;
        }
        if bytes[i] != b'"' {
            return None;
        }
        // read key string
        i += 1;
        let key_start = i;
        while i < bytes.len() && bytes[i] != b'"' {
            if bytes[i] == b'\\' && i + 1 < bytes.len() {
                i += 2;
                continue;
            }
            i += 1;
        }
        if i >= bytes.len() {
            return None;
        }
        let this_key = &obj[key_start..i];
        i += 1; // closing quote
        // ':'
        while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b'\n' | b'\r') {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b':' {
            return None;
        }
        i += 1;
        while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b'\n' | b'\r') {
            i += 1;
        }
        if i >= bytes.len() {
            return None;
        }
        let val_start = i;
        // skip value
        match bytes[i] {
            b'"' => {
                i += 1;
                while i < bytes.len() && bytes[i] != b'"' {
                    if bytes[i] == b'\\' && i + 1 < bytes.len() {
                        i += 2;
                        continue;
                    }
                    i += 1;
                }
                if i >= bytes.len() {
                    return None;
                }
                i += 1;
            }
            b'{' => match skip_object(&obj[i..]) {
                Some(rel) => i += rel,
                None => return None,
            },
            b'-' | b'0'..=b'9' => {
                if bytes[i] == b'-' {
                    i += 1;
                }
                while i < bytes.len() && bytes[i].is_ascii_digit() {
                    i += 1;
                }
            }
            _ => return None,
        }
        let val_end = i;
        if this_key == key {
            return Some(&obj[val_start..val_end]);
        }
        // skip whitespace, expect ',' or '}'
        while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b'\n' | b'\r') {
            i += 1;
        }
        if i >= bytes.len() {
            return None;
        }
        match bytes[i] {
            b',' => {
                i += 1;
            }
            b'}' => return None,
            _ => return None,
        }
    }
    None
}

/// Strip surrounding quotes from a JSON string literal. Does not decode
/// escapes — the daemon only sends pure-ASCII hex, so escapes shouldn't
/// appear; if they do we conservatively return None.
fn as_string(raw: &str) -> Option<&str> {
    let b = raw.as_bytes();
    if b.len() < 2 || b[0] != b'"' || b[b.len() - 1] != b'"' {
        return None;
    }
    let inner = &raw[1..raw.len() - 1];
    if inner.contains('\\') {
        return None;
    }
    Some(inner)
}

fn as_int(raw: &str) -> Option<i64> {
    raw.parse().ok()
}

// ---------- response emitters ----------

fn emit_error(id: Option<i64>, code: i32, msg: &str) {
    let id_str = match id {
        Some(n) => n.to_string(),
        None => "null".to_string(),
    };
    // No JSON-escaping is needed for our static error messages (no quotes).
    let _ = writeln!(
        io::stdout(),
        "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{code},\"message\":\"{msg}\"}},\"id\":{id_str}}}"
    );
    let _ = io::stdout().flush();
}

fn emit_result(id: Option<i64>, body: &str) {
    let id_str = match id {
        Some(n) => n.to_string(),
        None => "null".to_string(),
    };
    let _ = writeln!(
        io::stdout(),
        "{{\"jsonrpc\":\"2.0\",\"result\":{{{body}}},\"id\":{id_str}}}"
    );
    let _ = io::stdout().flush();
}

// ---------- parameter-set sizes (must match Lean bridge expectations) ----------

const PK_BYTES: usize = 64;       // 2 * 32 (pkSeed || pkRoot, each as bytes32 word)
const SK_BYTES: usize = 96;       // 3 * 32 (pkSeed || skSeed || pkRoot)
const SEED_BYTES: usize = 32;     // 32-byte secret entropy
const SIG_BYTES: usize = SIG_SIZE; // 3816

// ---------- hex helpers ----------

fn hex_decode_n(s: &str, out: &mut [u8]) -> Result<(), &'static str> {
    let s = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    if s.len() != out.len() * 2 {
        return Err("hex length mismatch");
    }
    hex::decode_to_slice(s, out).map_err(|_| "invalid hex")
}

fn hex_encode(b: &[u8]) -> String {
    hex::encode(b)
}

// ---------- handlers ----------

fn handle_info(id: Option<i64>) {
    let body = format!(
        "\"paramSet\":\"{PARAM_SET_NAME}\",\"sigBytes\":{},\"pkBytes\":{},\"skBytes\":{},\"seedBytes\":{},\"stub\":false",
        SIG_BYTES, PK_BYTES, SK_BYTES, SEED_BYTES,
    );
    emit_result(id, &body);
}

fn handle_keygen(id: Option<i64>, params: &str) {
    let seed_field = match find_field(params, "seedHex").and_then(as_string) {
        Some(s) => s,
        None => return emit_error(id, -32602, "missing seedHex"),
    };
    let mut seed = [0u8; SEED_BYTES];
    if let Err(e) = hex_decode_n(seed_field, &mut seed) {
        return emit_error(id, -32602, e);
    }

    let (pk_seed, sk_seed, pk_root) = keygen::from_seed_bytes(&seed);

    // Wire format: full 32-byte U256 words for everything.
    let pk_seed_b = hash::to_bytes32(pk_seed);
    let sk_seed_b = hash::to_bytes32(sk_seed);
    let pk_root_b = hash::to_bytes32(pk_root);

    let mut sk_buf = [0u8; SK_BYTES];
    sk_buf[0..32].copy_from_slice(&pk_seed_b);
    sk_buf[32..64].copy_from_slice(&sk_seed_b);
    sk_buf[64..96].copy_from_slice(&pk_root_b);

    let body = format!(
        "\"pkSeed\":\"{}\",\"pkRoot\":\"{}\",\"sk\":\"{}\"",
        hex_encode(&pk_seed_b),
        hex_encode(&pk_root_b),
        hex_encode(&sk_buf),
    );
    emit_result(id, &body);
}

fn handle_sign(id: Option<i64>, params: &str) {
    let sk_field = match find_field(params, "sk").and_then(as_string) {
        Some(s) => s,
        None => return emit_error(id, -32602, "missing sk"),
    };
    let dg_field = match find_field(params, "digest").and_then(as_string) {
        Some(s) => s,
        None => return emit_error(id, -32602, "missing digest"),
    };
    // optrand is accepted but unused: C9 signing is deterministic given
    // (sk_seed, message). Accepting the field keeps the protocol
    // identical to the C shim.
    let _ = find_field(params, "optrand");

    let mut sk_buf = [0u8; SK_BYTES];
    if let Err(e) = hex_decode_n(sk_field, &mut sk_buf) {
        return emit_error(id, -32602, e);
    }
    let mut digest_buf = [0u8; DIGEST_BYTES];
    if let Err(e) = hex_decode_n(dg_field, &mut digest_buf) {
        return emit_error(id, -32602, e);
    }

    let mut pk_seed_b = [0u8; 32];
    pk_seed_b.copy_from_slice(&sk_buf[0..32]);
    let mut sk_seed_b = [0u8; 32];
    sk_seed_b.copy_from_slice(&sk_buf[32..64]);
    let mut pk_root_b = [0u8; 32];
    pk_root_b.copy_from_slice(&sk_buf[64..96]);

    let pk_seed = u256_from_be(&pk_seed_b);
    let sk_seed = u256_from_be(&sk_seed_b);
    let pk_root = u256_from_be(&pk_root_b);
    let message = u256_from_be(&digest_buf);

    let sig = match sphincs::sign(pk_seed, sk_seed, pk_root, message) {
        Ok(v) => v,
        Err(e) => {
            // Static-string-friendly: avoid leaking dynamic allocation
            // in the JSON; truncate hard.
            let _ = e;
            return emit_error(id, -32603, "sign failed");
        }
    };
    if sig.len() != SIG_BYTES {
        return emit_error(id, -32603, "internal sig size mismatch");
    }
    let body = format!("\"sig\":\"{}\"", hex_encode(&sig));
    emit_result(id, &body);
}

fn handle_verify(id: Option<i64>, params: &str) {
    let pk_seed_field = find_field(params, "pkSeed").and_then(as_string);
    let pk_root_field = find_field(params, "pkRoot").and_then(as_string);
    let digest_field = find_field(params, "digest").and_then(as_string);
    let sig_field = find_field(params, "sig").and_then(as_string);
    let (pks, pkr, dg, sg) = match (pk_seed_field, pk_root_field, digest_field, sig_field) {
        (Some(a), Some(b), Some(c), Some(d)) => (a, b, c, d),
        _ => return emit_error(id, -32602, "verify requires pkSeed/pkRoot/digest/sig"),
    };
    let mut pk_seed_b = [0u8; 32];
    let mut pk_root_b = [0u8; 32];
    let mut digest_b = [0u8; DIGEST_BYTES];
    if hex_decode_n(pks, &mut pk_seed_b).is_err()
        || hex_decode_n(pkr, &mut pk_root_b).is_err()
        || hex_decode_n(dg, &mut digest_b).is_err()
    {
        return emit_error(id, -32602, "pkSeed/pkRoot/digest hex error");
    }
    let mut sig_buf = vec![0u8; SIG_BYTES];
    if hex_decode_n(sg, &mut sig_buf).is_err() {
        return emit_error(id, -32602, "sig length mismatch");
    }
    let pk_seed = u256_from_be(&pk_seed_b);
    let pk_root = u256_from_be(&pk_root_b);
    let message = u256_from_be(&digest_b);
    let ok = verifier::verify(pk_seed, pk_root, message, &sig_buf);
    let body = format!("\"ok\":{}", if ok { "true" } else { "false" });
    emit_result(id, &body);
}

// ---------- dispatcher ----------

fn dispatch(line: &str) {
    // Extract id, method, params from the top-level object.
    let id_raw = find_field(line, "id");
    let id: Option<i64> = id_raw.and_then(as_int);
    if id_raw.is_some() && id.is_none() {
        // Don't try to echo a non-numeric id — keep it null.
        return emit_error(None, -32600, "id must be numeric");
    }
    let method_raw = match find_field(line, "method") {
        Some(s) => s,
        None => return emit_error(id, -32600, "missing method"),
    };
    let method = match as_string(method_raw) {
        Some(s) => s,
        None => return emit_error(id, -32600, "method must be string"),
    };
    let params = find_field(line, "params").unwrap_or("{}");
    match method {
        "info" => handle_info(id),
        "keygen" => handle_keygen(id, params),
        "sign" => handle_sign(id, params),
        "verify" => handle_verify(id, params),
        _ => emit_error(id, -32601, "method not found"),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 3 && args[1] == "--rpc" {
        dispatch(&args[2]);
        return ExitCode::SUCCESS;
    }
    if args.len() != 1 {
        let _ = writeln!(io::stderr(), "Usage: {} [--rpc <json-line>]", args[0]);
        return ExitCode::from(2);
    }
    // One request per stdin read; matches the C shim's one-shot semantics.
    let mut buf = String::new();
    if io::stdin().read_to_string(&mut buf).is_err() || buf.trim().is_empty() {
        let _ = writeln!(io::stderr(), "{}: empty stdin", args[0]);
        return ExitCode::from(2);
    }
    dispatch(buf.trim());
    ExitCode::SUCCESS
}
