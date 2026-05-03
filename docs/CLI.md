# CLI

The CLI is the primary wallet surface. It must not talk directly to
Ethereum nodes, indexers, analytics, price feeds, fiat/onramp APIs,
metadata services, crash-report services, or peer-discovery services.

## Commands

```bash
leankohaku help
leankohaku version
leankohaku privacy
leankohaku network
leankohaku security
leankohaku doctor
leankohaku rpc-methods
```

Policy inspection:

```bash
leankohaku policy-check strict configured-node broadcast-tx direct
leankohaku policy-check tor configured-node node-read tor
leankohaku rpc-check strict configured direct eth_getBalance
leankohaku rpc-check tor configured tor eth_sendRawTransaction
leankohaku endpoint-check strict local http loopback false
leankohaku endpoint-check tor configured onion tor false
leankohaku decode erc20 0xa9059cbb...
```

Daemon-backed chain operations:

```bash
leankohaku balance 0x0000000000000000000000000000000000000000
leankohaku nonce 0x0000000000000000000000000000000000000000
leankohaku gas-price
leankohaku priority-fee
leankohaku estimate-gas '{"to":"0x0000000000000000000000000000000000000000","value":"0x1"}'
leankohaku broadcast 0x...
```

These commands validate inputs locally, then call the daemon over the Unix
socket. If the socket is missing and systemd socket activation is not present,
the CLI auto-spawns `leankohaku-daemon` unless `LEANKOHAKU_NO_AUTOSPAWN=1` is
set. Invalid inputs exit with code `2` before any daemon or network path is
attempted.

Daemon wallet send:

```bash
leankohaku daemon help
leankohaku daemon daily send sepolia 0xAa651C04bfE4F302eE243D6638d3B91389C4C02C 0.002
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
leankohaku eoa create daily
leankohaku eoa unlock daily
leankohaku eoa send daily 0x0000000000000000000000000000000000000000 1
```

`eoa send` gets nonce, fees, and gas through the daemon, signs an EIP-1559
transaction inside the daemon, then broadcasts the raw transaction.

## ENS resolution

ENS names are canonical on mainnet, so `kohaku resolve <name>` always queries
mainnet ENS regardless of the wallet's operating chain. Configure a mainnet
RPC explicitly — there is no default and no fallback to the operating-chain
RPC; if unset, resolution fails with JSON-RPC error `-32030`.

```bash
kohaku network set-ens-rpc "$MAINNET_RPC_URL"   # one-time
kohaku resolve vitalik.eth
kohaku network unset-ens-rpc                    # remove
```

The same value can be supplied via the `LEANKOHAKU_ENS_RPC_URL` environment
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
