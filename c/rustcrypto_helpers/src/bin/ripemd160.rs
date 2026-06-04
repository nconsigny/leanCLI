// SPDX-License-Identifier: MIT
//
// RIPEMD-160 helper backed by RustCrypto's `ripemd` crate.

use ripemd::{Digest, Ripemd160};

fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn decode_hex(input: &str) -> Result<Vec<u8>, String> {
    let hex = input
        .strip_prefix("0x")
        .or_else(|| input.strip_prefix("0X"))
        .unwrap_or(input)
        .as_bytes();

    if hex.len() % 2 != 0 {
        return Err("hex input has odd length".to_string());
    }

    let mut out = Vec::with_capacity(hex.len() / 2);
    for pair in hex.chunks_exact(2) {
        let hi = hex_digit(pair[0]).ok_or_else(|| "invalid hex input".to_string())?;
        let lo = hex_digit(pair[1]).ok_or_else(|| "invalid hex input".to_string())?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

fn print_hex(bytes: &[u8]) {
    print!("0x");
    for b in bytes {
        print!("{b:02x}");
    }
    println!();
}

fn main() {
    let mut args = std::env::args();
    let program = args.next().unwrap_or_else(|| "leancli-hacl-ripemd160".to_string());
    let Some(input_hex) = args.next() else {
        eprintln!("usage: {program} <hex>");
        std::process::exit(2);
    };
    if args.next().is_some() {
        eprintln!("usage: {program} <hex>");
        std::process::exit(2);
    }

    let input = match decode_hex(&input_hex) {
        Ok(input) => input,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };

    let digest = Ripemd160::digest(&input);
    print_hex(&digest);
}
