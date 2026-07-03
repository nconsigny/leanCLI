#!/usr/bin/env bash
# tests/safenode_proof.sh
#
# End-to-end eth_getProof smoke test against the safe-node deployment
# (default: the GCP Confidential Space instance at rpc-gcp.safe-node.com).
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

# Current GCP Confidential Space dev deployment; pin published by the
# operator 2026-07-02 (rotates with ACME finalization — on mismatch,
# re-derive via ops/tests/safenode_gcp_attest.sh before trusting it).
BASE="${LEANCLI_SAFE_NODE_URL:-https://rpc-gcp.safe-node.com}"
PIN="${ATTESTED_TLS_PIN:-sha256//BoHHay/wHtVESvf+Bh2MKh4A3wwAnRg47MZPE3tn1fU=}"
KEY="${LEANCLI_SAFE_NODE_API_KEY:-olabs-api-6f66df6d6bd1669ed0b2c3c4b2ef8e4307b334b8be7a2f3f6dcae10ada44f82b}"
ADMIN="${SAFENODE_ADMIN_KEY:-olabs-admin-6b2b28301cc9c5752efecd051e3756a13008300a42dc16ec368a8d9b1d6a5785}"
ADDR="${SAFENODE_PROBE_ADDR:-0x0000000000000000000000000000000000000000}"
MAX_RETRIES="${SAFENODE_MAX_RETRIES:-20}"
RETRY_DELAY="${SAFENODE_RETRY_DELAY:-5}"

ADMIN_URL="$BASE/$ADMIN/admin"
RPC_URL="$BASE/$KEY/json_rpc"

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
