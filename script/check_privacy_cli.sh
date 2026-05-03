#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.lake/build/bin/leankohaku"
SOCK="/tmp/leankohaku-privacy-check-$$.sock"

cleanup() {
  rm -f "$SOCK"
}
trap cleanup EXIT

cd "$ROOT"
lake build >/dev/null

check() {
  local expected="$1"
  shift
  local out
  out="$("$BIN" "$@")"
  case "$out" in
    "$expected"*) ;;
    *)
      printf 'expected prefix: %s\n' "$expected" >&2
      printf 'actual: %s\n' "$out" >&2
      exit 1
      ;;
  esac
}

check_exit() {
  local expected_code="$1"
  local expected_prefix="$2"
  shift 2
  local out code
  set +e
  out="$("$BIN" "$@" 2>&1)"
  code="$?"
  set -e
  if [[ "$code" != "$expected_code" ]]; then
    printf 'expected exit code: %s\n' "$expected_code" >&2
    printf 'actual exit code: %s\n' "$code" >&2
    printf 'output: %s\n' "$out" >&2
    exit 1
  fi
  case "$out" in
    "$expected_prefix"*) ;;
    *)
      printf 'expected prefix: %s\n' "$expected_prefix" >&2
      printf 'actual: %s\n' "$out" >&2
      exit 1
      ;;
  esac
}

check "DENY policy=strict peer=configured-node purpose=broadcast-tx transport=direct" \
  policy-check strict configured-node broadcast-tx direct

check "ALLOW policy=tor peer=configured-node purpose=node-read transport=tor" \
  policy-check tor configured-node node-read tor

check "DENY policy=strict backend=configured method=eth_getBalance" \
  rpc-check strict configured direct eth_getBalance

check "ALLOW policy=tor backend=configured method=eth_sendRawTransaction" \
  rpc-check tor configured tor eth_sendRawTransaction

check "DENY policy=strict peer=third-party-api purpose=analytics transport=tor" \
  policy-check strict third-party-api analytics tor

check "ALLOW mode=strict endpoint-kind=local scheme=http transport=loopback credentialed=false" \
  endpoint-check strict local http loopback false

check "ALLOW mode=tor endpoint-kind=configured scheme=onion transport=tor credentialed=false" \
  endpoint-check tor configured onion tor false

check "DENY mode=tor endpoint-kind=configured scheme=onion transport=tor credentialed=true" \
  endpoint-check tor configured onion tor true

check "DENY mode=tor endpoint-kind=third-party scheme=http transport=tor credentialed=false" \
  endpoint-check tor third-party http tor false

LEANKOHAKU_SOCKET="$SOCK" LEANKOHAKU_NO_AUTOSPAWN=1 \
check_exit 2 "daemon error -32000:" \
  balance 0x0000000000000000000000000000000000000000

check_exit 2 "invalid balance address: bad" \
  balance bad

check_exit 2 "send requires a named unlocked wallet" \
  send 0x0000000000000000000000000000000000000000 1

check_exit 2 "invalid send arguments: to=0x0000000000000000000000000000000000000000 amountWei=0" \
  send 0x0000000000000000000000000000000000000000 0

printf 'privacy CLI checks passed\n'
