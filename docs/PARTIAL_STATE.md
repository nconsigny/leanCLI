# Partial state node (StateVault)

The wallet persists the chain state it touches — provenance-tagged and,
where possible, Merkle-proven — so repeated reads stop depending on
third parties. The direction is the inverse of a pruning full node:
instead of "full node → prune some things", the leancli daemon is a
"light client → start remembering some things".

## What is stored

`$XDG_DATA_HOME/leancli/statevault.db` (SQLite, mode 0600, chain data
only — never key material). Disable with `LEANCLI_VAULT=0`; every read
path degrades to exactly the pre-vault behavior when it is off or
broken (vault interaction is strictly best-effort).

| Table | Keyed by | What |
|---|---|---|
| `token_meta` | (chain, addr) | ERC-20 decimals/symbol (immutable) |
| `no_code` | (chain, addr) | negative cache: address has no contract code |
| `code` | (chain, addr) | deployed bytecode |
| `headers` | (chain, **block**) | verified block hash + **state root** pins |
| `accounts` | (chain, addr, **block**) | balance/nonce/storageRoot/codeHash as of that block |
| `storage` | (chain, addr, slot, **block**) | slot value as of that block |

Mutable state is block-keyed by construction: the vault answers "what
did I last verify, and at which block" — never "what is the balance
now". `vault.get` responses carry `block`, `tier`, and `"stale": true`.

## Provenance tiers

Every row records how the value was obtained:

1. `rpc` — direct configured-RPC read, unverified.
2. `consensus` — served by the active light client (helios/colibri),
   Merkle-verified against sync-committee-attested state.
3. `lean` — an `eth_getProof` Merkle-Patricia proof verified **in
   Lean** (`LeanCli/Ethereum/Mpt.lean`) against a consensus-verified
   state root. Strongest tier: the proof step no longer trusts the
   light-client binary — helios only supplies the 32-byte root; any
   untrusted RPC supplies proofs, which can fail to verify but cannot
   lie.

Replacement is no-downgrade (a direct re-read never overwrites a
consensus-verified fact) and tag parsing is fail-safe downward. The
provenance algebra is proved in `LeanCli/Invariants/StateVault.lean`
(INVARIANTS.md Category 16).

## The pin flow (`vault.pin`)

```
vault.pin <addr> [slot ...]
   1. capture head        — eth_getBlockByNumber through the verified
                            backend's runCall directly (NO silent HTTP
                            fallback; an explicit direct fallback is
                            recorded as tier rpc)   → (block N, stateRoot)
   2. eth_getProof        — from the configured RPC, deliberately
                            direct/untrusted (via? = none)
   3. Lean MPT verify     — account proof against stateRoot; storage
                            proofs against the PROVEN storageRoot
   4. store               — accounts/storage rows at exactly block N,
                            tier = pinTier(headTier)  (lean iff the root
                            was consensus-verified)
```

Keccak-256 for proof nodes goes through the native HACL helper
(`leancli-hacl-keccak256`) — the same Cat-13 axiomatized boundary as
every other hash.

## Surfaces

- Daemon RPCs: `vault.status`, `vault.captureHead`, `vault.pin`,
  `vault.get`, `vault.tokens` (`LeanCli/Daemon/Server/VaultRpc.lean`).
- CLI: `leancli vault [status] | head [chain] | pin <addr> [slot ...] |
  get <addr> [chain] | tokens [chain]`.
- Opportunistic capture: the daemon's TokenMeta cache (decimals/symbol
  + negative code cache) now writes through to the vault with the tier
  of the read that produced it, and hydrates from it after a restart.
- The helios sidecar additionally exposes `head.info` (verified head
  header incl. stateRoot) for external callers.

## Trust posture

Nothing served from the vault gates a signature. The pre-sign pipeline
(`tx.decodeIntent → tx.simulate → ConfirmGate`) runs against fresh
verified state exactly as before; the vault is a display / offline /
prefetch tier. Structurally, no signing module imports
`Daemon.StateVault` (INVARIANTS.md 16.5).

Privacy note: every vault hit is an RPC query that never leaves the
machine, so the partial state node compounds with the SafeNode/ORAM
story — the best query-pattern leak is the query you don't send.

## Tests

`lake build vault_test && .lake/build/bin/vault_test` — SQLite
roundtrip + tier no-downgrade, RLP decoder roundtrips/canonicality,
and self-consistent MPT fixtures (single-leaf, branch+leaf, exclusion,
wrong-root, empty-trie; SKIPs when native helpers are not built).
`ops/tests/vault_smoke.sh` wraps it. The verifier has additionally been
validated against live mainnet `eth_getProof` responses (contract
account + storage slot, EOA, and deep 10-node proofs).

## Not yet

- Offline simulation (`eth_call` against accreted state) needs an EVM
  fed by the vault; helios's embedded REVM state provider is not
  pluggable from the NAPI surface. Out of scope for now.
- MPT verifier *soundness* is stated (📝 16.4) but not yet proved —
  it needs a formal trie semantics. The verifier is total, pure, and
  fixture/mainnet-tested.
