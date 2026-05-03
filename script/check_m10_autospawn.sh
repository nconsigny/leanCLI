#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="/tmp/leankohaku-m10-autospawn-$$.sock"
SYSTEMD_SOCK="/tmp/leankohaku-m10-systemd-$$.sock"
RUNTIME="$(mktemp -d /tmp/leankohaku-m10-runtime.XXXXXX)"
OUT="$(mktemp /tmp/leankohaku-m10-out.XXXXXX)"
ACTIVATE_LOG="$(mktemp /tmp/leankohaku-m10-activate.XXXXXX)"

cleanup() {
  set +e
  LEANKOHAKU_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leankohaku" daemon stop >/dev/null 2>&1
  LEANKOHAKU_SOCKET="$SYSTEMD_SOCK" LEANKOHAKU_NO_AUTOSPAWN=1 \
    "$ROOT/.lake/build/bin/leankohaku" daemon stop >/dev/null 2>&1
  if [[ -n "${activate_pid:-}" ]]; then
    kill "$activate_pid" >/dev/null 2>&1
    wait "$activate_pid" >/dev/null 2>&1
  fi
  rm -rf "$RUNTIME" "$OUT" "$ACTIVATE_LOG" "$SOCK" "$SYSTEMD_SOCK"
}
trap cleanup EXIT

cd "$ROOT"
lake build >/dev/null

set +e
LEANKOHAKU_SOCKET="$SOCK" \
XDG_RUNTIME_DIR="$RUNTIME" \
LEANKOHAKU_NO_AUTOSPAWN=1 \
"$ROOT/.lake/build/bin/leankohaku" daemon ping >"$OUT" 2>&1
disabled_code="$?"
set -e

if [[ "$disabled_code" != 2 ]]; then
  printf 'M10 autospawn check failed: disabled autospawn should exit 2\n' >&2
  cat "$OUT" >&2
  exit 1
fi

LEANKOHAKU_SOCKET="$SOCK" \
XDG_RUNTIME_DIR="$RUNTIME" \
"$ROOT/.lake/build/bin/leankohaku" daemon ping >"$OUT"

grep -q '"ok":true' "$OUT"
[[ -S "$SOCK" ]]

LEANKOHAKU_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leankohaku" daemon stop >/dev/null

if command -v systemd-socket-activate >/dev/null 2>&1; then
  systemd-socket-activate \
    --listen="$SYSTEMD_SOCK" \
    --setenv="LEANKOHAKU_SOCKET=$SYSTEMD_SOCK" \
    "$ROOT/.lake/build/bin/leankohaku-daemon" >"$ACTIVATE_LOG" 2>&1 &
  activate_pid="$!"

  for _ in {1..50}; do
    [[ -S "$SYSTEMD_SOCK" ]] && break
    sleep 0.1
  done

  if [[ ! -S "$SYSTEMD_SOCK" ]]; then
    printf 'M10 autospawn check failed: systemd socket was not created\n' >&2
    cat "$ACTIVATE_LOG" >&2 || true
    exit 1
  fi

  LEANKOHAKU_SOCKET="$SYSTEMD_SOCK" LEANKOHAKU_NO_AUTOSPAWN=1 \
    "$ROOT/.lake/build/bin/leankohaku" daemon ping >"$OUT"
  grep -q '"ok":true' "$OUT"

  LEANKOHAKU_SOCKET="$SYSTEMD_SOCK" LEANKOHAKU_NO_AUTOSPAWN=1 \
    "$ROOT/.lake/build/bin/leankohaku" daemon stop >/dev/null

  kill "$activate_pid" >/dev/null 2>&1
  wait "$activate_pid" >/dev/null 2>&1 || true
  unset activate_pid
fi

printf 'M10 autospawn checks passed\n'
