#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.lake/build/bin"

expect() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    printf 'native helper check failed\nexpected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

expect "$("$BIN/leankohaku-hacl-sha256" abcd)" \
  "0x123d4c7ef2d1600a1b3a0f6addc60a10f05a3495c9409f2ecbf4cc095d000a6b"

"$BIN/leankohaku-hacl-ripemd160" 00 | grep -Eq '^0x[0-9a-f]{40}$'

expect "$("$BIN/leankohaku-secp256k1-pubkey" \
  0000000000000000000000000000000000000000000000000000000000000001 compressed)" \
  "0x0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

printf 'native helper checks passed\n'
