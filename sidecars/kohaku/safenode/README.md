# leancli-safenode-bridge

TEE-attested oblivious-RPC proxy. Sits *upstream* of helios in the
verified-read pipeline and gives leanCLI two properties that plain RPC
can't:

- **Privacy** — the upstream is an ORAM server
  (`obliviouslabs/oblivious_node`), so a fully passive observer of the
  server cannot tell which storage slot or account you're querying.
- **Integrity** — the upstream TLS certificate is bound into a TEE
  attestation. This sidecar verifies the attestation at boot and pins
  the attested public key for every outbound HTTPS request. A
  publicly-trusted-but-not-the-enclave certificate is rejected.

Two attestation modes, matching upstream's two deployment targets
(`deploy/README.md` in `obliviouslabs/oblivious_node`):

| Mode | Deployment | What is verified | Needs Rust verifier? |
|---|---|---|---|
| `gcp` | GCP Confidential Space (current, `rpc-gcp.safe-node.com`) | Google-signed OIDC token: audience, nonce bound to the served TLS cert + fresh challenge, `hwmodel=GCP_INTEL_TDX`, secure boot, debug disabled since boot, STABLE image, expected OCI **image digest**, entrypoint, env launch policy | **No** — pure Node |
| `phala` | Phala/dstack TDX CVM (original, `rpc.safe-node.com`) | Raw TDX quote over `domain + sha256(cert) + challenge`, RTMR3 replay from event log, compose-hash | Yes (`tdx_quote_verifier`) |

Mode selection: `LEANCLI_SAFE_NODE_ATTESTATION=gcp|phala` wins;
otherwise `gcp` when `LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST` is set, else
`phala`. Either way the sidecar refuses to start if attestation fails,
and — if `LEANCLI_SAFE_NODE_EXPECTED_PIN` is set — if the freshly
attested pin differs from the operator-published one.

This sidecar does **not** replace helios's consensus verification.
Helios still parses every `eth_getProof` response and verifies the
Merkle proof against the sync-committee-attested state root. Safe-node
changes *where* proofs come from; it does not let the daemon trust
the proofs without verifying them.

## Split-routing (what travels safe-node vs. what doesn't)

The upstream safe-node application implements **only `eth_getProof`** on
its `/json_rpc` endpoint — every other method returns
`-32601 Method not found`. So the proxy can't dumbly forward all of
helios's traffic to it.

Instead, the sidecar splits routes by JSON-RPC method:

- **`eth_getProof` → safe-node** (TDX-pinned channel, ORAM upstream).
  This is the only method that reveals which address/slot the caller
  cares about, so it's the only one whose obliviousness matters.
- **Everything else → a non-pinned Sepolia RPC** (configurable via
  `LEANCLI_SAFE_NODE_FALLBACK_RPC`, defaults to
  `https://ethereum-sepolia-rpc.publicnode.com`). These are
  `eth_chainId`, `eth_getBlockByNumber`, `eth_getCode`, `eth_call`,
  `eth_estimateGas`, etc. — block-header and chain-metadata calls that
  reveal no address-level intent.

