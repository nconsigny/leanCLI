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
#     - Calls `forge create` on the upstream
#       lib/sphincs-minus/src/SphincsAccountFactory.sol (canonical
#       contract that inherits BaseAccount from account-abstraction).
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
  deploy-verifier)
    # Deploy the upstream Yul C9 verifier (no constructor args). Pulled
    # from the `lib/sphincs-minus/` submodule so bumping the pinned
    # commit is the source-of-truth update path. Yul is stack-deep
    # enough that --via-ir is required.
    paramSet="${2:-C9}"
    if [[ "$paramSet" != "C9" ]]; then
      echo "deploy-verifier: only C9 supported here (upstream Yul source);" >&2
      echo "  other paramSets ship via the on-chain registries upstream documents." >&2
      exit 2
    fi
    require forge
    need_env SEPOLIA_RPC_URL
    pk="$(deployer_private_key)"
    src_path="lib/sphincs-minus/src/SPHINCs-C9Asm.sol"
    if [[ ! -f "$src_path" ]]; then
      echo "missing $src_path — submodule not initialized?" >&2
      echo "  fix: git submodule update --init --recursive lib/sphincs-minus" >&2
      exit 2
    fi
    echo "deploying $src_path:SphincsC9Asm on Sepolia (--via-ir, solc 0.8.28)…" >&2
    out="$(forge create \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$pk" \
      --broadcast \
      --use 0.8.28 \
      --via-ir \
      "$src_path:SphincsC9Asm")"
    echo "$out"
    addr="$(printf '%s\n' "$out" | awk '/Deployed to:/ {print $3}')"
    if [[ -n "$addr" ]]; then
      data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
      dir="${data_home}/leankohaku/sphincs-verifiers"
      mkdir -p "$dir"
      out_file="${dir}/sepolia-${paramSet}.txt"
      printf '%s\n' "$addr" > "$out_file"
      echo "saved verifier address to $out_file"
    else
      echo "warning: could not parse 'Deployed to:' line; check forge output above" >&2
      exit 2
    fi
    ;;

  deploy)
    paramSet="${2:?usage: sphincs_sepolia.sh deploy <paramSet>}"
    require forge
    need_env SEPOLIA_RPC_URL
    need_env SPHINCS_VERIFIER_ADDR
    pk="$(deployer_private_key)"
    cat >&2 <<EOF
deploying lib/sphincs-minus/src/SphincsAccountFactory.sol on Sepolia
  paramSet: ${paramSet}
  entryPoint (v0.9): ${ENTRY_POINT_V09}
  verifier: ${SPHINCS_VERIFIER_ADDR}
EOF
    out="$(forge create \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$pk" \
      --broadcast \
      --use 0.8.28 \
      lib/sphincs-minus/src/SphincsAccountFactory.sol:SphincsAccountFactory \
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

  deploy-all)
    # End-to-end: verifier (upstream Yul) → factory (local Dev). Useful
    # after a `git submodule update` that pulls a new verifier patch.
    "$0" deploy-verifier "${2:-C9}" || exit $?
    data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    new_verifier="$(cat "${data_home}/leankohaku/sphincs-verifiers/sepolia-${2:-C9}.txt" 2>/dev/null)"
    if [[ -z "$new_verifier" ]]; then
      echo "deploy-all: verifier address not captured; aborting before factory deploy" >&2
      exit 2
    fi
    SPHINCS_VERIFIER_ADDR="$new_verifier" "$0" deploy "${2:-C9}" || exit $?
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
sphincs_sepolia.sh deploy-verifier [paramSet=C9]
  # Forge-creates the upstream Yul verifier from
  #   lib/sphincs-minus/src/SPHINCs-C9Asm.sol  (submodule)
  # Saves the address to \$XDG_DATA_HOME/leankohaku/sphincs-verifiers/sepolia-<paramSet>.txt

sphincs_sepolia.sh deploy <paramSet>
  # Forge-creates the upstream SphincsAccountFactory from
  #   lib/sphincs-minus/src/SphincsAccountFactory.sol
  # wiring (EntryPoint v0.9 singleton, \$SPHINCS_VERIFIER_ADDR).
  # Saves to \$XDG_DATA_HOME/leankohaku/sphincs-factories/sepolia-<paramSet>.txt

sphincs_sepolia.sh deploy-all [paramSet=C9]
  # verifier → factory back-to-back. Use after a submodule bump.

sphincs_sepolia.sh address <paramSet>
  # Echoes the last-recorded factory address for paramSet on sepolia.
USAGE
    ;;
esac
