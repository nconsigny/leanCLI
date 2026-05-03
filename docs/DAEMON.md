# Daemon

`leankohaku-daemon` is the only runtime process that performs wallet signing,
keystore access, and Ethereum node RPC. The CLI is a thin JSON-RPC client over a
local Unix-domain socket.

## Socket

Default path:

```text
${XDG_RUNTIME_DIR:-/tmp}/leankohaku/leankohaku.sock
```

Override with:

```bash
LEANKOHAKU_SOCKET=/path/to/leankohaku.sock
```

The daemon creates the parent directory when it binds the socket. For systemd
socket activation it accepts inherited fd `3` when `LISTEN_FDS=1`; in that mode
systemd owns the socket file lifecycle.

## Bootstrap

Preferred user service:

```bash
systemctl --user enable --now leankohaku.socket
```

Fallback behavior:

- CLI daemon-backed commands auto-spawn `leankohaku-daemon` when the socket is
  missing.
- Set `LEANKOHAKU_NO_AUTOSPAWN=1` to disable fallback spawning.
- `leankohaku daemon` starts the daemon in the foreground.

## Configuration

The daemon reads JSON config from:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/leankohaku/daemon.json
```

Override the config path with `LEANKOHAKU_CONFIG`.

Example:

```json
{
  "socket_path": "/run/user/1000/leankohaku/leankohaku.sock",
  "chain_id": 1,
  "rpc_url": "http://127.0.0.1:8545",
  "rpc_transport": "loopback",
  "ens_rpc_url": "https://mainnet.example/eth",
  "network_policy": "strict"
}
```

Environment variables override file values:

```bash
LEANKOHAKU_SOCKET=/run/user/1000/leankohaku/leankohaku.sock
LEANKOHAKU_RPC_URL=http://127.0.0.1:8545
LEANKOHAKU_RPC_TRANSPORT=loopback
LEANKOHAKU_CHAIN_ID=1
LEANKOHAKU_NETWORK_POLICY=strict
LEANKOHAKU_ENS_RPC_URL=https://mainnet.example/eth
```

`ens_rpc_url` (env `LEANKOHAKU_ENS_RPC_URL`; aliases `ensRpcUrl`,
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

## Methods

Daemon:

- `daemon.ping`
- `daemon.version`
- `daemon.shutdown`

TPM/R1 compatibility:

- `tpm.create` (chain-agnostic R1 key creation)
- `tpm.deploy` (params: `name`, `chain` ∈ {`sepolia`, `mainnet`})
- `tpm.createSepolia` (DEPRECATED alias for `tpm.create`)
- `tpm.listSepolia`
- `tpm.signSepolia`
- `r1.sendSepolia`
- `r1.sendEthSepolia`

Chain RPC:

- `chain.balance`
- `chain.nonce`
- `chain.gasPrice`
- `chain.maxPriorityFeePerGas`
- `chain.estimateGas`
- `chain.tokenBalance`
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
- `eoa.send`
- `eoa.delete`

Shielded bridge:

- `shielded.ping`

## Regression Checks

```bash
./script/check_m6_keystore_daemon.sh
./script/check_daemon_config.sh
./script/check_m10_autospawn.sh
./script/check_m8_chain_rpc.sh
```
