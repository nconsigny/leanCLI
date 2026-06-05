# Security

leanCLI uses a daemon boundary: the CLI parses arguments and talks to a
local Unix-domain socket; the daemon owns key access, signing, and Ethereum RPC.

## Trust Boundary

The **verified Lean core** is what we trust. Everything reached over a
process boundary — sidecars, Kohaku plugins, light-client backends, the LLM
agent, and node RPC — is **untrusted**: its output is input to be
re-validated, never authority to act on. No signing decision depends on what
a sidecar reports. Every produced calldata is re-decoded in Lean and routed
through `tx.decodeIntent → tx.simulate → ConfirmGate` before any key touches
it; the user's confirmation at `ConfirmGate` is the trust anchor, not a
simulation result or a plugin's claim.

Trusted runtime components (the narrow boundary the core does rely on):

- HACL helpers for hash, HMAC, KDF, and AEAD operations.
- RustCrypto `ripemd` helper for BIP-32 HASH160 fingerprints (HACL does not
  expose RIPEMD-160).
- Bitcoin Core `libsecp256k1` helpers for k1 signing, verification, recovery,
  and public key derivation.
- Linux kernel RNG through `/dev/urandom`.
- Linux Unix-domain sockets and same-uid peer credentials.
- Local TPM2 tooling for wallet master-KEK custody (PIN-bound), not an
  account-signing path.

Lean code orchestrates BIP-39/32/44, transaction framing, JSON/RLP encoding,
daemon dispatch, policy checks, and address derivation framing. It does not
reimplement production secp256k1 or hash primitives. See
[`docs/CRYPTO_POLICY.md`](./docs/CRYPTO_POLICY.md) for the
one-library-per-primitive pins.

## Plugin supply chain

Privacy and provider plugins are hosted under the Kohaku model (see
[`docs/PLUGIN_ARCHITECTURE.md`](./docs/PLUGIN_ARCHITECTURE.md)). The stance
is defense-in-depth against a malicious dependency tree:

- **Pinned.** Every `@kohaku-eth/*` package and its transitive
  `@kohaku-eth/provider` transport wrapper is version-locked with sha512
  subresource-integrity hashes in `sidecars/kohaku/package-lock.json`
  (`npm ci` fails on a tampered tarball). A human-auditable summary of the
  same versions + integrity hashes is mirrored in
  `sidecars/kohaku/plugins.lock.json`.
- **Dynamic-imported only when flag-enabled.** A plugin's code is
  `import()`-ed only after the `LEANCLI_PRIVACY` allow-list confirms it is
  enabled; a `shielded.*` call for a disabled plugin is refused before its
  code loads. The default privacy set is empty.
- **Treated as malicious regardless.** Even a correctly-pinned, enabled
  plugin is untrusted: its output flows through the standard pre-sign
  pipeline and its network egress is policy-gated (below). "It's shielded"
  grants no signing authority.

## Key Custody

EOA mnemonic storage is encrypted on disk under XDG data directories. The daemon
is the only process that decrypts slots and keeps unlocked seeds in memory. The
CLI does not import wallet, crypto, keystore, daemon, or outbound RPC modules;
`ops/scripts/check_cli_isolation.sh` enforces this.

Passphrases are sent to the daemon over the local same-user socket. They are not
logged. The current Lean runtime does not provide guaranteed zeroization for
managed memory, so unlocked seed lifetime is bounded by daemon state TTL rather
than claimed memory erasure.

## Network Policy

The deny-by-default policy (`LeanCli.Network.Policy`) is enforced before
outbound RPC:

- CLI direct node access is denied by structure.
- Strict daemon mode allows local loopback provider access.
- Configured-node traffic requires explicit Tor policy.
- Third-party purposes (price quotes, indexer/metadata lookups, peer
  discovery) are denied under strict policy.
- **No shielded egress without policy permission (invariant 5.7).** Every
  shielded method is classified to a network purpose, and a policy-denied
  shielded request is refused inside `LeanCli.Privacy.Bridge.callGated`
  **before** the sidecar is spawned — so a shielded operation cannot reach
  the network when the policy refuses it. Proved in
  `LeanCli/Invariants/Bridge.lean`.

## Local Socket Model

The daemon listens on a Unix-domain socket and rejects peers whose kernel
credential uid does not match the daemon uid. This is a same-user local trust
model, not a multi-user authorization system.

There is no TCP daemon transport in v1.

## Reporting

This repository is still pre-release. Do not store production funds until the
native helper pins, packaging, and integration tests have been reviewed on the
target platform.
