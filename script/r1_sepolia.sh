#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

KEY_NAME="${LEAN_KOHAKU_TPM_KEY:-daily}"
KEY_DIR=".leankohaku/keystore/tpm2/${KEY_NAME}"
ACCOUNT_FILE="${KEY_DIR}/r1-account-address.txt"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 1
  fi
}

need_env() {
  if [[ -z "${!1:-}" ]]; then
    echo "missing env var: $1" >&2
    exit 1
  fi
}

deployer_private_key() {
  if [[ -n "${SEPOLIA_DEPLOYER_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SEPOLIA_DEPLOYER_PRIVATE_KEY"
  elif [[ -n "${PRIVATE_KEY:-}" ]]; then
    printf '%s' "$PRIVATE_KEY"
  else
    echo "missing env var: SEPOLIA_DEPLOYER_PRIVATE_KEY or PRIVATE_KEY" >&2
    exit 1
  fi
}

load_pubkey_xy() {
  require openssl
  require python3

  local pem="${KEY_DIR}/public.pem"
  if [[ ! -f "$pem" ]]; then
    echo "missing TPM public key: $pem" >&2
    echo "run: ./.lake/build/bin/leankohaku wallet create r1 ${KEY_NAME}" >&2
    exit 1
  fi

  local der="${KEY_DIR}/public.der"
  openssl pkey -pubin -in "$pem" -pubout -outform DER -out "$der"
  python3 - "$der" <<'PY'
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
point = data[-65:]
if len(point) != 65 or point[0] != 0x04:
    raise SystemExit("unexpected P-256 SPKI public key encoding")
qx = point[1:33].hex()
qy = point[33:65].hex()
print(f"0x{qx} 0x{qy}")
PY
}

account_address() {
  if [[ -n "${R1_ACCOUNT_ADDRESS:-}" ]]; then
    echo "$R1_ACCOUNT_ADDRESS"
  elif [[ -f "$ACCOUNT_FILE" ]]; then
    tr -d '[:space:]' < "$ACCOUNT_FILE"
  else
    echo "missing R1 account address; deploy first or set R1_ACCOUNT_ADDRESS" >&2
    exit 1
  fi
}

signature_rs() {
  require python3
  local sig="${KEY_DIR}/signature.bin"
  if [[ ! -f "$sig" ]]; then
    echo "missing TPM signature: $sig" >&2
    exit 1
  fi
  python3 - "$sig" <<'PY'
import pathlib
import sys

sig = pathlib.Path(sys.argv[1]).read_bytes()
if len(sig) != 64:
    if len(sig) < 8 or sig[0] != 0x30:
        raise SystemExit(f"expected 64-byte plain or DER P-256 signature, got {len(sig)} bytes")
    idx = 2
    if sig[1] & 0x80:
        length_len = sig[1] & 0x7f
        idx = 2 + length_len
    if idx >= len(sig) or sig[idx] != 0x02:
        raise SystemExit("invalid DER signature: missing r integer")
    r_len = sig[idx + 1]
    r = sig[idx + 2:idx + 2 + r_len]
    idx = idx + 2 + r_len
    if idx >= len(sig) or sig[idx] != 0x02:
        raise SystemExit("invalid DER signature: missing s integer")
    s_len = sig[idx + 1]
    s = sig[idx + 2:idx + 2 + s_len]
    r = r.lstrip(b"\x00")
    s = s.lstrip(b"\x00")
    if len(r) > 32 or len(s) > 32:
        raise SystemExit("invalid DER signature: r or s longer than 32 bytes")
    r = r.rjust(32, b"\x00")
    s = s.rjust(32, b"\x00")
else:
    r = sig[:32]
    s = sig[32:]
print(f"0x{r.hex()} 0x{s.hex()}")
PY
}

compute_digest() {
  require cast
  need_env SEPOLIA_RPC_URL
  local account target value data nonce
  account="$(account_address)"
  target="${1:?target required}"
  value="${2:?value required}"
  data="${3:-0x}"
  nonce="$(cast call --rpc-url "$SEPOLIA_RPC_URL" "$account" "nonce()(uint256)")"
  cast call --rpc-url "$SEPOLIA_RPC_URL" "$account" \
    "digestFor(address,uint256,bytes,uint256)(bytes32)" \
    "$target" "$value" "$data" "$nonce"
}

eth_to_wei() {
  require cast
  local eth_value="${1:?eth value required}"
  cast to-wei "$eth_value" ether
}

execute_signed() {
  require cast
  need_env SEPOLIA_RPC_URL
  local pk account target value data r s
  pk="$(deployer_private_key)"
  account="$(account_address)"
  target="${1:?target required}"
  value="${2:?value required}"
  data="${3:-0x}"
  read -r r s < <(signature_rs)
  echo "Broadcasting R1 execute from $account"
  echo "  to: $target"
  echo "  value wei: $value"
  cast send --rpc-url "$SEPOLIA_RPC_URL" \
    --private-key "$pk" \
    "$account" "execute(address,uint256,bytes,bytes32,bytes32)" \
    "$target" "$value" "$data" "$r" "$s"
}

# Split the inline 64-byte signature hex into r and s files inside the
# key directory, so execute_signed -> signature_rs can pick them up
# without having to touch the TPM. The daemon writes the live TPM2
# signature for us; this mirrors that path for the broadcast-signed
# subcommand.
write_signature_from_hex() {
  local hex="${1:?signature hex required}"
  local raw="${hex#0x}"
  # Accept either raw r||s (64 bytes / 128 hex) or DER (typically 70-72 bytes
  # / 140-144 hex). signature_rs() handles both formats.
  if (( ${#raw} % 2 != 0 )) || (( ${#raw} < 128 )) || (( ${#raw} > 160 )); then
    echo "expected 64–80 byte signature hex; got ${#raw} chars" >&2
    exit 1
  fi
  mkdir -p "$KEY_DIR"
  printf '%s' "$raw" | xxd -r -p > "${KEY_DIR}/signature.bin"
}

# Print the digest, the R1 account address, and the wei value as three
# whitespace-separated tokens on stdout. The daemon parses the first
# token as the digest hex.
emit_digest_bundle() {
  local target="$1" value="$2" data="$3"
  local digest account
  digest="$(compute_digest "$target" "$value" "$data")"
  account="$(account_address)"
  printf '%s %s %s\n' "$digest" "$account" "$value"
}

cmd="${1:-help}"
case "$cmd" in
  deploy)
    require forge
    need_env SEPOLIA_RPC_URL
    pk="$(deployer_private_key)"
    read -r qx qy < <(load_pubkey_xy)
    cat >&2 <<'EOF'
WARNING: deploying solidity/dev/R1AccountDev.sol.
This is a temporary Solidity fallback for Sepolia testing only.
Canonical source remains Contracts/R1Account/R1Account.lean.
EOF
    out="$(forge create \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$pk" \
      --broadcast \
      solidity/dev/R1AccountDev.sol:R1AccountDev \
      --constructor-args "$qx" "$qy")"
    echo "$out"
    addr="$(printf '%s\n' "$out" | awk '/Deployed to:/ {print $3}')"
    if [[ -n "$addr" ]]; then
      mkdir -p "$KEY_DIR"
      printf '%s\n' "$addr" > "$ACCOUNT_FILE"
      echo "saved account address to $ACCOUNT_FILE"
    fi
    ;;

  digest)
    target="${2:?usage: r1_sepolia.sh digest <target> <value-wei> [data-hex]}"
    value="${3:?usage: r1_sepolia.sh digest <target> <value-wei> [data-hex]}"
    data="${4:-0x}"
    compute_digest "$target" "$value" "$data"
    ;;

  sign)
    digest="${2:?usage: r1_sepolia.sh sign <digest-hex>}"
    ./.lake/build/bin/leankohaku wallet sign sepolia "$KEY_NAME" "$digest"
    ;;

  execute)
    target="${2:?usage: r1_sepolia.sh execute <target> <value-wei> [data-hex]}"
    value="${3:?usage: r1_sepolia.sh execute <target> <value-wei> [data-hex]}"
    data="${4:-0x}"
    execute_signed "$target" "$value" "$data"
    ;;

  send)
    target="${2:?usage: r1_sepolia.sh send <target> <value-wei> [data-hex]}"
    value="${3:?usage: r1_sepolia.sh send <target> <value-wei> [data-hex]}"
    data="${4:-0x}"
    account="$(account_address)"
    echo "R1 account: $account"
    echo "Target: $target"
    echo "Value wei: $value"
    digest="$(compute_digest "$target" "$value" "$data")"
    echo "Digest: $digest"
    ./.lake/build/bin/leankohaku wallet sign sepolia "$KEY_NAME" "$digest"
    echo "Signature complete; broadcasting transaction..."
    execute_signed "$target" "$value" "$data"
    ;;

  prepare-digest)
    target="${2:?usage: r1_sepolia.sh prepare-digest <target> <value-wei> [data-hex]}"
    value="${3:?usage: r1_sepolia.sh prepare-digest <target> <value-wei> [data-hex]}"
    data="${4:-0x}"
    emit_digest_bundle "$target" "$value" "$data"
    ;;

  prepare-digest-eth)
    target="${2:?usage: r1_sepolia.sh prepare-digest-eth <target> <value-eth> [data-hex]}"
    valueEth="${3:?usage: r1_sepolia.sh prepare-digest-eth <target> <value-eth> [data-hex]}"
    data="${4:-0x}"
    valueWei="$(eth_to_wei "$valueEth")"
    emit_digest_bundle "$target" "$valueWei" "$data"
    ;;

  broadcast-signed)
    sigHex="${2:?usage: r1_sepolia.sh broadcast-signed <signature-hex> <target> <value-wei> [data-hex]}"
    target="${3:?usage: r1_sepolia.sh broadcast-signed <signature-hex> <target> <value-wei> [data-hex]}"
    value="${4:?usage: r1_sepolia.sh broadcast-signed <signature-hex> <target> <value-wei> [data-hex]}"
    data="${5:-0x}"
    write_signature_from_hex "$sigHex"
    require cast
    need_env SEPOLIA_RPC_URL
    pk="$(deployer_private_key)"
    account="$(account_address)"
    read -r r s < <(signature_rs)
    # Use --async so cast returns the txHash immediately; the daemon
    # polls eth_getTransactionReceipt itself and emits live progress
    # notifications during the wait.
    cast send --async --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$pk" \
      "$account" "execute(address,uint256,bytes,bytes32,bytes32)" \
      "$target" "$value" "$data" "$r" "$s"
    ;;

  send-eth)
    target="${2:?usage: r1_sepolia.sh send-eth <target> <value-eth> [data-hex]}"
    valueEth="${3:?usage: r1_sepolia.sh send-eth <target> <value-eth> [data-hex]}"
    data="${4:-0x}"
    valueWei="$(eth_to_wei "$valueEth")"
    echo "Value ETH: $valueEth"
    echo "Value wei: $valueWei"
    "$0" send "$target" "$valueWei" "$data"
    ;;

  address)
    account_address
    ;;

  *)
    cat <<EOF
Usage:
  LEAN_KOHAKU_TPM_KEY=daily ./script/r1_sepolia.sh deploy  # temporary Solidity fallback
  ./script/r1_sepolia.sh address
  ./script/r1_sepolia.sh digest <target> <value-wei> [data-hex]
  ./script/r1_sepolia.sh sign <digest-hex>
  ./script/r1_sepolia.sh execute <target> <value-wei> [data-hex]
  ./script/r1_sepolia.sh send <target> <value-wei> [data-hex]
  ./script/r1_sepolia.sh send-eth <target> <value-eth> [data-hex]
  ./script/r1_sepolia.sh prepare-digest <target> <value-wei> [data-hex]
  ./script/r1_sepolia.sh prepare-digest-eth <target> <value-eth> [data-hex]
  ./script/r1_sepolia.sh broadcast-signed <signature-hex> <target> <value-wei> [data-hex]

Required env:
  SEPOLIA_RPC_URL
  SEPOLIA_DEPLOYER_PRIVATE_KEY or PRIVATE_KEY

Optional env:
  LEAN_KOHAKU_TPM_KEY=daily
  R1_ACCOUNT_ADDRESS=<deployed-account>
EOF
    ;;
esac
