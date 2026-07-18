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
  LEANCLI_SOCKET="$SOCK" XDG_DATA_HOME="$DATA" LEANCLI_PASSPHRASE='m6-pass' "$ROOT/.lake/build/bin/leancli" "$@" </dev/null >/tmp/leancli-m6-check-out 2>&1
  code="$?"
  set -e
  if [[ "$code" != "$expected" ]]; then
    printf 'M6 check failed: expected exit %s for %s, got %s\n' "$expected" "$*" "$code" >&2
    cat /tmp/leancli-m6-check-out >&2
    exit 1
  fi
}

# Verify the thin CLI forwards keystore operations to the daemon over
# JSON-RPC (the daemon-log method assertions below confirm the routing).
# The R1/P-256 + TPM-Sepolia surface these checks used to exercise was
# removed; the current keystore surface is EOA import/unlock/list.
ANVIL_MNEMONIC='test test test test test test test test test test test junk'
run_expect_code 0 wallet list
run_expect_code 0 wallet import anvil "$ANVIL_MNEMONIC"
run_expect_code 0 wallet unlock anvil
run_expect_code 2 wallet create eoa

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null
wait "$daemon_pid" >/dev/null 2>&1 || true
unset daemon_pid

grep -q '"method":"eoa.list"' "$LOG"
grep -q '"method":"eoa.import"' "$LOG"
grep -q '"method":"eoa.unlock"' "$LOG"

printf 'M6 keystore daemon checks passed\n'
