#!/usr/bin/env bash
# tests/safenode_gcp_attest.sh
#
# One-shot GCP Confidential Space attestation of the safe-node deployment,
# using the vendored verifier (sidecars/kohaku/safenode/verify_client_tdx.mjs).
# Pure Node — no Rust tdx_quote_verifier needed in this mode.
#
# Verifies the Google-signed OIDC token (audience, nonce bound to the served
# TLS cert + a fresh challenge, GCP_INTEL_TDX, secure boot, debug disabled,
# STABLE image, expected OCI image digest, entrypoint, env launch policy),
# derives the attested TLS pin, and — if ATTESTED_TLS_PIN is set — checks the
# derived pin against the operator-published one.
#
# Env you can override:
#   LEANCLI_SAFE_NODE_URL        deployment base URL
#   CONFIDENTIAL_SPACE_AUDIENCE  OIDC audience (default safe-node:<host>)
#   EXPECTED_GCP_IMAGE_DIGEST    expected OCI image digest
#   ATTESTED_TLS_PIN             expected pin; empty = just print the derived pin

set -u

BASE="${LEANCLI_SAFE_NODE_URL:-https://rpc-gcp.safe-node.com}"
HOST="${BASE#https://}"
AUD="${CONFIDENTIAL_SPACE_AUDIENCE:-safe-node:$HOST}"
DIGEST="${EXPECTED_GCP_IMAGE_DIGEST:-sha256:61aa4c551e8327459c38b152695193003e789d55844a21ab1b1d35b031906282}"
EXPECTED_PIN="${ATTESTED_TLS_PIN:-sha256//BoHHay/wHtVESvf+Bh2MKh4A3wwAnRg47MZPE3tn1fU=}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$REPO_ROOT/sidecars/kohaku/safenode/verify_client_tdx.mjs"

echo "=== GCP Confidential Space attestation: $BASE ==="
echo "audience:      $AUD"
echo "image digest:  $DIGEST"
OUT="$(node "$VERIFIER" "$BASE" \
  --gcp-confidential-space \
  --attested-tls \
  --tls-domain "$HOST" \
  --gcp-audience "$AUD" \
  --expected-gcp-image-digest "$DIGEST")" || {
  echo "✗ attestation failed"
  exit 1
}
echo "$OUT"

DERIVED_PIN="$(echo "$OUT" | sed -n 's/^attested_tls_pin=//p' | tail -1)"
if [ -z "$DERIVED_PIN" ]; then
  echo "✗ verifier succeeded but printed no attested_tls_pin"
  exit 1
fi
if [ -n "$EXPECTED_PIN" ] && [ "$DERIVED_PIN" != "$EXPECTED_PIN" ]; then
  echo "✗ derived pin does not match expected pin"
  echo "  derived:  $DERIVED_PIN"
  echo "  expected: $EXPECTED_PIN"
  echo "  (the pin rotates with ACME finalization — confirm with the operator"
  echo "   before trusting the new one, then update the inlined default)"
  exit 1
fi
echo "✓ attestation OK, pin = $DERIVED_PIN"
