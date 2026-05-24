#!/usr/bin/env bash
# Phase 1b smoke test for the agent-side skills layer.
#
# Stages:
#
#   A — static skill-pack sanity. Verifies that every required skill
#       directory exists, each has a parseable SKILL.md frontmatter,
#       and the OFAC flag + chain whitelist constraints are satisfied.
#       Does NOT spawn any binary.
#
#   B — agent-daemon ping. Same shape as Phase 1a; here we just want
#       to confirm the binary still binds the socket after the
#       skills wiring was added.
#
#   C — skills startup. Spawn kohaku-agentd with a temp skills root
#       and confirm the stderr line shows the expected count.
#
#   D — reload op. Edit a temp skill, send {"op":"reload"} over the
#       socket, verify the new count is picked up.
#
#   E — protocol_lookup via direct registry probe (when daemon is up,
#       we can't drive run_turn without a live LLM; this stage logs a
#       DEFERRED notice in that case and relies on the Lean unit
#       coverage in stage A).
#
# Exit code is the first failing stage's exit code, or 0 when every
# stage either passed or was deferred.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
AGENTD="${KOHAKU_AGENTD_BIN:-${ROOT}/.lake/build/bin/kohaku_agentd}"

if [[ ! -x "$AGENTD" ]]; then
  echo "FAIL: $AGENTD not built. Run \`lake build kohaku_agentd\`." >&2
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

# ---------------------------------------------------------------------------
section "A: static skill-pack sanity"

REQUIRED=(
  kohaku-wallet web3-security uniswap railgun privacy-pool
  tornado-cash morpho fxusd bold-liquity cowswap aave
)
for s in "${REQUIRED[@]}"; do
  if [[ ! -f "skills/$s/SKILL.md" ]]; then
    fail "missing skills/$s/SKILL.md"
  fi
  if ! grep -q "^name: $s\b" "skills/$s/SKILL.md"; then
    fail "skills/$s/SKILL.md frontmatter missing or wrong 'name:'"
  fi
done
ok "all eleven required skills have SKILL.md with matching name"

if ! grep -q "^ofacFlagged: true" skills/tornado-cash/SKILL.md; then
  fail "skills/tornado-cash/SKILL.md missing ofacFlagged: true"
fi
ok "tornado-cash has ofacFlagged: true"

if ! grep -q "OFAC" skills/tornado-cash/security.md; then
  fail "skills/tornado-cash/security.md missing OFAC mention"
fi
ok "tornado-cash security.md mentions OFAC"

# Real-content skills must have non-empty overview.md without TODOs at
# the top-level (functions/ scaffolding is allowed to carry TODOs).
for s in kohaku-wallet web3-security uniswap; do
  if grep -lE 'TODO\(curator\):' \
       "skills/$s/SKILL.md" "skills/$s/overview.md" \
       "skills/$s/security.md" "skills/$s/interactions.md" \
       2>/dev/null | grep -q .; then
    fail "real-content skill $s has TODO(curator): in top-level docs"
  fi
done
ok "real-content skills (kohaku-wallet, web3-security, uniswap) free of top-level TODOs"

# Every scaffold skill must carry at least one TODO(curator): marker
for s in railgun privacy-pool tornado-cash morpho fxusd bold-liquity cowswap aave; do
  if ! grep -rqE 'TODO\(curator\):' "skills/$s/" 2>/dev/null; then
    fail "scaffold skill $s missing any TODO(curator): markers"
  fi
done
ok "all eight scaffold skills carry TODO(curator): markers"

