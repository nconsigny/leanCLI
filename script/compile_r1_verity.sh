#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERITY_DIR="${ROOT}/.lake/packages/verity"

if [[ ! -d "$VERITY_DIR/.git" ]]; then
  echo "missing Verity checkout; run ./script/setup_verity.sh first" >&2
  exit 1
fi

cat >&2 <<'EOF'
R1Account is authored in Lean at:
  Contracts/R1Account/R1Account.lean

The upstream Verity compiler expects contracts inside its own Lake package
and currently pins Lean 4.22.0. leanCLI pins Lean 4.29.1.

Next integration task:
  1. add a compatible Verity package/toolchain,
  2. register Contracts.R1Account.R1Account as a compiler module,
  3. link LeanCli_R1_p256Verify to an EIP-7951/P256VERIFY Yul helper,
  4. emit deployable Yul/EVM bytecode to artifacts/r1-sepolia/.

This script intentionally fails until that compatibility bridge is in place,
so we do not accidentally deploy stale Solidity or unverified bytecode.
EOF

exit 1
