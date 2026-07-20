#!/usr/bin/env bash
# Offline smoke checks for the shared Privacy Pools / Railgun bridge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIDE="$ROOT/sidecars/kohaku"
FAIL=0

run() { node "$SIDE/bridge.mjs" --rpc "$1" 2>/dev/null; }

want() {
  case "$2" in
    *"$1"*) printf 'ok   %s\n' "$3" ;;
    *) printf 'FAIL %s\n     wanted substring: %s\n     got: %s\n' "$3" "$1" "$2"; FAIL=1 ;;
  esac
}

echo "== kohaku shared sidecar offline smoke =="

want '"ok":true' \
  "$(run '{"jsonrpc":"2.0","id":1,"method":"ping"}')" \
  "ping"

want 'plugin not enabled: privacy-pools' \
  "$(run '{"jsonrpc":"2.0","id":2,"method":"shielded.balance","params":{}}')" \
  "gate blocks disabled privacy-pools"

want 'plugin not enabled: railgun' \
  "$(run '{"jsonrpc":"2.0","id":3,"method":"shielded.railgun.balance","params":{}}')" \
  "gate blocks disabled railgun"

# Valid requests reach the target package import, then stop at the first
# intentionally omitted secret. This proves package loading and dispatch work
# without requiring RPC access, funded notes, or proving artifacts.
want 'LEANCLI_PP_MNEMONIC is required' \
  "$(LEANCLI_PRIVACY=privacy-pools LEANCLI_CHAIN_ID=11155111 \
     LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":4,"method":"shielded.balance","params":{}}')" \
  "privacy-pools alpha.14 imports"

want 'LEANCLI_RG_SEED_HEX or LEANCLI_RG_MNEMONIC is required' \
  "$(LEANCLI_PRIVACY=railgun LEANCLI_CHAIN_ID=11155111 \
     LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":5,"method":"shielded.railgun.balance","params":{}}')" \
  "railgun alpha.28 imports"

# Unit tests. plugin-api.test.mjs imports @kohaku-eth/privacy-pools, whose
# bundled output uses extension-less specifiers — it only resolves under the
# same ESM loader bridge.mjs re-execs itself with, so run node --test under it.
echo "== kohaku sidecar unit tests =="
if node --no-warnings --experimental-loader "$SIDE/loader.mjs" --test \
    "$SIDE/max-amount.test.mjs" "$SIDE/plugin-api.test.mjs"; then
  echo "ok   unit tests (max-amount, plugin-api)"
else
  echo "FAIL unit tests (max-amount, plugin-api)"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "== FAILED =="
  exit 1
fi
echo "== all kohaku shared sidecar offline checks passed =="
