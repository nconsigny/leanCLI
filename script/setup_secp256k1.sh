#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECP_URL="${SECP_URL:-https://github.com/bitcoin-core/secp256k1.git}"
SECP_REV="${SECP_REV:-1a53f4961f337b4d166c25fce72ef0dc88806618}"
SECP_SRC="${ROOT}/.lake/packages/secp256k1"
SECP_PREFIX="${ROOT}/.lake/secp256k1"
HELPER_DIR="${ROOT}/.lake/build/bin"

missing=()
for tool in git cmake ninja cc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if [[ "${#missing[@]}" -ne 0 ]]; then
  echo "missing secp256k1 build tools: ${missing[*]}" >&2
  echo "Ubuntu: sudo apt install git cmake ninja-build gcc" >&2
  echo "Arch:   sudo pacman -S git cmake ninja gcc" >&2
  echo "macOS:  brew install git cmake ninja && xcode-select --install   # cc via Xcode Command Line Tools" >&2
  exit 1
fi

mkdir -p "${ROOT}/.lake/packages" "$HELPER_DIR"

if [[ ! -d "$SECP_SRC/.git" ]]; then
  git clone "$SECP_URL" "$SECP_SRC"
fi

git -C "$SECP_SRC" fetch --depth 1 origin "$SECP_REV"
git -C "$SECP_SRC" checkout --detach "$SECP_REV"

cmake -S "$SECP_SRC" -B "$SECP_SRC/build/leancli" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SECP_PREFIX" \
  -DSECP256K1_ENABLE_MODULE_RECOVERY=ON \
  -DSECP256K1_BUILD_TESTS=OFF \
  -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF \
  -DSECP256K1_BUILD_BENCHMARK=OFF \
  -DSECP256K1_BUILD_CTIME_TESTS=OFF

cmake --build "$SECP_SRC/build/leancli" --target install

build_helper() {
  local src="$1"
  local out="$2"
  cc -O2 \
    -I"${ROOT}/c/secp256k1_helpers" \
    -I"${ROOT}/c/hacl_helpers" \
    -I"$SECP_PREFIX/include" \
    "$src" \
    -L"$SECP_PREFIX/lib" -lsecp256k1 \
    -Wl,-rpath,"$SECP_PREFIX/lib" \
    -o "$out"
}

build_helper "${ROOT}/c/secp256k1_helpers/secp256k1_sign.c" "$HELPER_DIR/leancli-secp256k1-sign"
build_helper "${ROOT}/c/secp256k1_helpers/secp256k1_pubkey.c" "$HELPER_DIR/leancli-secp256k1-pubkey"
build_helper "${ROOT}/c/secp256k1_helpers/secp256k1_recover.c" "$HELPER_DIR/leancli-secp256k1-recover"
build_helper "${ROOT}/c/secp256k1_helpers/secp256k1_verify.c" "$HELPER_DIR/leancli-secp256k1-verify"

cat <<EOF
libsecp256k1 installed at:
  $SECP_PREFIX

Helpers installed at:
  $HELPER_DIR/leancli-secp256k1-sign
  $HELPER_DIR/leancli-secp256k1-pubkey
  $HELPER_DIR/leancli-secp256k1-recover
  $HELPER_DIR/leancli-secp256k1-verify

Add to PATH if needed:
  export PATH="$HELPER_DIR:\$PATH"
EOF
