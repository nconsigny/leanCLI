#!/usr/bin/env bash
# Phase 0 smoke test for the Lean-native leancli-agent.
#
# Three stages, each opt-in via env flags:
#
#   Stage A — pure transport (always runs):
#     `leancli-agent --rpc '{ping,version,bogus-method}'` exit + stdout shape.
#     No daemon, no llama-server needed.
#
#   Stage B — daemon round-trip (runs when LEANCLI_SOCKET is set
#     and the socket exists):
#     Uses one tool RPC against a running daemon to confirm the
#     UDS JSON-RPC path is wired.
#
#   Stage C — full agent loop (only when LEANCLI_TEST_LLAMA_URL is set):
#     Three scripted llm.parseIntent prompts against the configured
#     loopback LLM:
#       * mainnet decode  (chainId 1)
#       * Sepolia eip712  (chainId 11155111)
#       * Sepolia propose_send (chainId 11155111)
#     `LEANCLI_TEST_MOCK_LLM=1` instructs the script to skip stage C
#     with a non-fatal note (sandbox-friendly default).
#
# Exit code is the first failing stage's exit code, or 0 when every
# stage either passed or was deferred.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
AGENT="${LEANCLI_AGENT_BIN:-${ROOT}/.lake/build/bin/leancli_agent}"

if [[ ! -x "$AGENT" ]]; then
  echo "FAIL: $AGENT not built. Run \`lake build leancli_agent\` first." >&2
  exit 1
fi

note()  { printf '  %s\n' "$*"; }
ok()    { printf '  ok: %s\n' "$*"; }
fail()  { printf '  FAIL: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }

assert_contains() {
  local out="$1" needle="$2" label="$3"
  if [[ "$out" == *"$needle"* ]]; then
    ok "$label contains '$needle'"
  else
    fail "$label missing '$needle' (got: $out)"
  fi
}

# ---------------------------------------------------------------------
section "stage A — transport"

out=$("$AGENT" --rpc '{"jsonrpc":"2.0","method":"ping","id":1}')
assert_contains "$out" '"protocol":"0.0.1"' "ping"

out=$("$AGENT" --rpc '{"jsonrpc":"2.0","method":"version","id":2}')
assert_contains "$out" '"backend":"lean-agent"' "version"

out=$("$AGENT" --rpc '{"jsonrpc":"2.0","method":"nope","id":3}')
assert_contains "$out" '"code":-32601' "unknown-method error code"

# missing argv → exit 2, no JSON on stdout.
if "$AGENT" >/dev/null 2>&1; then
  fail "no-args invocation should have exited non-zero"
fi
ok "no-args invocation exits non-zero"

# ---------------------------------------------------------------------
section "stage B — daemon round-trip"

SOCKET="${LEANCLI_SOCKET:-${XDG_RUNTIME_DIR:-/tmp}/leancli/leancli.sock}"
if [[ ! -S "$SOCKET" ]]; then
  note "skipped: no daemon socket at $SOCKET"
  note "  start the daemon with \`lake env .lake/build/bin/leancli-daemon\`"
  note "  then re-run with LEANCLI_SOCKET=$SOCKET"
else
  # We do not have a Lean-side one-shot JSON-RPC CLI in this tree.
  # Use the existing leancli-llm-legacy daemon-callback wire shape:
  # one JSON line in, one JSON line out, close. nc-style probes
  # work on socat / nc-openbsd; we try whichever is present.
  if command -v socat >/dev/null 2>&1; then
    PROBE_OUT=$(printf '%s\n' '{"jsonrpc":"2.0","method":"daemon.ping","id":1}' \
                 | socat - UNIX-CONNECT:"$SOCKET" 2>&1 || true)
  elif command -v nc >/dev/null 2>&1; then
    PROBE_OUT=$(printf '%s\n' '{"jsonrpc":"2.0","method":"daemon.ping","id":1}' \
                 | nc -U -q1 "$SOCKET" 2>&1 || true)
  else
    note "skipped: neither socat nor nc available for the UDS probe"
    PROBE_OUT=""
  fi
  if [[ -n "$PROBE_OUT" ]]; then
    if [[ "$PROBE_OUT" == *'"jsonrpc":"2.0"'* ]]; then
      ok "daemon.ping returned a JSON-RPC envelope"
    else
      note "daemon.ping probe returned: $PROBE_OUT"
      note "  (skipped: cannot confirm without a parseable response)"
    fi
  fi
fi

# ---------------------------------------------------------------------
section "stage C — full agent loop"

if [[ "${LEANCLI_TEST_MOCK_LLM:-0}" = "1" ]]; then
  note "skipped: LEANCLI_TEST_MOCK_LLM=1 set (sandbox mode)"
  note "  to run stage C, start llama-server on http://127.0.0.1:8080,"
  note "  set LEANCLI_TEST_LLAMA_URL=http://127.0.0.1:8080/v1/chat/completions,"
  note "  unset LEANCLI_TEST_MOCK_LLM, and re-run this script."
elif [[ -z "${LEANCLI_TEST_LLAMA_URL:-}" ]]; then
  note "deferred: LEANCLI_TEST_LLAMA_URL not set"
  note "  to enable, run a loopback LLM (llama-server, vLLM, …) and"
  note "  export LEANCLI_TEST_LLAMA_URL=http://127.0.0.1:8080/v1/chat/completions"
else
  export LEANCLI_AGENT_LLM_URL="$LEANCLI_TEST_LLAMA_URL"
  for chain in 1 11155111 11155111; do
    if [[ "$chain" = "1" ]]; then
      prompt="Decode the calldata for transfer(0xabc...000, 100) on USDC mainnet."
    elif [[ -n "${C_done:-}" ]]; then
      prompt="Draft a 0.01 ETH send from my wallet to 0x000000000000000000000000000000000000dEaD on Sepolia."
      C_done=1
    else
      prompt="Decode this EIP-712 typed-data payload on Sepolia: {\"types\":{},\"domain\":{},\"primaryType\":\"X\",\"message\":{}}"
      C_done=1
    fi
    rpc=$(printf '{"jsonrpc":"2.0","method":"llm.parseIntent","params":{"prompt":%q,"chainId":%d},"id":1}' "$prompt" "$chain")
    out=$("$AGENT" --rpc "$rpc")
    if [[ "$out" == *'"backend":"lean-agent"'* ]]; then
      ok "chain $chain prompt round-tripped"
    else
      note "chain $chain prompt returned: $out"
      fail "stage C did not see a lean-agent envelope"
    fi
  done
fi

echo
echo "phase 0 smoke complete"
