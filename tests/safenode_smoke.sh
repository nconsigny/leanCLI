#!/usr/bin/env bash
# tests/safenode_smoke.sh
#
# End-to-end smoke test for the safenode + helios verified+private read
# pipeline. Runs four steps:
#
#   1. curl the upstream safe-node /json_rpc endpoint with the user API key
#      from $LEANCLI_SAFE_NODE_API_KEY (or the literal new key inlined below
#      if the env var isn't set). Exercises the raw transport: TDX-attested
#      TLS pin + nginx auth + Sepolia eth_chainId.
#   2. Stop any running daemon and respawn it with the new key in env, so
#      the safenode sidecar inherits it at spawn time.
#   3. Wait for TDX verify + helios consensus sync to settle.
#   4. Send a tx.simulate on chainId 11155111 (Sepolia) with backend=helios
#      against the daemon socket. Under the hood, helios's REVM will fetch
#      eth_getProof through the local safenode HTTP proxy, which forwards
#      to the TDX-attested ORAM upstream over the pinned channel.
#
# Run from the leanCLI repo root:
#   bash tests/safenode_smoke.sh
#
# Env you can override:
#   LEANCLI_SAFE_NODE_API_KEY  override the inlined user key
#   ATTESTED_TLS_PIN          override the inlined pin (sha256//<base64>)
#   DAEMON_SOCKET             override the daemon UDS path
#
# Exit 0 on a clean simulate (any non-revert + non-auth-error result);
# exit 1 with the diagnostic from whichever step failed.

set -u

PIN="${ATTESTED_TLS_PIN:-sha256//3VHy52Tn0kQ7io763wwEiKewgH8f4LjA+HHT0bmzOxg=}"
KEY="${LEANCLI_SAFE_NODE_API_KEY:-olabs-api-bf83325bdef58f70006bf6ee1245cb4bbd475b4d0083b257144cb6889240d35b}"
URL="https://rpc.safe-node.com/$KEY/json_rpc"
SOCK="${DAEMON_SOCKET:-/run/user/$(id -u)/leancli/leancli.sock}"

# ---------------------------------------------------------------------------
# Step 1: raw upstream probe
# ---------------------------------------------------------------------------
echo "=== [1/4] eth_getProof via new user key (Sepolia) ==="
# safe-node's /json_rpc only implements eth_getProof — eth_chainId etc. all
# return -32601. So we probe the one method that's actually authoritative.
ADMIN="${SAFENODE_ADMIN_KEY:-olabs-admin-339d287c44315dbc77cdff781c1a43fb8a7b242996f2c5b883bda1bfcfae83a3}"
ADMIN_URL="https://rpc.safe-node.com/$ADMIN/admin"
SYNC="$(curl --pinnedpubkey "$PIN" -sS -X POST "$ADMIN_URL" \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"admin_get_sync_status","params":[]}')"
ROOT="$(echo "$SYNC" | jq -r '.result.latest_root_number // empty')"
if [ -z "$ROOT" ]; then
  echo "✗ admin call did not return latest_root_number; key is dead"
  exit 1
fi
BLOCK_HEX="$(printf '0x%x' "$ROOT")"
BODY="$(jq -nc --arg b "$BLOCK_HEX" '{jsonrpc:"2.0",id:1,method:"eth_getProof",params:["0x0000000000000000000000000000000000000000",[],$b]}')"
PROOF_OK=0
for i in 1 2 3 4 5; do
  RAW="$(curl --pinnedpubkey "$PIN" -sS -X POST "https://rpc.safe-node.com/$KEY/json_rpc" \
    -H 'content-type: application/json' --data "$BODY")"
  if echo "$RAW" | jq -e '.result.accountProof | length > 0' >/dev/null 2>&1; then
    echo "✓ eth_getProof landed on attempt $i at block $BLOCK_HEX"
    PROOF_OK=1
    break
  fi
  CODE="$(echo "$RAW" | jq -r '.error.code // "?"')"
  echo "attempt $i: code=$CODE"
  [ "$CODE" = "-32001" ] || { echo "non-retriable error; aborting"; echo "$RAW"; exit 1; }
  sleep 2
done
if [ "$PROOF_OK" -ne 1 ]; then
  echo "✗ eth_getProof never materialized; key may be dead or server backfilling slowly"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: restart the daemon with the new key in env
# ---------------------------------------------------------------------------
echo
echo "=== [2/4] restart daemon with new safenode env ==="
export LEANCLI_SAFE_NODE_URL="${LEANCLI_SAFE_NODE_URL:-https://rpc.safe-node.com}"
export LEANCLI_SAFE_NODE_API_KEY="$KEY"
export LEANCLI_SAFE_NODE_DOMAIN="${LEANCLI_SAFE_NODE_DOMAIN:-rpc.safe-node.com}"
: "${TDX_QUOTE_VERIFIER_BIN:?must point at the upstream Rust tdx_quote_verifier binary}"
export TDX_QUOTE_VERIFIER_BIN

# Defensive restart: send the RPC stop, then wait up to 5s for the socket
# to actually disappear. If it doesn't, an old daemon is wedged — pkill it
# and remove the sockets so the new spawn binds cleanly. Without this, a
# stale daemon silently keeps serving and the new one exits non-fatally,
# which is exactly the failure mode that bit us before.
./.lake/build/bin/leancli daemon stop 2>/dev/null || true
for _ in 1 2 3 4 5; do [ -S "$SOCK" ] || break; sleep 1; done
if [ -S "$SOCK" ]; then
  echo "daemon did not stop via RPC; killing"
  pkill -f leancli-daemon || true
  pkill -f 'bridge/(helios|colibri|safenode)/bridge.mjs' || true
  sleep 1
  rm -f /run/user/"$(id -u)"/leancli/*.sock
fi
nohup ./.lake/build/bin/leancli-daemon > /tmp/leancli-daemon.out 2>&1 &
echo "spawned leancli-daemon pid=$! (logs: /tmp/leancli-daemon.out)"

# ---------------------------------------------------------------------------
# Step 3: wait for boot + TDX verify + helios consensus sync
# ---------------------------------------------------------------------------
echo
echo "=== [3/4] wait for safenode + helios ==="
for i in $(seq 1 30); do
  if [ -S "$SOCK" ] && grep -q '\[safenode\] attested TLS pin' /tmp/leancli-daemon.out 2>/dev/null; then
    echo "safenode attested (after ${i}s)"
    break
  fi
  sleep 1
done
grep -E '\[safenode\]|safenode attested|helios enabled' /tmp/leancli-daemon.out || true

# Give helios a moment to start its consensus sync; first simulate will
# block on it otherwise. 8s is empirically enough for Sepolia.
sleep 8

# ---------------------------------------------------------------------------
# Step 4: tx.simulate on Sepolia through helios + safenode
# ---------------------------------------------------------------------------
echo
echo "=== [4/4] tx.simulate chainId=11155111, backend=helios ==="
python3 - "$SOCK" <<'PY'
import socket, json, sys
sock_path = sys.argv[1]
req = {
    "jsonrpc": "2.0", "id": 1, "method": "tx.simulate",
    "params": {
        "chainId": 11155111,
        "backend": "helios",
        "to": "0x0000000000000000000000000000000000000000",
        "data": "0x",
    },
}
s = socket.socket(socket.AF_UNIX)
s.connect(sock_path)
s.sendall((json.dumps(req) + "\n").encode())
buf = b""
while b"\n" not in buf:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
print(buf.decode())
PY
