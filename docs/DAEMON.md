# Daemon

`leancli-daemon` is the only runtime process that performs wallet signing,
keystore access, and Ethereum node RPC. The CLI is a thin JSON-RPC client over a
local Unix-domain socket.

## Socket

Default path:

```text
${XDG_RUNTIME_DIR:-/tmp}/leancli/leancli.sock
```

Override with:

```bash
LEANCLI_SOCKET=/path/to/leancli.sock
```

The daemon creates the parent directory when it binds the socket. For systemd
socket activation it accepts inherited fd `3` when `LISTEN_FDS=1`; in that mode
systemd owns the socket file lifecycle.

## Bootstrap

Preferred user service:

```bash
systemctl --user enable --now leancli.socket
```

Fallback behavior:

- CLI daemon-backed commands auto-spawn `leancli-daemon` when the socket is
  missing.
- Set `LEANCLI_NO_AUTOSPAWN=1` to disable fallback spawning.
- `leancli daemon` starts the daemon in the foreground.

## Configuration

The daemon reads JSON config from:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/leancli/daemon.json
```

Override the config path with `LEANCLI_CONFIG`.

Example:

```json
{
  "socket_path": "/run/user/1000/leancli/leancli.sock",
  "chain_id": 1,
  "rpc_url": "http://127.0.0.1:8545",
  "rpc_transport": "loopback",
  "ens_rpc_url": "https://mainnet.example/eth",
  "network_policy": "strict"
}
```

Environment variables override file values:

```bash
LEANCLI_SOCKET=/run/user/1000/leancli/leancli.sock
LEANCLI_RPC_URL=http://127.0.0.1:8545
LEANCLI_RPC_TRANSPORT=loopback
LEANCLI_CHAIN_ID=1
LEANCLI_NETWORK_POLICY=strict
LEANCLI_ENS_RPC_URL=https://mainnet.example/eth
```

`ens_rpc_url` (env `LEANCLI_ENS_RPC_URL`; aliases `ensRpcUrl`,
`mainnet_rpc_url`, `mainnetRpcUrl`) must point at a mainnet RPC. ENS names are
canonical on mainnet, so resolution always queries mainnet (chainId 1)
regardless of the wallet's operating chain. If unset, `chain.resolveName`
returns JSON-RPC error code `-32030` with no fallback to `rpc_url`.

`strict` policy allows local loopback node reads and raw transaction broadcast.
Configured-node access belongs behind explicit Tor policy.

## JSON-RPC

Requests and responses are JSON-RPC 2.0 objects, one request per socket
connection. Standard errors are used where possible:

- `-32700` parse error
- `-32600` invalid request
- `-32601` method not found
- `-32602` invalid params
- `-32603` internal error

Daemon-specific errors currently include:

- `-32010` EOA slot not found
- `-32011` EOA unlock failed
- `-32012` EOA slot locked
- `-32013` EOA signing failed
- `-32020` chain RPC failed
- `-32021` unknown chain (chain key missing from `chainEndpoints`)
- `-32030` ENS resolution: no `ens_rpc_url` configured
- `-32043` TPM sign failed (e.g. fprintd biometric verification failed)

## Methods

Daemon:

- `daemon.ping`
- `daemon.version`
- `daemon.shutdown`
- `daemon.preflight` — params `{method: "balance"|"send", address?, to?, amountWei?}` → `{ok, summary, plan}`. The CLI's `printPreflight` is a thin wrapper.

Account-state (workstation-local, owned by daemon — file lives at `$XDG_CONFIG_HOME/leancli/default-account.txt`):

- `account.getDefault` → `{name: string|null}`
- `account.setDefault` (params `{name}`) → `{ok, name}`
- `account.clearDefault` → `{ok: true}`
- `account.list` → `{accounts: [{type: "eoa"|"tpm", name, address, indices?}]}` — single unified view used by the TUI's wallet list and CLI completion helpers.

TPM/R1 compatibility:

- `tpm.create` (chain-agnostic R1 key creation)
- `tpm.deploy` (params: `name`, `chain` ∈ {`sepolia`, `mainnet`})
- `tpm.createSepolia` (DEPRECATED alias for `tpm.create`)
- `tpm.listSepolia`
- `tpm.listSepoliaAddresses`
- `tpm.signSepolia`
- `r1.sendSepolia`
- `r1.sendEthSepolia`

Chain RPC (all policy-gated through `Privacy.NetworkPolicy`):

- `chain.balance`
- `chain.nonce`
- `chain.gasPrice`
- `chain.maxPriorityFeePerGas`
- `chain.estimateGas`
- `chain.tokenBalance`
- `chain.ethCall` — general policy-gated `eth_call` (params `{to, data, block?, chain?}`). Used by the LLM sidecar's read tools (`get_aave_health_factor`, `get_uniswap_v3_quote`, `get_morpho_blue_position`); any future protocol-read tool should encode calldata via viem and route through here.
- `chain.sendRawTransaction`

EOA:

- `eoa.list`
- `eoa.show`
- `eoa.address`
- `eoa.import`
- `eoa.create`
- `eoa.unlock`
- `eoa.lock`
- `eoa.derive`
- `eoa.signDigest`
- `eoa.signMessage`
- `eoa.signTx`
- `eoa.signTypedData`
- `eoa.send`
- `eoa.delete`
- `eoa.account.{list,add,rm}`

Sidecar bridges (all policy-gated; one-shot spawn per call):

- `shielded.*` — Privacy Pools / Railgun (`bridge/`).
- `clearsign.ping`
- `tx.decodeIntent` — params `{chainId, to, value, data, from?}` → ERC-7730 descriptor walker. Daemon prefetches ERC-20 metadata for the `to` address and threads it into the bridge call as `tokenMetadata` so amount fields render with real decimals + ticker. Falls back to a bundled 4byte dictionary when no descriptor matches.
- `eip712.decodeIntent` — params `{chainId, domain, types, primaryType, message}` → walks `display.formats[encodeType]` for the matching descriptor (e.g. CowSwap order). Daemon prefetches token metadata for any address-shaped fields in `message`.
- `tx.simulate` — params `{chainId?, from?, to, value?, data, block?, chain?, trace?}` → `{ok, block, tx, returnData?, revertReason?, gasEstimate?, gasEstimateError?, trace?, traceUnavailable?, tokenMetadata?}`. With `trace: true` the daemon runs `debug_traceCall` (`callTracer + withLog`), walks the trace for ERC-20 Transfer events, and prefetches token metadata for every emitting address — TUI's `TransfersBlock` then renders "0.1 USDC" rows.
- `llm.ping`
- `tx.draftFromIntent` — params `{prompt, chainId, fromAddr?}` → `{candidates: [{to, value, data, rationale, confidence, ...}]}`. Sidecar tries a rule-based matcher first; falls through to an Anthropic Claude tool-use loop when `ANTHROPIC_API_KEY` is set in the daemon's env. Every emitted draft must flow through `tx.decodeIntent` + `tx.simulate` + a user-confirm step before signing — the daemon never signs based on this output directly.

## Regression Checks

```bash
./script/check_m6_keystore_daemon.sh
./script/check_daemon_config.sh
./script/check_m10_autospawn.sh
./script/check_m8_chain_rpc.sh
```
