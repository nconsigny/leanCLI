# CLI

The CLI is the primary wallet surface and is a **thin JSON-RPC forwarder**
to the daemon. It must not talk directly to Ethereum nodes, indexers,
analytics, price feeds, fiat/onramp APIs, metadata services, crash-report
services, or peer-discovery services. State-bearing operations
(default-account file, account formatting, preflight policy check) live
daemon-side; the CLI calls `account.getDefault` / `account.setDefault` /
`account.list` / `daemon.preflight` and pretty-prints the response.
Interactive prompts (e.g. the Y/N after `wallet create r1`) intentionally
remain CLI-side.

For the bundled TUI:

```bash
leancli tui
```

See the [Daemon RPC catalog](./DAEMON.md) for the full method list.

## Commands

```bash
leancli help
leancli version
leancli privacy
leancli network
leancli security
leancli doctor
leancli rpc-methods
```

Policy inspection:

```bash
leancli policy-check strict configured-node broadcast-tx direct
leancli policy-check tor configured-node node-read tor
leancli rpc-check strict configured direct eth_getBalance
leancli rpc-check tor configured tor eth_sendRawTransaction
leancli endpoint-check strict local http loopback false
leancli endpoint-check tor configured onion tor false
leancli decode erc20 0xa9059cbb...
```

Daemon-backed chain operations:

```bash
leancli balance 0x0000000000000000000000000000000000000000
leancli nonce 0x0000000000000000000000000000000000000000
leancli gas-price
leancli priority-fee
leancli estimate-gas '{"to":"0x0000000000000000000000000000000000000000","value":"0x1"}'
leancli broadcast 0x...
```

These commands validate inputs locally, then call the daemon over the Unix
socket. If the socket is missing and systemd socket activation is not present,
the CLI auto-spawns `leancli-daemon` unless `LEANCLI_NO_AUTOSPAWN=1` is
set. Invalid inputs exit with code `2` before any daemon or network path is
attempted.

Daemon wallet send:

```bash
leancli daemon help
leancli daemon daily send sepolia 0xAa651C04bfE4F302eE243D6638d3B91389C4C02C 0.002
```

This is the preferred user-facing send path. It takes ETH units, computes
the R1 account digest, requires local TPM/fingerprint signing, and then
broadcasts the R1 account `execute` transaction on Sepolia.

EOA runtime signing requires HACL Packages helpers:

```bash
sudo apt install git cmake ninja-build gcc
./script/setup_hacl.sh
```

EOA send:

```bash
leancli eoa create daily
leancli eoa unlock daily
leancli eoa send daily 0x0000000000000000000000000000000000000000 1
```

`eoa send` gets nonce, fees, and gas through the daemon, signs an EIP-1559
transaction inside the daemon, then broadcasts the raw transaction.

## ENS resolution

ENS names are canonical on mainnet, so `leancli resolve <name>` always queries
mainnet ENS regardless of the wallet's operating chain. Configure a mainnet
RPC explicitly — there is no default and no fallback to the operating-chain
RPC; if unset, resolution fails with JSON-RPC error `-32030`.

```bash
leancli network set-ens-rpc "$MAINNET_RPC_URL"   # one-time
leancli resolve vitalik.eth
leancli network unset-ens-rpc                    # remove
```

The same value can be supplied via the `LEANCLI_ENS_RPC_URL` environment
variable or the `ens_rpc_url` field in `daemon.json`.

## Regression Check

```bash
./script/check_privacy_cli.sh
./script/check_daemon_config.sh
./script/check_m10_autospawn.sh
./script/check_m8_chain_rpc.sh
```

These scripts build the project, check representative allow/deny paths, verify
daemon auto-spawn, and exercise chain RPC plus `eoa.send` against Anvil.
