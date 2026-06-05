# leanCLI Audit & Maintainability Refactor — Working Plan

> Branch `refactor/kohaku-plugin-host`, off `master @ d0f6a32d`. Toolchain pinned (v4.29.1),
> **no new Lean deps**. Proofs-as-tests: `lake build` must stay green with zero `sorry` at every commit.
> This doc is the orchestration source of truth for the multi-phase refactor; Stream-F folds/removes it.

## Theme

A **flag-driven Kohaku-SDK plugin host**: the Kohaku SDK pulls **providers** (Helios / Colibri /
direct RPC / optional SafeNode ORAM proxy) and **privacy protocols** (Railgun / Privacy Pools /
Tornado-pending) on demand. Everything is a flag; nothing heavy is paid for until opted into.
Lean, auditable, maintainable, clean root. **Not a strip-down** — keep every useful feature.

## Decisions (user-confirmed 2026-06-05)

- **Colibri: KEPT**, folded into the provider registry as one selectable backend (mutually
  exclusive with Helios — "one or the other"). Routed via the Kohaku provider path
  (`@kohaku-eth/provider` exposes both `helios` and `colibri`). *Not deleted.*
- **`lib/sphincs-minus` submodule → `vendor/sphincs-minus`** (`.gitmodules` path rewrite).
- **DeFi skills: keep all, consolidate only.** Maintained core = uniswap/aave/morpho; long-tail
  (fxusd, bold-liquity, cowswap, …) stays in-tree.
- **`llm-legacy`: deleted** (native `leancli-agent` is the default and is independent of it).

## Recon corrections to the original brief (evidence-verified)

- **RustCrypto CANNOT be dropped** — `ripemd160IO` backs `HDKey.fingerprintIO` (BIP-32 HASH160);
  HACL doesn't expose RIPEMD-160; helper is in the daemon precheck. Stream A = scope-trim HACL +
  pin revisions + docs, **not** "collapse to 2 chains". Crypto is subprocess-helper based, not
  `extern_lib` FFI (only lean_uds/http/sqlite are `extern_lib`).
- **`Purpose.indexerLookup` is LIVE** (`ChainRpc.lean:570`) — keep it. Only `analytics`,
  `fiatOnramp`, `crashReport`, `metadataLookup` are dead and removable.
- **`P256Precompile` is SHARED** with SPHINCS (`SphincsAccount`, `Wallet/Account`,
  `Invariants/Mainnet`, `Lib/Core`). Strip R1-specific structures; keep precompile def + shared
  chain constants (extract to a neutral module if cleaner). **Do not delete the file.**
- **Invariants 5.9/5.10/5.11 are already correctly homed** in `Invariants/Network.lean`. No proof
  re-home; at most a ledger label tweak. **5.7** is an existing `🚧 in-progress` invariant (force
  every `Bridge.call` through `policyAllows`), to be completed — not a brand-new bonus.
- **TPM is gated with R1** at `Server.lean:114` (`tpm.`||`r1.`). Split the conditional, **keep TPM**
  (KEK custody), drop R1.
- **SafeNode is already flag-gated** (`LEANCLI_SAFE_NODE_URL`). Helios is default read backend;
  Colibri was disabled-by-default. `tx.simulate` already supports `backend: rpc|colibri|helios`.
- **Aave + Swap already consolidated** to single-RPC arms; **Morpho is skill-only** (no Lean module).
  Cat 11 (zero-slippage identity) must stay intact.

## Invariant deltas (INVARIANTS.md — Stream-F reconciles; nobody edits mid-stream except notes)

- REMOVE: Cat 9 (EIP-7951), Cat 10 (R1 contract), R1 half of 0.5 (keep EIP-7702 half), 8.4
  (Apple-SE-R1), 13.8 (P-256 EUF-CMA — orphaned once 9/10 go), R1 halves of 3.3.
- KEEP verbatim: 8.7 (PP/EOA secret split), Cat 12 (SPHINCS), Cat 11 (swap), Cat 14 (LLM addr).
- COMPLETE: 5.7 (host-call policy-classification runtime gate).
- RE-PROVE on trimmed types: Cat 6/7 (network policy), Cat 8 (keystore minus R1).
- Other Cat 13 entries (Keccak/SHA-256/RIPEMD/HMAC/PBKDF2/ChaCha20/secp256k1/SPHINCS/native) STAY.

## Phases

- **Phase 1 — Stream-0 (atomic, single commit, no behavior change):** repo-layout move.
  `c→native`, `bridge→sidecars/kohaku` (then `kohaku/clearsign→sidecars/clearsign`),
  `lib/sphincs-minus→vendor/sphincs-minus`, `script/+packaging/+tests/→ops/{scripts,packaging,tests}`.
  Fix lakefile `extern_lib` paths, all 23 Lean spawn-path literals + `Util/BridgeResolve.lean`,
  `script/leanclispawn` (pkill + wrapper + asset paths), CI, nix, docs index.
  **Snapshot JSON (10.9 MB): MOVE with the dir now (no behavior change). Gitignore+fetch-on-first-run
  is deferred — it needs a real fetch source and is a behavior change (cold-start), so not in the
  atomic move.**
- **Phase 2 — Streams A–E (parallel, disjoint paths; serialize shared-writer files):**
  - A: crypto sourcing hygiene (HACL scope-trim, pins, `docs/CRYPTO_POLICY.md`, `native/README.md`).
  - B: Kohaku plugin host — provider registry (helios/colibri/rpc/safenode), privacy registry,
    `plugins.lock.json`, delete llm-legacy, fold Helios/Colibri/Privacy into the host. **Hot file
    `RPC/Outbound.lean` — B edits before D.**
  - C: drop R1 + Solidity path (keep TPM, keep P256Precompile def, keep EIP-712/ENS), re-prove Cat 8.
  - D: network policy — re-home `Privacy/NetworkPolicy→Network/Policy` (15+ importers), trim 4 dead
    purposes, collapse mode matrix, re-prove Cat 6/7.
  - E: swap/DeFi simplification (mostly consolidation + docs; Cat 11 intact).
- **Phase 3 — Stream-F:** docs/invariants reconciliation + full integration gate.

## Integration contract (every commit)

1. `lake build` green, zero `sorry`/`sorryAx`.
2. Pre-sign pipeline (`decode→simulate→confirm`, `SendRawFlow` canonical) never bypassed.
3. ✅ invariant set only grows or is re-homed — never silently lost.
4. `(cd tui && npm run build)` green before any commit touching `tui/`.
5. Every Kohaku plugin stays untrusted (output re-validated in Lean, egress policy-gated).

## Status log

- [x] Branch created; green baseline (263 jobs, no sorry).
- [x] Recon (7 explorers) + verification of load-bearing claims.
- [x] Phase 1 — layout move (commit `94b9045a`).
- [x] Phase 2 Stream A — crypto hygiene (pins, CRYPTO_POLICY.md, native/README.md, pruned 2 dead helpers).
- [ ] Phase 2 Streams B, C, D, E.
- [ ] Phase 3 — Stream-F reconciliation + integration gate.
