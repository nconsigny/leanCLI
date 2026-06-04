#!/usr/bin/env bash
# Phase 1a smoke test for leancli-agentd (persistent agent daemon).
#
# Stages, each opt-in via env flags:
#
#   A — session-store unit test (always runs, no daemon needed).
#       Runs .lake/build/bin/agent_session_test which exercises the
#       SQLite shim end-to-end (bootstrap, append + load, FTS5,
#       second-handle concurrent read).
#
#   B — leancli-agentd ping (always runs). Spawns the daemon with
#       throwaway XDG paths, talks to it over UDS via a small python
#       client, kills it.
#
#   C — opcode smoke (always runs). create_session, search (empty),
#       close_session round-trips. Verifies the daemon's serialised
#       request dispatch over the UDS frame.
#
#   D — restart survival. Stop the daemon, restart with the same
#       LEANCLI_AGENT_DB, confirm `search` still returns the row count
#       it had before restart. Uses opcodes only — no LLM required.
#
#   E — full run_turn end-to-end (DEFERRED unless LEANCLI_TEST_LLAMA_URL).
#       In Phase 0 the leancli-agent loop segfaults on libcurl when
#       no LLM is reachable on the configured loopback URL — this is
#       a Phase-0-inherited issue tracked separately. Until a real
#       LLM is available, stage E is opt-in via LEANCLI_TEST_LLAMA_URL.
#
#   F — LlmAgent.Bridge mode auto-detection in one-shot mode.
#       Smoke-checks that the Phase 0 binary still responds to ping;
#       full persistent vs. one-shot routing is exercised by the
#       wallet daemon's chat.draft handler under a real chat
#       session, deferred to integration tests.
#
#   G — TUI end-to-end (always deferred in the sandbox).
#
# Exit code is the first failing stage's exit code, or 0 when every
# stage either passed or was deferred.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
AGENTD="${LEANCLI_AGENTD_BIN:-${ROOT}/.lake/build/bin/leancli_agentd}"
AGENT="${LEANCLI_AGENT_BIN:-${ROOT}/.lake/build/bin/leancli_agent}"
SESSION_TEST="${ROOT}/.lake/build/bin/agent_session_test"

if [[ ! -x "$AGENTD" ]]; then
  echo "FAIL: $AGENTD not built. Run \`lake build leancli_agentd\`." >&2
  exit 1
fi

note()    { printf '  %s\n' "$*"; }
ok()      { printf '  ok: %s\n' "$*"; }
fail()    { printf '  FAIL: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }
defer()   { printf '  DEFERRED: %s\n' "$*"; }

assert_contains() {
  local out="$1" needle="$2" label="$3"
  if [[ "$out" == *"$needle"* ]]; then
    ok "$label contains '$needle'"
  else
    fail "$label missing '$needle' (got: $out)"
  fi
}

# Tiny python UDS client.
PYCLIENT="$(mktemp -t udsclient.XXXXXX.py)"
trap 'rm -f "$PYCLIENT"' EXIT
cat >"$PYCLIENT" <<'EOF'
import socket, sys
p, msg = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(p)
s.sendall((msg + "\n").encode())
s.shutdown(socket.SHUT_WR)
buf = b""
while True:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
print(buf.decode().rstrip())
EOF

# Shared throwaway dirs. Deleted on exit.
TMP="$(mktemp -d)"
cleanup_all() { rm -rf "$TMP"; rm -f "$PYCLIENT"; }
trap cleanup_all EXIT
mkdir -p "$TMP/run/leancli" "$TMP/state/leancli"
export LEANCLI_AGENT_SOCKET="$TMP/run/leancli/agent.sock"
export LEANCLI_AGENT_DB="$TMP/state/leancli/sessions.db"

start_agentd() {
  "$AGENTD" >"$TMP/agentd.log" 2>&1 &
  AGENTD_PID=$!
  sleep 0.3
  local waited=0
  while [[ ! -S "$LEANCLI_AGENT_SOCKET" && $waited -lt 30 ]]; do
    sleep 0.1; waited=$((waited + 1))
  done
  if [[ ! -S "$LEANCLI_AGENT_SOCKET" ]]; then
    cat "$TMP/agentd.log" >&2
    fail "leancli-agentd did not bind socket within ~3s"
  fi
}

stop_agentd() {
  if [[ -n "${AGENTD_PID:-}" ]]; then
    kill "$AGENTD_PID" 2>/dev/null || true
    wait "$AGENTD_PID" 2>/dev/null || true
    AGENTD_PID=
  fi
}

# ---------------------------------------------------------------------------
section "A: agent_session_test"

if [[ -x "$SESSION_TEST" ]]; then
  if "$SESSION_TEST"; then
    ok "agent_session_test passed"
  else
    fail "agent_session_test failed"
  fi
else
  defer "agent_session_test not built (run \`lake build agent_session_test\`)"
fi

# ---------------------------------------------------------------------------
section "B: leancli-agentd ping"

start_agentd
PING_OUT="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"ping"}')"
note "ping reply: $PING_OUT"
assert_contains "$PING_OUT" '"ok":true'      "ping reply"
assert_contains "$PING_OUT" '"protocol"'     "ping reply"

# ---------------------------------------------------------------------------
section "C: opcode smoke"

CS="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"create_session","metadata":{"chainId":11155111}}')"
note "create_session: $CS"
assert_contains "$CS" '"ok":true'    "create_session"
assert_contains "$CS" '"session_id"' "create_session"
SID="$(printf '%s' "$CS" | python3 -c 'import sys,json
o=json.loads(sys.stdin.read())
print(o["result"]["session_id"])')"
note "sid=$SID"

# Empty search returns ok with zero hits.
S_EMPTY="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"search","query":"USDC","limit":3}')"
note "search empty: $S_EMPTY"
assert_contains "$S_EMPTY" '"ok":true' "search"

# Unknown op returns structured error.
UNK="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"nope"}')"
note "unknown op: $UNK"
assert_contains "$UNK" '"ok":false'         "unknown op"
assert_contains "$UNK" '"kind":"bad_request"' "unknown op kind"

CLOSE="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" \
  "$(python3 -c 'import sys,json; print(json.dumps({"op":"close_session","session_id":int(sys.argv[1])}))' "$SID")")"
