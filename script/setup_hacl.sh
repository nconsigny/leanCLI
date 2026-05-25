#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HACL_URL="${HACL_URL:-https://github.com/cryspen/hacl-packages.git}"
HACL_REV="${HACL_REV:-05c3d8fb321ed65e3db3a6a8b853019e86fb40a2}"
HACL_SRC="${ROOT}/.lake/packages/hacl-packages"
HACL_PREFIX="${ROOT}/.lake/hacl"
HELPER_DIR="${ROOT}/.lake/build/bin"

missing=()
for tool in git cmake ninja cc cargo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing+=("$tool")
  fi
done

if [[ "${#missing[@]}" -ne 0 ]]; then
  echo "missing HACL build tools: ${missing[*]}" >&2
  echo "Ubuntu: sudo apt install git cmake ninja-build gcc" >&2
  echo "Arch:   sudo pacman -S git cmake ninja gcc" >&2
  echo "macOS:  brew install git cmake ninja rustup-init && rustup-init -y && xcode-select --install   # cc/cargo via Xcode CLT + rustup" >&2
  exit 1
fi

mkdir -p "${ROOT}/.lake/packages" "$HELPER_DIR"

if [[ ! -d "$HACL_SRC/.git" ]]; then
  git clone "$HACL_URL" "$HACL_SRC"
fi

git -C "$HACL_SRC" fetch --depth 1 origin "$HACL_REV"
git -C "$HACL_SRC" checkout --detach "$HACL_REV"

cmake -S "$HACL_SRC" -B "$HACL_SRC/build/leankohaku" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$HACL_PREFIX" \
  -DENABLE_TESTS=OFF \
  -DENABLE_BENCHMARKS=OFF

# Some hacl-packages revisions generate config.h under the configured build
# directory but their install script expects it under build/config.h.
if [[ -f "$HACL_SRC/build/leankohaku/config.h" && ! -f "$HACL_SRC/build/config.h" ]]; then
  cp "$HACL_SRC/build/leankohaku/config.h" "$HACL_SRC/build/config.h"
fi

cmake --build "$HACL_SRC/build/leankohaku" --target install

build_helper() {
  local src="$1"
  local out="$2"
  cc -O2 \
    -I"${ROOT}/c/hacl_helpers" \
    -I"$HACL_PREFIX/include" \
    -I"$HACL_PREFIX/include/hacl" \
    -I"$HACL_SRC/include" \
    -I"$HACL_SRC/karamel/include" \
    "$src" \
    -L"$HACL_PREFIX/lib" -lhacl \
    -Wl,-rpath,"$HACL_PREFIX/lib" \
    -o "$out"
}

build_helper "${ROOT}/c/hacl_helpers/hacl_keccak256.c" "$HELPER_DIR/leankohaku-hacl-keccak256"
build_helper "${ROOT}/c/hacl_helpers/hacl_sha256.c" "$HELPER_DIR/leankohaku-hacl-sha256"
build_helper "${ROOT}/c/hacl_helpers/hacl_hmac_sha512.c" "$HELPER_DIR/leankohaku-hacl-hmac-sha512"
build_helper "${ROOT}/c/hacl_helpers/hacl_hmac_sha256.c" "$HELPER_DIR/leankohaku-hacl-hmac-sha256"
build_helper "${ROOT}/c/hacl_helpers/hacl_pbkdf2_sha512.c" "$HELPER_DIR/leankohaku-hacl-pbkdf2"
build_helper "${ROOT}/c/hacl_helpers/hacl_hmac_drbg_sha256.c" "$HELPER_DIR/leankohaku-hacl-hmac-drbg"
build_helper "${ROOT}/c/hacl_helpers/hacl_chacha20poly1305.c" "$HELPER_DIR/leankohaku-hacl-chacha20poly1305"

cargo build --release --manifest-path "${ROOT}/c/rustcrypto_helpers/Cargo.toml"
cp "${ROOT}/c/rustcrypto_helpers/target/release/leankohaku-hacl-ripemd160" "$HELPER_DIR/leankohaku-hacl-ripemd160"

cat <<EOF
HACL installed at:
  $HACL_PREFIX

Helpers installed at:
  $HELPER_DIR/leankohaku-hacl-keccak256
  $HELPER_DIR/leankohaku-hacl-sha256
  $HELPER_DIR/leankohaku-hacl-hmac-sha512
  $HELPER_DIR/leankohaku-hacl-hmac-sha256
  $HELPER_DIR/leankohaku-hacl-pbkdf2
  $HELPER_DIR/leankohaku-hacl-hmac-drbg
  $HELPER_DIR/leankohaku-hacl-chacha20poly1305
  $HELPER_DIR/leankohaku-hacl-ripemd160

Add to PATH if needed:
  export PATH="$HELPER_DIR:\$PATH"
EOF
