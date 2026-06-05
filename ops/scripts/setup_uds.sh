#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEAN_PREFIX="$(lean --print-prefix)"
OUT_DIR="${ROOT}/.lake/build/native"

mkdir -p "$OUT_DIR"

cc -O2 -fPIC \
  -I"${LEAN_PREFIX}/include" \
  -c "${ROOT}/native/lean_uds/lean_uds.c" \
  -o "${OUT_DIR}/lean_uds.o"

ar rcs "${OUT_DIR}/liblean_uds.a" "${OUT_DIR}/lean_uds.o"

cat <<EOF
UDS FFI built at:
  ${OUT_DIR}/lean_uds.o
  ${OUT_DIR}/liblean_uds.a
EOF
