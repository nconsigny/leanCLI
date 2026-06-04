#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_HOME="$(mktemp -d /tmp/leancli-config-check.XXXXXX)"
SOCK="/tmp/leancli-config-check-$$.sock"
OVERRIDE_SOCK="/tmp/leancli-config-override-$$.sock"
LOG="$(mktemp /tmp/leancli-config-log.XXXXXX)"
OUT="$(mktemp /tmp/leancli-config-out.XXXXXX)"

cleanup() {
  set +e
  LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null 2>&1
  LEANCLI_SOCKET="$OVERRIDE_SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null 2>&1
  if [[ -n "${daemon_pid:-}" ]]; then
    wait "$daemon_pid" >/dev/null 2>&1
  fi
  rm -rf "$CONFIG_HOME" "$LOG" "$OUT" "$SOCK" "$OVERRIDE_SOCK"
}
trap cleanup EXIT

cd "$ROOT"
lake build >/dev/null

mkdir -p "$CONFIG_HOME/leancli"
cat >"$CONFIG_HOME/leancli/daemon.json" <<JSON
{
  "socket_path": "$SOCK",
  "chain_id": 31337,
  "rpc_url": "http://127.0.0.1:8545",
  "network_policy": "strict"
}
JSON

XDG_CONFIG_HOME="$CONFIG_HOME" \
PATH="$ROOT/.lake/build/bin:$PATH" \
"$ROOT/.lake/build/bin/leancli-daemon" >"$LOG" 2>&1 &
daemon_pid="$!"

for _ in {1..50}; do
  [[ -S "$SOCK" ]] && break
  sleep 0.1
done

if [[ ! -S "$SOCK" ]]; then
  printf 'daemon config check failed: configured socket was not created\n' >&2
  cat "$LOG" >&2 || true
  exit 1
fi

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" daemon ping >"$OUT"
grep -q '"chainId":31337' "$OUT"

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null
wait "$daemon_pid" >/dev/null 2>&1 || true
unset daemon_pid

XDG_CONFIG_HOME="$CONFIG_HOME" \
LEANCLI_SOCKET="$OVERRIDE_SOCK" \
LEANCLI_CHAIN_ID=1 \
PATH="$ROOT/.lake/build/bin:$PATH" \
"$ROOT/.lake/build/bin/leancli-daemon" >"$LOG" 2>&1 &
daemon_pid="$!"

for _ in {1..50}; do
  [[ -S "$OVERRIDE_SOCK" ]] && break
  sleep 0.1
done

if [[ ! -S "$OVERRIDE_SOCK" ]]; then
  printf 'daemon config check failed: env override socket was not created\n' >&2
  cat "$LOG" >&2 || true
  exit 1
fi

LEANCLI_SOCKET="$OVERRIDE_SOCK" "$ROOT/.lake/build/bin/leancli" daemon ping >"$OUT"
grep -q '"chainId":1' "$OUT"

LEANCLI_SOCKET="$OVERRIDE_SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null
wait "$daemon_pid" >/dev/null 2>&1 || true
unset daemon_pid

printf 'daemon config checks passed\n'