Privacy posture: an observer of the fallback RPC sees block headers
and chain metadata; they do **not** see which addresses or storage
slots we accessed (those went via safe-node's ORAM channel). An
observer of safe-node sees encrypted ORAM traffic with no useful
selectors. The two observers cannot collude meaningfully because the
queries are partitioned by sensitivity.

## Backfill retry policy

Safe-node's `eth_getProof` returns `-32001 "Failed due to data non
availability"` on a cache miss and queues a backfill in the
background. Per the upstream docs, retrying shortly afterward usually
lands. The sidecar retries with exponential backoff: **800 ms, 1.6 s,
3.2 s** (4 attempts total, ~5.6 s worst case). If the proof still
isn't materialized, the `-32001` is returned to the caller verbatim —
helios will surface it and the daemon can decide whether to fail the
simulate or retry the whole flow.

Note on the GCP deployment's startup behavior (per the operator):
JSON-RPC answers immediately after deploy — a seed feeder loads roots,
follows live blocks, and serves request-driven backfill through an
upstream Sepolia RPC while the local reth/lighthouse pair syncs in the
background. Proactive witness/node sync (from block 11,080,000) only
starts once local reth finishes its execution stage, which takes days
on a fresh deployment — expect more `-32001` backfills until then.

## Prerequisite (phala mode only): the Rust TDX quote verifier

GCP mode needs **no external binary** — the Confidential Space token is
verified in pure Node against Google's JWKS.

For phala mode, the TDX quote-parsing logic lives in a companion Rust
binary, `tdx_quote_verifier`, in `obliviouslabs/tdx_easy_https`
(vendored into `oblivious_node` as the `external/tdx_easy_https`
submodule). We do **not** redistribute it. You must either:

1. Build it from the upstream source and export its path:

   ```bash
   git clone --recurse-submodules https://github.com/obliviouslabs/oblivious_node /tmp/oblivious_node
   (cd /tmp/oblivious_node/external/tdx_easy_https/tdx_quote_verifier && cargo build --release)
   export TDX_QUOTE_VERIFIER_BIN=/tmp/oblivious_node/external/tdx_easy_https/tdx_quote_verifier/target/release/tdx_quote_verifier
   ```

2. Or install it system-wide and unset `TDX_QUOTE_VERIFIER_BIN` — the
   vendored `verify_client_tdx.mjs` will fall back to `cargo run` from
   the working tree (only useful if you cloned the upstream repo).

Without this binary phala-mode attestation fails and the sidecar
refuses to start (which is the correct outcome — we never let an
unattested ORAM server proxy reads).

## Running standalone (GCP Confidential Space — current deployment)

```bash
export LEANCLI_SAFE_NODE_URL="https://rpc-gcp.safe-node.com"
export LEANCLI_SAFE_NODE_API_KEY="olabs-api-…"                # from the operator
# Attestation anchors, published by the operator per release:
export LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST="sha256:61aa4c551e8327459c38b152695193003e789d55844a21ab1b1d35b031906282"
export LEANCLI_SAFE_NODE_GCP_AUDIENCE="safe-node:rpc-gcp.safe-node.com"   # optional; this is the default
export LEANCLI_SAFE_NODE_EXPECTED_PIN='sha256//BoHHay/wHtVESvf+Bh2MKh4A3wwAnRg47MZPE3tn1fU='  # optional cross-check
# Optional: pin parts of the attested env launch policy (comma-sep NAME=VALUE):
# export LEANCLI_SAFE_NODE_GCP_ENV="ETH_NETWORK=sepolia,SEED_RETH_RPC_URL=https://sepolia.drpc.org"

node bridge.mjs --listen /tmp/safenode.sock
```

The audience/digest/pin values above are the current GCP dev
deployment's; when the operator publishes a new image, update
`LEANCLI_SAFE_NODE_GCP_IMAGE_DIGEST` (and the pin, which rotates with
ACME finalization — re-derive it via attestation rather than trusting
a stale value).

## Running standalone (Phala/dstack — original deployment)

```bash
export LEANCLI_SAFE_NODE_URL="https://rpc.safe-node.com"
export LEANCLI_SAFE_NODE_API_KEY="olabs-api-…"
export LEANCLI_SAFE_NODE_ATTESTATION=phala                   # or just leave GCP_IMAGE_DIGEST unset
export LEANCLI_SAFE_NODE_DOMAIN="rpc.safe-node.com"          # optional; defaults to URL hostname
export LEANCLI_SAFE_NODE_PCCS_URL="https://…"               # optional; PCCS for the Rust verifier
export TDX_QUOTE_VERIFIER_BIN=/path/to/tdx_quote_verifier

node bridge.mjs --listen /tmp/safenode.sock
```

On success the sidecar prints two lines to stderr:

```
[safenode] proxy on http://127.0.0.1:<port> → https://rpc-gcp.safe-node.com (domain=rpc-gcp.safe-node.com)
[safenode] attested TLS pin = sha256//…
```

The HTTP URL is what you point helios's `executionRpc` at. The user
API key never leaves this process.

## Running from the daemon

The wallet daemon spawns this sidecar automatically when
`LEANCLI_SAFE_NODE_URL` is set in its environment. For a systemd
install, put the env in `~/.config/leancli/daemon.env` (the unit's
`EnvironmentFile=`) and restart the daemon — shell exports are NOT
seen by a systemd-managed daemon.

There is no `leancli` subcommand for these yet; drive the daemon RPCs
over the UDS directly (or use the `o` toggle on the TUI dashboard's
settings pane):

```bash
sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/leancli/leancli.sock"
rpc() { python3 -c '
import json,socket,sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall((json.dumps({"jsonrpc":"2.0","id":1,"method":sys.argv[2],
  "params":json.loads(sys.argv[3])})+"\n").encode())
buf=b""
while b"\n" not in buf: buf+=s.recv(65536)
print(buf.decode())' "$sock" "$@"; }

# Status (attestation mode, pin, image digest / MRTD / RTMR3, proxy URL)
rpc daemon.safeNode.status '{}'

# Re-run the attestation flow (refreshes the pin if the enclave rotated
# certs; refuses to update on a verification failure).
rpc daemon.safeNode.verify '{}'

# Disable/re-enable at runtime
rpc daemon.safeNode.toggle '{"enable": false}'
rpc daemon.safeNode.toggle '{"enable": true}'
```

When safe-node is enabled, the daemon transparently substitutes the
local proxy URL for `executionRpc` on every helios call. No other code
path changes — `tx.simulate`, `tx.simulateHelios`, and `eth.proxyHelios`
all keep working with their existing parameter shapes.

## Chain scope

Only `chainId=1` (mainnet) and `chainId=11155111` (sepolia) are
supported in v1. The dev safe-node deployment caps its ORAM at 1M
nodes on a 16GB CVM and is sized for Sepolia; mainnet pressure is
untested. Other chains fall through to plain helios (or whatever
`daemon.readBackend` you have configured).
