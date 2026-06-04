#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERITY_DIR="${ROOT}/.lake/packages/verity"
VERITY_REV="${VERITY_REV:-103311b0ebef7203c6ab14dc4fc7e10d32d5def0}"
VERITY_URL="${VERITY_URL:-https://github.com/lfglabs-dev/verity.git}"

mkdir -p "${ROOT}/.lake/packages"

if [[ ! -d "$VERITY_DIR/.git" ]]; then
  git clone "$VERITY_URL" "$VERITY_DIR"
fi

git -C "$VERITY_DIR" fetch --depth 1 origin "$VERITY_REV"
git -C "$VERITY_DIR" checkout --detach "$VERITY_REV"

cat <<EOF
Verity pinned at:
  $VERITY_DIR
  $VERITY_REV

Note: upstream Verity currently pins Lean 4.22.0 while leanCLI pins
Lean 4.29.1. Build/compile Verity artifacts in a matching Verity toolchain
until the dependency is upgraded or vendored compatibly.
EOF
