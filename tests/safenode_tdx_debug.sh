#!/usr/bin/env bash
# tests/safenode_tdx_debug.sh
#
# Diagnostic for "TDX verify failed: TDX quote verifier failed" — the Rust
# verifier is exiting non-zero with empty stderr+stdout. This script runs
# each piece in isolation so we see what's actually going wrong.

set -u

: "${TDX_QUOTE_VERIFIER_BIN:?must point at the Rust tdx_quote_verifier}"
PIN="${ATTESTED_TLS_PIN:-sha256//3VHy52Tn0kQ7io763wwEiKewgH8f4LjA+HHT0bmzOxg=}"
APP="${SAFENODE_APP_URL:-https://rpc.safe-node.com}"

echo "=== [1] binary sanity ==="
ls -la "$TDX_QUOTE_VERIFIER_BIN" || true
file "$TDX_QUOTE_VERIFIER_BIN" 2>/dev/null || true
echo "--- --help ---"
"$TDX_QUOTE_VERIFIER_BIN" --help 2>&1 | head -40 || echo "binary refused --help (status=$?)"
echo

echo "=== [2] fetch fresh /attestation ==="
RD="0x$(openssl rand -hex 32)"
echo "report_data: $RD"
TMP="$(mktemp /tmp/safenode-attest.XXXXXX.json)"
HTTP_CODE="$(curl --pinnedpubkey "$PIN" -sS -o "$TMP" -w '%{http_code}' \
  "$APP/attestation?report_data=$RD")"
echo "HTTP $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
  echo "✗ /attestation did not return 200; aborting"
  head -c 500 "$TMP"; echo
  exit 1
fi
QUOTE="$(jq -r .quote "$TMP")"
echo "quote length: ${#QUOTE} chars"

echo
echo "=== [3] run verifier directly with full stderr ==="
RUST_LOG=debug RUST_BACKTRACE=1 \
  "$TDX_QUOTE_VERIFIER_BIN" \
    --quote-hex   "0x$QUOTE" \
    --report-data-hex "$RD" 2>&1 | tee /tmp/safenode-verifier.out
status=${PIPESTATUS[0]}
echo
echo "verifier exit status: $status"
echo "verifier output bytes: $(wc -c < /tmp/safenode-verifier.out)"

if [ "$status" -ne 0 ]; then
  echo
  echo "Hints based on output:"
  if grep -qi "pccs\|provisioning" /tmp/safenode-verifier.out; then
    echo "  - PCCS-related: try setting KOHAKU_SAFE_NODE_PCCS_URL"
  fi
  if grep -qi "no such file\|not found" /tmp/safenode-verifier.out; then
    echo "  - missing-file: verifier may want files relative to its CWD"
  fi
  if grep -qi "permission" /tmp/safenode-verifier.out; then
    echo "  - permission issue on the binary or a config dir"
  fi
  if [ ! -s /tmp/safenode-verifier.out ]; then
    echo "  - verifier produced no output AT ALL — likely SIGSEGV / dynamic-linker"
    echo "    rerun with: ldd \"\$TDX_QUOTE_VERIFIER_BIN\""
    echo "    or: strace -f -e trace=execve,openat -- \"\$TDX_QUOTE_VERIFIER_BIN\" --help 2>&1 | head -40"
  fi
fi
