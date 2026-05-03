# Security

leanKohaku uses a daemon boundary: the CLI parses arguments and talks to a
local Unix-domain socket; the daemon owns key access, signing, and Ethereum RPC.

## Trust Boundary

Trusted runtime components:

- HACL helpers for hash, HMAC, KDF, DRBG, and AEAD operations.
- RustCrypto `ripemd` helper for BIP-32 HASH160 fingerprints.
- Bitcoin Core `libsecp256k1` helpers for k1 signing, verification, recovery,
  and public key derivation.
- Linux kernel RNG through `/dev/urandom`.
- Linux Unix-domain sockets and same-uid peer credentials.
- Local TPM2 tooling for R1/Sepolia compatibility flows.

Lean code orchestrates BIP-39/32/44, transaction framing, JSON/RLP encoding,
daemon dispatch, policy checks, and address derivation framing. It does not
reimplement production secp256k1 or hash primitives.

## Key Custody

EOA mnemonic storage is encrypted on disk under XDG data directories. The daemon
is the only process that decrypts slots and keeps unlocked seeds in memory. The
CLI does not import wallet, crypto, keystore, daemon, or outbound RPC modules;
`script/check_cli_isolation.sh` enforces this.

Passphrases are sent to the daemon over the local same-user socket. They are not
logged. The current Lean runtime does not provide guaranteed zeroization for
managed memory, so unlocked seed lifetime is bounded by daemon state TTL rather
than claimed memory erasure.

## Network Policy

The deny-by-default policy is enforced before outbound RPC:

- CLI direct node access is denied by structure.
- Strict daemon mode allows local loopback provider access.
- Configured-node traffic requires explicit Tor policy.
- Third-party analytics, crash reporting, metadata, indexers, price APIs, and
  fiat/onramp APIs are denied surfaces.

## Local Socket Model

The daemon listens on a Unix-domain socket and rejects peers whose kernel
credential uid does not match the daemon uid. This is a same-user local trust
model, not a multi-user authorization system.

There is no TCP daemon transport in v1.

## Reporting

This repository is still pre-release. Do not store production funds until the
native helper pins, packaging, and integration tests have been reviewed on the
target platform.
