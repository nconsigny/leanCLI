#!/usr/bin/env bash
# tests/safenode_proof.sh
#
# End-to-end eth_getProof smoke test against rpc.safe-node.com.
#
# The server returns -32001 "Failed due to data non availability" on a cache
# miss and queues a backfill; per upstream docs the recommended pattern is to
# retry until the proof is materialized. This script does that retry loop.
#
# Tries two block heights in parallel:
#   - latest accepted root (from admin_get_sync_status.latest_root_number)
#   - the historical snapshot ceiling (historical_root_number, typically 1M)
# Historical blocks are more likely to be warm because the startup prefetch
# lane covers them; live blocks need on-demand backfill.

set -u

PIN="${ATTESTED_TLS_PIN:-sha256//3VHy52Tn0kQ7io763wwEiKewgH8f4LjA+HHT0bmzOxg=}"
KEY="${LEANCLI_SAFE_NODE_API_KEY:-olabs-api-bf83325bdef58f70006bf6ee1245cb4bbd475b4d0083b257144cb6889240d35b}"
ADMIN="${SAFENODE_ADMIN_KEY:-olabs-admin-339d287c44315dbc77cdff781c1a43fb8a7b242996f2c5b883bda1bfcfae83a3}"
ADDR="${SAFENODE_PROBE_ADDR:-0x0000000000000000000000000000000000000000}"
MAX_RETRIES="${SAFENODE_MAX_RETRIES:-20}"
RETRY_DELAY="${SAFENODE_RETRY_DELAY:-5}"

ADMIN_URL="https://rpc.safe-node.com/$ADMIN/admin"
RPC_URL="https://rpc.safe-node.com/$KEY/json_rpc"

echo "=== admin_get_sync_status ==="
SYNC="$(curl --pinnedpubkey "$PIN" -sS -X POST "$ADMIN_URL" \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"admin_get_sync_status","params":[]}')"
echo "$SYNC" | jq '.result | {latest_root_number, historical_root_number, live_root_number, latest_node_delta_number, historical_node_delta_number}'

LATEST="$(echo "$SYNC" | jq -r '.result.latest_root_number // empty')"
HIST="$(echo "$SYNC"   | jq -r '.result.historical_root_number // empty')"
if [ -z "$LATEST" ]; then
  echo "✗ admin call did not return latest_root_number"
  exit 1
fi

try_proof() {
  local block_dec="$1"
  local label="$2"
  local block_hex
  block_hex="$(printf '0x%x' "$block_dec")"
  local body
  body="$(jq -nc --arg b "$block_hex" --arg a "$ADDR" \
    '{jsonrpc:"2.0",id:1,method:"eth_getProof",params:[$a,[],$b]}')"

  echo
  echo "=== eth_getProof @ block $block_hex (decimal $block_dec) [$label] ==="
  for i in $(seq 1 "$MAX_RETRIES"); do
    local raw
    raw="$(curl --pinnedpubkey "$PIN" -sS -X POST "$RPC_URL" \
      -H 'content-type: application/json' --data "$body")"

    if echo "$raw" | jq -e '.result.accountProof | length > 0' >/dev/null 2>&1; then
      echo "attempt $i: ✓ proof materialized"
      echo "$raw" | jq '.result | {balance, nonce, codeHash, storageHash, accountProof_len: (.accountProof|length)}'
      return 0
    fi

    local code
    code="$(echo "$raw" | jq -r '.error.code // "?"')"
    local msg
    msg="$(echo "$raw" | jq -r '.error.message // ""')"
    echo "attempt $i: code=$code $msg"
    if [ "$code" != "-32001" ]; then
      echo "non-retriable error; aborting"
      return 1
    fi
    sleep "$RETRY_DELAY"
  done
  echo "✗ exhausted $MAX_RETRIES retries at block $block_hex"
  return 1
}

# Try the historical snapshot block first — its node delta lane has been
# warming since startup, so it's the most likely to land on the first try.
if [ -n "$HIST" ] && [ "$HIST" != "0" ]; then
  try_proof "$HIST" "historical snapshot" && exit 0
fi

# Fall back to the latest root. This may take more retries because the
# server has to backfill the witness nodes on demand.
try_proof "$LATEST" "live latest root" && exit 0

echo
echo "✗ both block heights failed; share the output with the operator"
exit 1
