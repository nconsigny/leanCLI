#!/usr/bin/env bash
# Sepolia-only deploy + diagnostics for the SPHINCS- hybrid factory.
#
# Mirrors `script/r1_sepolia.sh` in shape so the daemon's
# `sphincs.factory.deploy` RPC can shell out the same way as
# `tpm.deploy` does. Refuses non-Sepolia chains because the on-chain
# verifier addresses we ship in defaults are Sepolia-only and no
# mainnet factory has been deployed at the time of writing.
#
# Usage:
#   sphincs_sepolia.sh deploy <paramSet>
#     - Reads SPHINCS_VERIFIER_ADDR (the per-paramSet shared verifier on
#       Sepolia) from the env, plus SEPOLIA_DEPLOYER_PRIVATE_KEY or
#       PRIVATE_KEY for the funded deployer EOA, and SEPOLIA_RPC_URL.
#     - Calls `forge create` on solidity/sphincs/SphincsAccountFactoryDev.sol
#       with constructor args (entryPoint=v0.9 singleton, verifier=<env>).
#     - Saves the resulting factory address to
#       $XDG_DATA_HOME/leankohaku/sphincs-factories/sepolia-<paramSet>.txt
#       so subsequent daemon reads can pick it up without a daemon.json
#       edit. The daemon RPC also echoes the address in its response.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# v0.9 EntryPoint deterministic deployment — same address on every EVM chain.
ENTRY_POINT_V09="0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108"

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

factory_state_path() {
  local paramSet="$1"
  local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  local dir="${data_home}/leankohaku/sphincs-factories"
  mkdir -p "$dir"
  printf '%s/sepolia-%s.txt' "$dir" "$paramSet"
}

cmd="${1:-help}"
case "$cmd" in
  deploy)
    paramSet="${2:?usage: sphincs_sepolia.sh deploy <paramSet>}"
    require forge
    need_env SEPOLIA_RPC_URL
    need_env SPHINCS_VERIFIER_ADDR
    pk="$(deployer_private_key)"
    cat >&2 <<EOF
deploying solidity/sphincs/SphincsAccountFactoryDev.sol on Sepolia
  paramSet: ${paramSet}
  entryPoint (v0.9): ${ENTRY_POINT_V09}
  verifier: ${SPHINCS_VERIFIER_ADDR}
EOF
    out="$(forge create \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$pk" \
      --broadcast \
      solidity/sphincs/SphincsAccountFactoryDev.sol:SphincsAccountFactoryDev \
      --constructor-args "$ENTRY_POINT_V09" "$SPHINCS_VERIFIER_ADDR")"
    echo "$out"
    addr="$(printf '%s\n' "$out" | awk '/Deployed to:/ {print $3}')"
    if [[ -n "$addr" ]]; then
      out_file="$(factory_state_path "$paramSet")"
      printf '%s\n' "$addr" > "$out_file"
      echo "saved factory address to $out_file"
    else
      echo "warning: could not parse 'Deployed to:' line; check forge output above" >&2
      exit 2
    fi
    ;;

  address)
    paramSet="${2:?usage: sphincs_sepolia.sh address <paramSet>}"
    out_file="$(factory_state_path "$paramSet")"
    if [[ -f "$out_file" ]]; then
      tr -d '[:space:]' < "$out_file"
      echo ""
    else
      echo "no factory address recorded for paramSet=${paramSet} on sepolia" >&2
      echo "(run sphincs_sepolia.sh deploy ${paramSet})" >&2
      exit 1
    fi
    ;;

  help|*)
    cat <<USAGE
sphincs_sepolia.sh deploy <paramSet>
sphincs_sepolia.sh address <paramSet>
USAGE
    ;;
esac
