#!/usr/bin/env bash
# Build the lean_http FFI shim into .lake/build/native. Idempotent;
# safe to re-run. Mirrors script/setup_uds.sh exactly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEAN_PREFIX="$(lean --print-prefix)"
OUT_DIR="${ROOT}/.lake/build/native"

mkdir -p "$OUT_DIR"

# libcurl-dev presence: we only need the headers + a -lcurl-able shared
# object. `curl-config --cflags --libs` is the canonical probe.
if ! command -v curl-config >/dev/null 2>&1; then
  echo "ERROR: curl-config not found; install libcurl development headers" >&2
  exit 1
fi

CURL_CFLAGS="$(curl-config --cflags)"
CURL_LIBS="$(curl-config --libs)"

cc -O2 -fPIC \
  -I"${LEAN_PREFIX}/include" \
  ${CURL_CFLAGS} \
  -c "${ROOT}/c/lean_http/lean_http.c" \
  -o "${OUT_DIR}/lean_http.o"

ar rcs "${OUT_DIR}/liblean_http.a" "${OUT_DIR}/lean_http.o"

cat <<EOF
HTTP FFI built at:
  ${OUT_DIR}/lean_http.o
  ${OUT_DIR}/liblean_http.a
libcurl: $(curl-config --version)
linker hint (caller links libcurl): ${CURL_LIBS}
EOF
