#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOCK="/tmp/leancli-m6-check-$$.sock"
DATA="$(mktemp -d /tmp/leancli-m6-check.XXXXXX)"
LOG="$(mktemp /tmp/leancli-m6-check-log.XXXXXX)"

cleanup() {
  set +e
  LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null 2>&1
  if [[ -n "${daemon_pid:-}" ]]; then
    wait "$daemon_pid" >/dev/null 2>&1
  fi
  rm -rf "$DATA" "$LOG" "$SOCK"
}
trap cleanup EXIT

cd "$ROOT"
lake build >/dev/null
ops/scripts/check_cli_isolation.sh >/dev/null

LEANCLI_SOCKET="$SOCK" \
XDG_DATA_HOME="$DATA" \
PATH="$ROOT/.lake/build/bin:$PATH" \
"$ROOT/.lake/build/bin/leancli-daemon" >"$LOG" 2>&1 &
daemon_pid="$!"

for _ in {1..50}; do
  [[ -S "$SOCK" ]] && break
  sleep 0.1
done

if [[ ! -S "$SOCK" ]]; then
  printf 'M6 check failed: daemon socket was not created\n' >&2
  cat "$LOG" >&2 || true
  exit 1
fi

run_expect_code() {
  local expected="$1"
  shift
  local code
  set +e
  LEANCLI_SOCKET="$SOCK" XDG_DATA_HOME="$DATA" "$ROOT/.lake/build/bin/leancli" "$@" >/tmp/leancli-m6-check-out 2>&1
  code="$?"
  set -e
  if [[ "$code" != "$expected" ]]; then
    printf 'M6 check failed: expected exit %s for %s, got %s\n' "$expected" "$*" "$code" >&2
    cat /tmp/leancli-m6-check-out >&2
    exit 1
  fi
}

run_expect_code 0 wallet list sepolia
run_expect_code 1 wallet create sepolia 'bad/key'
run_expect_code 1 wallet sign sepolia 'bad/key' 0000000000000000000000000000000000000000000000000000000000000000
run_expect_code 1 wallet send sepolia 'bad/key' 0x0000000000000000000000000000000000000000 1

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null
wait "$daemon_pid" >/dev/null 2>&1 || true
unset daemon_pid

grep -q '"method":"tpm.listSepolia"' "$LOG"
grep -q '"method":"tpm.createSepolia"' "$LOG"
grep -q '"method":"tpm.signSepolia"' "$LOG"
grep -q '"method":"r1.sendSepolia"' "$LOG"

printf 'M6 keystore daemon checks passed\n'
