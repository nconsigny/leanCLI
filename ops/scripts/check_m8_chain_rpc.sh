#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOCK="/tmp/leancli-m8-check-$$.sock"
DATA="$(mktemp -d /tmp/leancli-m8-check.XXXXXX)"
DAEMON_LOG="$(mktemp /tmp/leancli-m8-daemon-log.XXXXXX)"
ANVIL_LOG="$(mktemp /tmp/leancli-m8-anvil-log.XXXXXX)"
PORT="${LEANCLI_TEST_ANVIL_PORT:-8546}"
ANVIL_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ANVIL_RECIPIENT="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
ANVIL_MNEMONIC="test test test test test test test test test test test junk"

cleanup() {
  set +e
  LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null 2>&1
  if [[ -n "${daemon_pid:-}" ]]; then
    wait "$daemon_pid" >/dev/null 2>&1
  fi
  if [[ -n "${anvil_pid:-}" ]]; then
    kill "$anvil_pid" >/dev/null 2>&1
    wait "$anvil_pid" >/dev/null 2>&1
  fi
  rm -rf "$DATA" "$DAEMON_LOG" "$ANVIL_LOG" "$SOCK" /tmp/leancli-m8-check-out
}
trap cleanup EXIT

if ! command -v anvil >/dev/null 2>&1; then
  printf 'M8 chain RPC check skipped: anvil not found\n'
  exit 0
fi

cd "$ROOT"
lake build >/dev/null

anvil --host 127.0.0.1 --port "$PORT" >"$ANVIL_LOG" 2>&1 &
anvil_pid="$!"

for _ in {1..50}; do
  if curl -sS -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
      "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

LEANCLI_SOCKET="$SOCK" \
XDG_DATA_HOME="$DATA" \
LEANCLI_RPC_URL="http://127.0.0.1:$PORT" \
LEANCLI_CHAIN_ID=31337 \
PATH="$ROOT/.lake/build/bin:$PATH" \
"$ROOT/.lake/build/bin/leancli-daemon" >"$DAEMON_LOG" 2>&1 &
daemon_pid="$!"

for _ in {1..50}; do
  [[ -S "$SOCK" ]] && break
  sleep 0.1
done

if [[ ! -S "$SOCK" ]]; then
  printf 'M8 check failed: daemon socket was not created\n' >&2
  cat "$DAEMON_LOG" >&2 || true
  exit 1
fi

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" balance "$ANVIL_ACCOUNT" >/tmp/leancli-m8-check-out
grep -q '"balance":"0x' /tmp/leancli-m8-check-out

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" chain nonce "$ANVIL_ACCOUNT" >/tmp/leancli-m8-check-out
grep -q '"nonce":"0x' /tmp/leancli-m8-check-out

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" \
  chain token-balance 0x0000000000000000000000000000000000000000 "$ANVIL_ACCOUNT" >/tmp/leancli-m8-check-out
grep -q '"balance":"0x' /tmp/leancli-m8-check-out

# `chain gas-price` / `chain priority-fee` pretty-print the fee as
# "<gwei>  (<wei> wei, 0x<hex>)" rather than raw JSON, so assert on that hex tail.
LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" chain gas-price >/tmp/leancli-m8-check-out
grep -q 'wei, 0x' /tmp/leancli-m8-check-out

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" chain priority-fee >/tmp/leancli-m8-check-out
grep -q 'wei, 0x' /tmp/leancli-m8-check-out

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" \
  chain estimate-gas '{"from":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":"0x1"}' \
  >/tmp/leancli-m8-check-out
grep -q '"gas":"0x' /tmp/leancli-m8-check-out

set +e
LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" chain broadcast 0x01 >/tmp/leancli-m8-check-out 2>&1
broadcast_code="$?"
set -e
if [[ "$broadcast_code" != 2 ]]; then
  printf 'M8 check failed: invalid broadcast should preserve daemon/node failure as exit 2\n' >&2
  cat /tmp/leancli-m8-check-out >&2
  exit 1
fi
grep -q 'chain RPC failed' /tmp/leancli-m8-check-out

# EOA operations moved under the `wallet` namespace; sending from a specific
# wallet uses `from <wallet> send <to> <amount>`.
LEANCLI_SOCKET="$SOCK" XDG_DATA_HOME="$DATA" LEANCLI_PASSPHRASE='m8-pass' \
  "$ROOT/.lake/build/bin/leancli" wallet import anvil "$ANVIL_MNEMONIC" >/tmp/leancli-m8-check-out
grep -q "$ANVIL_ACCOUNT" /tmp/leancli-m8-check-out

LEANCLI_SOCKET="$SOCK" XDG_DATA_HOME="$DATA" LEANCLI_PASSPHRASE='m8-pass' \
  "$ROOT/.lake/build/bin/leancli" wallet unlock anvil >/tmp/leancli-m8-check-out
grep -q '"locked":false' /tmp/leancli-m8-check-out

LEANCLI_SOCKET="$SOCK" XDG_DATA_HOME="$DATA" \
  "$ROOT/.lake/build/bin/leancli" from anvil send "$ANVIL_RECIPIENT" 1 </dev/null >/tmp/leancli-m8-check-out
# `send` pretty-prints the result ("hash:    0x<64 hex>") rather than raw JSON.
grep -qE '0x[0-9a-fA-F]{64}' /tmp/leancli-m8-check-out

# `max` is resolved daemon-side to balance minus a capped 21k-gas reserve,
# then passed as a concrete wei amount through the normal signing path.
LEANCLI_SOCKET="$SOCK" XDG_DATA_HOME="$DATA" \
  "$ROOT/.lake/build/bin/leancli" from anvil send "$ANVIL_RECIPIENT" max </dev/null >/tmp/leancli-m8-check-out
grep -q 'Resolved max send:' /tmp/leancli-m8-check-out
grep -qE '0x[0-9a-fA-F]{64}' /tmp/leancli-m8-check-out

LEANCLI_SOCKET="$SOCK" "$ROOT/.lake/build/bin/leancli" daemon stop >/dev/null
wait "$daemon_pid" >/dev/null 2>&1 || true
unset daemon_pid

grep -q '"method":"chain.balance"' "$DAEMON_LOG"
grep -q '"method":"chain.nonce"' "$DAEMON_LOG"
grep -q '"method":"chain.tokenBalance"' "$DAEMON_LOG"
grep -q '"method":"chain.gasPrice"' "$DAEMON_LOG"
grep -q '"method":"chain.maxPriorityFeePerGas"' "$DAEMON_LOG"
grep -q '"method":"chain.estimateGas"' "$DAEMON_LOG"
grep -q '"method":"chain.sendRawTransaction"' "$DAEMON_LOG"
grep -q '"method":"eoa.send"' "$DAEMON_LOG"
grep -q '"method":"eoa.maxSendable"' "$DAEMON_LOG"
grep -q 'eth_getBalance' "$ANVIL_LOG"
grep -q 'eth_getTransactionCount' "$ANVIL_LOG"
grep -q 'eth_call' "$ANVIL_LOG"
grep -q 'eth_gasPrice' "$ANVIL_LOG"
grep -q 'eth_maxPriorityFeePerGas' "$ANVIL_LOG"
grep -q 'eth_estimateGas' "$ANVIL_LOG"
grep -q 'eth_sendRawTransaction' "$ANVIL_LOG"

printf 'M8 chain RPC checks passed\n'
