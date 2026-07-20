#!/usr/bin/env bash
# Offline smoke check for the Tornado Cash sidecar path.
#
# Exercises the bridge (sidecars/kohaku/bridge.mjs -> tornado.mjs) directly via
# the one-shot --rpc argv protocol — no daemon, no live RPC, no funded state.
# Validates: the SDK is installed & imports, the LEANCLI_PRIVACY gate, and the
# offline denomination/param validation. Does NOT exercise a live sync/proof
# (that needs a funded Sepolia account and belongs in an integration run).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIDE="$ROOT/sidecars/kohaku"
FAIL=0

run() { node "$SIDE/bridge.mjs" --rpc "$1" 2>/dev/null; }

want() { # want <substring> <json-out> <label>
  case "$2" in
    *"$1"*) printf 'ok   %s\n' "$3" ;;
    *) printf 'FAIL %s\n     wanted substring: %s\n     got: %s\n' "$3" "$1" "$2"; FAIL=1 ;;
  esac
}

echo "== tornado sidecar offline smoke =="

# 0. dependency present
if [ ! -d "$SIDE/node_modules/@kohaku-eth/tornado-cash" ]; then
  echo "FAIL @kohaku-eth/tornado-cash not installed — run 'npm install' in $SIDE"
  exit 1
fi
echo "ok   @kohaku-eth/tornado-cash installed"

# 1. ping (no plugin)
want '"ok":true' "$(run '{"jsonrpc":"2.0","id":1,"method":"ping"}')" "ping"

# 2. catalogue reports tornado live on both chains
out="$(LEANCLI_PRIVACY=tornado run '{"jsonrpc":"2.0","id":2,"method":"listEnabled"}')"
want '"name":"tornado-cash","status":"live"' "$out" "listEnabled: tornado live"
want '"enabled":true' "$out" "listEnabled: tornado enabled"

# 3. enablement gate blocks tornado when not listed
want 'plugin not enabled: tornado' \
  "$(run '{"jsonrpc":"2.0","id":3,"method":"shielded.tornado.prepareDeposit","params":{"amountEth":"0.1"}}')" \
  "gate blocks disabled tornado"

# 4. deposit amount must be a multiple of 0.1 ETH (offline reject)
want 'multiple of 0.1 ETH' \
  "$(LEANCLI_PRIVACY=tornado LEANCLI_CHAIN_ID=11155111 LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":4,"method":"shielded.tornado.prepareDeposit","params":{"amountEth":"0.15"}}')" \
  "deposit rejects non-multiple of 0.1"

# 5. withdraw amount must be exactly one denomination (offline reject)
want 'exactly one pool denomination' \
  "$(LEANCLI_PRIVACY=tornado LEANCLI_CHAIN_ID=1 LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":5,"method":"shielded.tornado.quoteWithdraw","params":{"amountEth":"0.3","recipient":"0x1111111111111111111111111111111111111111","recipientDerivationPath":"m/44\u0027/60\u0027/0\u0027/0/0"}}')" \
  "withdraw rejects non-denomination amount"

# 5b. 10 ETH is a real mainnet pool but NOT deployed on Sepolia — reject per-chain
want 'on chain 11155111 (0.1/1 ETH)' \
  "$(LEANCLI_PRIVACY=tornado LEANCLI_CHAIN_ID=11155111 LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":7,"method":"shielded.tornado.quoteWithdraw","params":{"amountEth":"10","recipient":"0x1111111111111111111111111111111111111111","recipientDerivationPath":"m/44\u0027/60\u0027/0\u0027/0/0"}}')" \
  "withdraw rejects 10 ETH on Sepolia (no such pool)"

# 5c. the same 10 ETH IS a valid denomination on mainnet — it passes the
#     denom gate and proceeds to plugin construction (here it trips the unset
#     storage-path guard, which itself proves the denom gate is chain-aware and
#     did NOT reject 10 ETH on mainnet).
want 'LEANCLI_TC_STORAGE_PATH is required' \
  "$(LEANCLI_PRIVACY=tornado LEANCLI_CHAIN_ID=1 LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":8,"method":"shielded.tornado.quoteWithdraw","params":{"amountEth":"10","recipient":"0x1111111111111111111111111111111111111111","recipientDerivationPath":"m/44\u0027/60\u0027/0\u0027/0/0"}}')" \
  "withdraw accepts 10 ETH denom on mainnet (passes chain-aware gate)"

# 6. withdraw requires a valid recipient (offline reject)
want 'recipient must be' \
  "$(LEANCLI_PRIVACY=tornado LEANCLI_CHAIN_ID=1 LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":6,"method":"shielded.tornado.quoteWithdraw","params":{"amountEth":"0.1","recipient":"nope"}}')" \
  "withdraw rejects bad recipient"

# 7. deterministic EIP-7702 delegation requires a daemon-resolved BIP-44 path
want 'recipientDerivationPath must be a canonical Ethereum BIP-44 path' \
  "$(LEANCLI_PRIVACY=tornado LEANCLI_CHAIN_ID=1 LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":9,"method":"shielded.tornado.quoteWithdraw","params":{"amountEth":"0.1","recipient":"0x1111111111111111111111111111111111111111"}}')" \
  "withdraw requires deterministic delegation path"

# 8. tail calls are validated before any plugin/state work (offline reject)
want 'invalid tail call target' \
  "$(LEANCLI_PRIVACY=tornado LEANCLI_CHAIN_ID=1 LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":10,"method":"shielded.tornado.quoteWithdraw","params":{"amountEth":"0.1","recipient":"0x1111111111111111111111111111111111111111","recipientDerivationPath":"m/44\u0027/60\u0027/0\u0027/0/0","tailCalls":[{"to":"nope","data":"0x"}]}}')" \
  "quote rejects malformed tail call target"

# 8b. tail calls are paymaster-only
want 'only supported in paymaster mode' \
  "$(LEANCLI_PRIVACY=tornado LEANCLI_CHAIN_ID=1 LEANCLI_RPC_URL=http://127.0.0.1:1 \
     run '{"jsonrpc":"2.0","id":11,"method":"shielded.tornado.quoteWithdraw","params":{"amountEth":"0.1","recipient":"0x1111111111111111111111111111111111111111","recipientDerivationPath":"m/44\u0027/60\u0027/0\u0027/0/0","mode":"relayer","tailCalls":[{"to":"0x2222222222222222222222222222222222222222","data":"0x1234"}]}}')" \
  "relayer mode rejects tail calls"

# 9. unit tests (note selection, denomination gates, 7702 delegation options).
#    Run under the same ESM loader bridge.mjs re-execs itself with, matching
#    how these modules load in production.
if node --no-warnings --experimental-loader "$SIDE/loader.mjs" --test \
    "$SIDE/tornado.test.mjs"; then
  echo "ok   unit tests (tornado)"
else
  echo "FAIL unit tests (tornado)"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then echo "== FAILED =="; exit 1; fi
echo "== all tornado sidecar offline checks passed =="