note "close_session: $CLOSE"
assert_contains "$CLOSE" '"ok":true' "close_session"

# Create a second session so stage D can verify two rows survive
# restart. No need to populate messages — the row in `sessions` is
# enough to confirm persistence.
CS2="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"create_session","metadata":{"chainId":1}}')"
note "create_session #2: $CS2"
assert_contains "$CS2" '"session_id":2' "create_session 2"

# ---------------------------------------------------------------------------
section "D: restart survival"

stop_agentd
start_agentd

# After restart, a fresh create_session must return 3 (autoincrement
# continued from before — proves the sessions table survived).
CS3="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"create_session","metadata":{}}')"
note "create_session after restart: $CS3"
assert_contains "$CS3" '"session_id":3' "create_session 3 (rowid continued)"

# Search after restart still works.
S_RESTART="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"search","query":"USDC","limit":3}')"
note "search after restart: $S_RESTART"
assert_contains "$S_RESTART" '"ok":true' "search after restart"

stop_agentd

# ---------------------------------------------------------------------------
section "E: run_turn end-to-end"

if [[ -z "${LEANCLI_TEST_LLAMA_URL:-}" ]]; then
  defer "run_turn requires a live llama-server. Set LEANCLI_TEST_LLAMA_URL"
  defer "  e.g. LEANCLI_TEST_LLAMA_URL=http://127.0.0.1:8080/v1 to exercise."
  defer "  Note: Phase-0 leancli-agent currently segfaults inside libcurl"
  defer "  when the LLM endpoint is unreachable; this is being tracked"
  defer "  separately and is out of Phase 1a scope."
else
  export LEANCLI_AGENT_LLM_URL="$LEANCLI_TEST_LLAMA_URL/chat/completions"
  start_agentd
  CSE="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"create_session","metadata":{"chainId":11155111}}')"
  SIDE="$(printf '%s' "$CSE" | python3 -c 'import sys,json
o=json.loads(sys.stdin.read()); print(o["result"]["session_id"])')"
  for i in 1 2 3; do
    PROMPT="phase1a-smoke turn $i: send 0.01 USDC to vitalik.eth"
    REQ="$(python3 -c '
import json, sys
print(json.dumps({"op":"run_turn","session_id":int(sys.argv[1]),"prompt":sys.argv[2]}))
' "$SIDE" "$PROMPT")"
    RT="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" "$REQ")"
    note "run_turn $i: $(printf '%s' "$RT" | head -c 200)"
    assert_contains "$RT" '"ok"' "run_turn $i shape"
  done
  S_RT="$(python3 "$PYCLIENT" "$LEANCLI_AGENT_SOCKET" '{"op":"search","query":"USDC","limit":10}')"
  HITS="$(printf '%s' "$S_RT" | python3 -c '
import sys, json
o=json.loads(sys.stdin.read()); print(len(o["result"]["hits"]))')"
  if (( HITS >= 1 )); then
    ok "history search returned $HITS hits"
  else
    fail "expected ≥1 hit after 3 run_turns; got $HITS"
  fi
  stop_agentd
fi

# ---------------------------------------------------------------------------
section "F: LlmAgent.Bridge mode auto-detection"

if [[ -x "$AGENT" ]]; then
  # Persistent socket is gone (stopped above); the one-shot binary
  # should answer ping in isolation. Full bridge auto-detect runs
  # inside `leancli-daemon` and is best exercised through
  # tests/integration tests against the wallet daemon's chat.draft.
  PING_OS="$("$AGENT" --rpc '{"jsonrpc":"2.0","method":"ping","id":1}')"
  note "leancli-agent ping: $PING_OS"
  assert_contains "$PING_OS" '"ok":true' "leancli-agent ping"
else
  defer "leancli-agent (one-shot) not built; skipping mode autodetect cross-check"
fi

# ---------------------------------------------------------------------------
section "G: TUI end-to-end"
defer "TUI smoke (leancli tui) requires an interactive terminal and an"
defer "  llama-server backend; not runnable in the sandbox. Exercise"
defer "  manually with LEANCLI_AGENT_LLM_URL=http://127.0.0.1:8080/v1"
defer "  and LEANCLI_AGENT_MODE=persistent."

printf '\n== Phase 1a smoke: PASS ==\n'
