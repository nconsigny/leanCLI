# leankohaku-safenode-bridge

TDX-attested oblivious-RPC proxy. Sits *upstream* of helios in the
verified-read pipeline and gives Kohaku two properties that plain RPC
can't:

- **Privacy** — the upstream is an ORAM server
  (`obliviouslabs/oblivious_node`), so a fully passive observer of the
  server cannot tell which storage slot or account you're querying.
- **Integrity** — the upstream TLS certificate is bound into a TDX
  quote. This sidecar verifies the quote at boot and pins the
  attested public key for every outbound HTTPS request. A
  publicly-trusted-but-not-the-enclave certificate is rejected.

This sidecar does **not** replace helios's consensus verification.
Helios still parses every `eth_getProof` response and verifies the
Merkle proof against the sync-committee-attested state root. Safe-node
changes *where* proofs come from; it does not let the daemon trust
the proofs without verifying them.

## Prerequisite: the Rust TDX quote verifier

The TDX quote-parsing logic lives in a companion Rust binary,
`tdx_quote_verifier`, vendored in `obliviouslabs/oblivious_node` at
`deploy/phala/tdx_quote_verifier/`. We do **not** redistribute it.
You must either:

1. Build it from the upstream source and export its path:

   ```bash
   git clone https://github.com/obliviouslabs/oblivious_node /tmp/oblivious_node
   (cd /tmp/oblivious_node/deploy/phala/tdx_quote_verifier && cargo build --release)
   export TDX_QUOTE_VERIFIER_BIN=/tmp/oblivious_node/deploy/phala/tdx_quote_verifier/target/release/tdx_quote_verifier
   ```

2. Or install it system-wide and unset `TDX_QUOTE_VERIFIER_BIN` — the
   vendored `verify_client_tdx.mjs` will fall back to `cargo run` from
   the working tree (only useful if you cloned the upstream repo).

Without this binary the sidecar will fail to attest the enclave and
will refuse to start (which is the correct outcome — we never let an
unattested ORAM server proxy reads).

## Running standalone

```bash
export KOHAKU_SAFE_NODE_URL="https://rpc.safe-node.com"
export KOHAKU_SAFE_NODE_API_KEY="olabs-api-…"
export KOHAKU_SAFE_NODE_DOMAIN="rpc.safe-node.com"          # optional; defaults to URL hostname
export KOHAKU_SAFE_NODE_PCCS_URL="https://…"               # optional; PCCS for the Rust verifier
export TDX_QUOTE_VERIFIER_BIN=/path/to/tdx_quote_verifier

node bridge.mjs --listen /tmp/safenode.sock
```

On success the sidecar prints two lines to stderr:

```
[safenode] proxy on http://127.0.0.1:<port> → https://rpc.safe-node.com (domain=rpc.safe-node.com)
[safenode] attested TLS pin = sha256//…
```

The HTTP URL is what you point helios's `executionRpc` at. The user
API key never leaves this process.

## Running from the daemon

The wallet daemon spawns this sidecar automatically when
`KOHAKU_SAFE_NODE_URL` is set in its environment. Operator commands:

```bash
# Status (proxy URL, attested pin, MRTD, RTMR3, ...)
leankohaku rpc daemon.safeNode.status

# Re-run the TDX verify flow (refreshes the pin if the enclave rotated
# certs; refuses to update on a verification failure).
leankohaku rpc daemon.safeNode.verify

# Disable/re-enable at runtime
leankohaku rpc daemon.safeNode.toggle '{"enable": false}'
leankohaku rpc daemon.safeNode.toggle '{"enable": true}'
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
