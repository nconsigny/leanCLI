#!/usr/bin/env bash
# StateVault + MPT verifier smoke test.
#
# Builds and runs the `vault_test` executable: SQLite roundtrip (schema,
# tier no-downgrade), RLP decoder roundtrips/canonicality, and
# self-consistent Merkle-Patricia proof fixtures. The MPT section needs
# the native `leancli-hacl-keccak256` helper (`lake script run
# setup-helpers`); without it the section SKIPs and this script warns.
set -euo pipefail

cd "$(dirname "$0")/../.."

echo "[vault-smoke] lake build vault_test"
lake build vault_test

if ! command -v leancli-hacl-keccak256 >/dev/null 2>&1 \
    && [ ! -x .lake/build/bin/leancli-hacl-keccak256 ]; then
  echo "[vault-smoke] warning: leancli-hacl-keccak256 not built —" \
       "MPT fixtures will SKIP (run: lake script run setup-helpers)"
fi

echo "[vault-smoke] running vault_test"
.lake/build/bin/vault_test

echo "[vault-smoke] OK"