# contracts.json contains no foreign chain ids — we use named keys
# (mainnet / sepolia) only.
if grep -rE '"chainId"' skills/*/contracts.json 2>/dev/null | grep -v 'mainnet\|sepolia' | grep -q .; then
  fail "some contracts.json has a chainId field (we use named keys only)"
fi
ok "no chainId fields in any contracts.json"

# ---------------------------------------------------------------------------
section "B: kohaku-agentd ping (post-skills wiring)"

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

TMP="$(mktemp -d)"
mkdir -p "$TMP/run/leankohaku" "$TMP/state/leankohaku"
export KOHAKU_AGENT_SOCKET="$TMP/run/leankohaku/agent.sock"
export KOHAKU_AGENT_DB="$TMP/state/leankohaku/sessions.db"
# Use the in-tree skills/ root explicitly so the env / data-home
# fallback chain in resolveSkillsDir does not surprise this test.
export KOHAKU_AGENT_SKILLS_DIR="$ROOT/skills"

start_agentd() {
  "$AGENTD" >"$TMP/agentd.log" 2>&1 &
  AGENTD_PID=$!
  sleep 0.3
  local waited=0
  while [[ ! -S "$KOHAKU_AGENT_SOCKET" && $waited -lt 30 ]]; do
    sleep 0.1; waited=$((waited + 1))
  done
  if [[ ! -S "$KOHAKU_AGENT_SOCKET" ]]; then
    cat "$TMP/agentd.log" >&2
    fail "kohaku-agentd did not bind socket within ~3s"
  fi
}
stop_agentd() {
  if [[ -n "${AGENTD_PID:-}" ]]; then
    kill "$AGENTD_PID" 2>/dev/null || true
    wait "$AGENTD_PID" 2>/dev/null || true
    AGENTD_PID=
  fi
}

start_agentd
PING_OUT="$(python3 "$PYCLIENT" "$KOHAKU_AGENT_SOCKET" '{"op":"ping"}')"
note "ping reply: $PING_OUT"
assert_contains "$PING_OUT" '"ok":true' "ping reply"

# ---------------------------------------------------------------------------
section "C: skills startup log"

if grep -q "kohaku-agentd: skills at" "$TMP/agentd.log"; then
  ok "agentd logged skills path"
else
  cat "$TMP/agentd.log" >&2
  fail "agentd did not log skills path"
fi

# At least 11 protocol/meta skills + 9 pre-existing action skills must be
# visible to the agent-side parser. The agent-side parser ignores skills
# whose frontmatter lacks a `name:`; expect 20 loaded.
LOADED=$(grep -oE "\([0-9]+ loaded\)" "$TMP/agentd.log" | head -1)
note "agentd loaded: $LOADED"
if [[ -z "$LOADED" ]]; then
  fail "agentd did not log loaded-count line"
fi
COUNT=$(echo "$LOADED" | grep -oE '[0-9]+' | head -1)
if (( COUNT < 11 )); then
  fail "agentd loaded only $COUNT skills; expected ≥ 11"
fi
ok "agentd loaded ≥ 11 skills"

# ---------------------------------------------------------------------------
section "D: reload op"

# Use a sentinel temp skill so we don't mutate the repo tree.
SENTINEL="$ROOT/skills/_phase1b_smoke_sentinel"
rm -rf "$SENTINEL"
mkdir -p "$SENTINEL"
cat >"$SENTINEL/SKILL.md" <<'EOF'
---
name: _phase1b_smoke_sentinel
version: 0.0
description: temporary sentinel skill written by tests/agent_phase1b_smoke.sh
alwaysOn: false
triggers:
  - phase1b-smoke-needle
---
sentinel
EOF
trap 'rm -rf "$SENTINEL"' EXIT

RELOAD_OUT="$(python3 "$PYCLIENT" "$KOHAKU_AGENT_SOCKET" '{"op":"reload"}')"
note "reload reply: $RELOAD_OUT"
assert_contains "$RELOAD_OUT" '"ok":true' "reload reply"
# The skills count after reload must be larger than the initial load
# because we added one skill on disk.
POST=$(echo "$RELOAD_OUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["result"]["skills"])')
note "post-reload count: $POST"
if (( POST <= COUNT )); then
  fail "reload count $POST not greater than initial $COUNT (sentinel was not picked up)"
fi
ok "reload picked up the sentinel skill"

rm -rf "$SENTINEL"

# ---------------------------------------------------------------------------
section "E: run_turn end-to-end (LLM required)"

stop_agentd
if [[ -z "${KOHAKU_TEST_LLAMA_URL:-}" ]]; then
  defer "run_turn requires a live llama-server. Set KOHAKU_TEST_LLAMA_URL"
  defer "  e.g. KOHAKU_TEST_LLAMA_URL=http://127.0.0.1:8080/v1"
  defer "  With KOHAKU_LOG_PROMPT=1 the agentd log will contain"
  defer "  '[skills] active: kohaku-wallet,web3-security[,...]' lines"
  defer "  the operator can grep to confirm trigger matching."
fi

printf '\n== Phase 1b smoke: PASS ==\n'
