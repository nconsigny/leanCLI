# Upstream Catch-up Plan — kohaku-cli

**Upstream:** https://github.com/kassandraoftroy/kohaku-cli (local clone: `../kohaku-cli`)
**Last reviewed upstream SHA:** `d84bf57` ("chore: comment userop gas logs", 2026-07-19)
**Reviewed on:** 2026-07-20
**leanCLI baseline at review:** branch `tornado-cash-shield-unshield`, HEAD `0533694`

This document tracks feature/plugin parity with upstream kohaku-cli and defines the
recurring process for catching up on new upstream releases. Update the
"Last reviewed upstream SHA" marker every time a review completes.

---

## 1. Upstream delta reviewed (5 commits, `9101b07..611898f`)

| Commit | What it does |
|---|---|
| `738a326` | `--amount-max` flag + interactive `"max"` keyword on `transfer` and `unshield`; new `transfer-max.ts`, `railgun-unshield-max.ts`, `pimlico-gas.ts` utils |
| `54d0ecc` | USD values on all balance rows (CLI + TUI) via new `eth-prices@1.1.0` dep — on-chain pricing only (Chainlink ETH/USD feed, UniV2/V3 pools, fixed 1:1 stables) through the user's own RPC |
| `8a06f85` | README rewrite documenting the v0.0.1 surface (docs only) |
| `f4c78b4` | Tornado EIP-7702 delegation fix: bump `@kohaku-eth/tornado-cash` alpha.15 → alpha.16, deterministic delegator derived from the wallet BIP-32 path, recipient must be a wallet-derived account, per-withdrawal paymaster fee |
| `611898f` | v0.0.1 polish: tornado single-note unshield assertion, tornado `max` = largest spendable note, `--tail-calls` flag, tornado shield amount validation, `tui` subcommand disabled |

Second review (2026-07-20), `611898f..d84bf57`:

| Commit | What it does |
|---|---|
| `0df25ce` | Tail call clean up: `--tail-calls` entries gain an optional `msg.value` third field paid out of the withdrawal after the paymaster fee (payout call dropped at 0, hard error when tail values exceed the after-fee amount); UserOp `callGasLimit` becomes a calldata heuristic (`80k + 1.5×Σ`, clamp [300k, 5M], no `eth_estimateGas`) patched into the SDK worker pre-spawn and fed into the fee formula — **ported, see WS-5.3** |
| `d84bf57` | Comments out userop gas debug logs — no port needed |

Upstream repo facts (verified 2026-07-19): no tags/releases, no open PRs, no unmerged
branches; sole contributor pushes bursts directly to `main` (last burst 07-18/19).
**Tracking upstream = watching `main` + npm, not GitHub releases.**

## 2. Plugin release status

Upstream's pins were current with npm at review time (only `derive-railgun-keys`
0.1.0 → 0.1.1 was behind; trivial, behavior-equivalent HMAC swap). The table
records leanCLI's pre-catch-up baseline:

| Package | leanCLI pin at review | upstream pin / npm target | Gap contents |
|---|---|---|---|
| `@kohaku-eth/tornado-cash` | 0.0.2-alpha.15 | **0.0.2-alpha.16** (07-18) | arbitrary delegator paths (`deriveDelegatorSigner`, `delegation:{mode:"deterministic",path}`) — the 7702 fix |
| `@kohaku-eth/railgun` | 0.0.1-alpha.21 | **0.0.1-alpha.28** (07-04) | incl. alpha.27 (06-18) **unified note-by-note plugin API** |
| `@kohaku-eth/privacy-pools` | 0.0.2-alpha.9 | **0.0.2-alpha.14** (07-04) | incl. alpha.13 (06-18) unified note-by-note API |
| `@kohaku-eth/plugins` | 0.0.1-alpha.8 | **0.0.1-alpha.11** (07-04) | lockstep API/dependency updates |

Caveats discovered:
- npm dist-tag `latest` is **stale** for `privacy-pools` (points at 0.0.1) and
  `tornado-cash` — always pin exact versions; never rely on `npm install <pkg>`.
- All `@kohaku-eth/*` packages publish in lockstep from the `ethereum/kohaku` monorepo
  via GitHub Actions with npm provenance attestations (lockstep dates: 03-25, 04-23,
  06-12, 06-18, 07-04). Verify provenance when bumping `plugins.lock.json`.
- `npm audit --omit=dev` on the completed WS-2 tree reports **0 critical, 14 high,
  38 moderate** transitive findings. Most high findings are under Tornado's
  `@privacy-paymasters/sdk` / `@pimlico/alto` toolchain; Privacy Pools also has an
  unfixed moderate `@zk-kit/lean-imt` chain. npm offers no compatible direct-package
  fix for either plugin. Do not run `npm audit fix --force` (it proposes downgrading
  Tornado to 0.0.1); track fixes in upstream Kohaku releases.

## 3. Workstreams (priority order)

### WS-1 — Security: tornado 7702 deterministic delegation (do first)
On alpha.15, paymaster withdrawals use an **ephemeral delegator not recoverable from the
seed** — the exact defect upstream fixed. leanCLI shared it before this workstream.

**Status: completed 2026-07-20.** Alpha.16 is pinned with verified registry integrity;
the daemon resolves and re-derives wallet-owned recipients before forwarding their BIP-44
paths, the sidecar uses deterministic delegation, and execute re-checks the spendable note.

1. Bump `@kohaku-eth/tornado-cash` → 0.0.2-alpha.16 in `sidecars/kohaku/package.json`,
   regenerate `package-lock.json`, update `plugins.lock.json` (version + sha512) per the
   SECURITY.md supply-chain pinning process. *(S)*
2. `sidecars/kohaku/tornado.mjs` (`tornadoQuoteWithdraw`/`tornadoExecuteWithdraw`): accept
   a `recipientDerivationPath` and pass `delegation:{mode:"deterministic",path}` to
   `prepareUnshield`. *(S)*
3. Lean core owns the policy (invariant: no signing decision depends on sidecar output):
   in `LeanCli/Daemon/Server/ShieldedRpc.lean` (`shielded.tornado.quoteWithdraw` /
   `executeWithdraw`, ~l.1010-1062), resolve the recipient **daemon-side** against the
   wallet's own account records (EoaStore carries `derivationPath`) and hard-require a
   wallet-derived recipient; fail fast before spawning the sidecar. Do NOT trust a path
   supplied by CLI/TUI/agent. `Bip44.canonicalEthereumPath` already exists — don't re-port
   upstream's path helper. *(M)*
4. Per-withdrawal paymaster fee: enforce the quote-time single-matching-note invariant at
   execute time in `tornadoExecuteWithdraw` (re-check a spendable note with
   `amount === amountWei`, throw if absent). leanCLI's one-denomination-per-call model
   makes this the correct minimal port. *(S)*

### WS-2 — Plugin catch-up: railgun/PP/plugins to the 07-04 lockstep set
Bigger than the CLI diff: crosses the 06-18 **unified note-by-note API**.

**Status: completed 2026-07-20.** The monorepo changes at `8420942` (async Host),
`36f090e` (unified notes), and the Railgun alpha.22–25 runtime fixes were reviewed.
The lockstep target set is pinned with verified integrity; the bridge now uses async
storage/keystore methods, Privacy Pools' initial-state provider callback, and Railgun's
post-WASM 4337/7702 configuration.

1. Bump `@kohaku-eth/plugins` → alpha.11, `@kohaku-eth/railgun` → alpha.28,
   `@kohaku-eth/privacy-pools` → alpha.14 together (lockstep set). *(M)*
2. Reconcile `sidecars/kohaku/bridge.mjs` and the railgun/PP flows with the note-by-note
   API changes; re-run shielded smoke tests (CI scripts under `ops/`). *(M–L, unknown
   until the API diff is read — read the `ethereum/kohaku` monorepo changelog between
   the pinned and target versions first)*
3. Update transitive pins (`@kohaku-eth/provider`, `mimc-tree`) in `plugins.lock.json`
   with provenance verification. *(S)*

### WS-3 — amount-max / "max" keyword parity — **done**
Port the *math* daemon-side in Lean; treat sidecar-computed caps as untrusted quotes.
1. Pure function first: `transferMaxAmountFromBalance` as `LeanCli/Ethereum/TransferMax.lean`
   with lemmas (`result ≤ balance`, `result = 0` when `balance ≤ reserve`) alongside the
   existing `subChecked` lemmas in `LeanCli/Invariants/`. *(S)*
2. Daemon RPC `eoa.maxSendable`: reserve = `21000 × maxFeePerGas × 1.2` using the already
   **capped** EIP-1559 fee logic in `LeanCli/Daemon/Server/Helpers.lean` (~l.559-694) —
   deliberately diverge from upstream's unclamped provider estimate. *(M)*
3. CLI: accept a `max` literal on `send`/`unshield` grammar arms in
   `LeanCli/Cli/Commands.lean` (matches the existing approve/Aave sentinel convention);
   TUI: accept `"max"` in `SendFlow.tsx` / `WalletUnshieldFlow.tsx` / `UnshieldFlow.tsx`
   amount fields, **resolving to a concrete wei value before the ConfirmGate** so the
   broadcast is bound to the confirmed number. *(M)*
4. Railgun net-max: port `railgun-unshield-max.ts` (fixed 4337 gas-unit table, treasury
   BPS math `((balance − gasReserve) × (10000 − feeBps)) / 10000`, Pimlico
   `pimlico_getUserOperationGasPrice`) as a sidecar quote op + Lean-side display; preserve
   upstream's failure policy — gas-fetch failure is **fatal** for `--amount-max` on
   fee-token unshields, soft-fallback (flagged) for the interactive hint. *(M)*
5. Privacy Pools max = largest single unspent note; Tornado max = largest spendable note
   (grammar arm + notes fold; prerequisites already exist). *(S)*

Implemented July 20, 2026. Native sends resolve through `eoa.maxSendable` using the
same capped EIP-1559 fee reader as signing. CLI/TUI `max` inputs are replaced by a
concrete amount before simulation/confirmation. Shielded max selection is note-bound
for Privacy Pools/Tornado; Railgun uses the upstream fixed 4337 gas table, Pimlico
`standard.maxFeePerGas`, and treasury BPS math, then recomputes the cap at execution.
The TUI treats an explicit Railgun `max` gas-price failure as fatal; the read-only RPC
also supports `strict:false` and returns `gasEstimateFailed:true` for hint surfaces.

### WS-4 — USD pricing (decision required — currently a deliberate exclusion)
`Purpose.priceQuote` is a denied third-party purpose (proved invariant 6.4). **Nuance
from reading upstream:** `eth-prices` is *not* a hosted price API — it quotes entirely
on-chain (Chainlink aggregator, Uniswap pools) via the user's own RPC, i.e. traffic that
classifies as `.nodeRead` to the configured node. Options:
- **(a) Won't-do** — keep the exclusion, record it in §5. Zero work.
- **(b) Port natively in Lean core** — new `LeanCli/Prices/` module reusing the
  `eth_call` plumbing pattern of `LeanCli/Swap/UniV3.lean` (Chainlink `latestRoundData`,
  UniV2/V3 pool reads, fixed 1:1 stables), folded into the existing Multicall3 batch in
  `SwapRpc.lean` `swap.balances`; pure cent-rounding math (`(usd6+5000)/10000`, half-up,
  negate-after-round) proved in Lean. No `eth-prices` JS dep, no policy change to
  third-party purposes — but requires an explicit note amending the 6.4 rationale. *(M–L)*
Decision owner: project. Until decided, listed as **deferred**, not missing.

### WS-5 — Small parity fixes
1. Tornado shield validation into Lean core: pre-flight `wei % 10^17 == 0 && wei > 0`
   check in the `.tornadoDeposit` handler (`LeanCli/Cli/Runtime.lean` ~l.2662) using the
   verified `parseEthToWei`; adopt upstream's clearer denominations message. Sidecar
   check stays as defense-in-depth. *(S)*
2. Tornado single-note unshield: ~80% already ported; add the chain-keyed denomination
   table + assertion to Lean core next to the tornado pool registry in
   `LeanCli/Registry/KnownProtocols.lean` (currently sidecar-only). *(S)*
3. `--tail-calls` user-supplied extras: mechanism (payout-first `tailCalls` closure) is
   already ported; expose optional user extras only if a use-case appears. **Optional.** *(M)*

   **Status: completed 2026-07-20** (upstream promoted this to a full feature in
   `0df25ce` "fix: tail call clean up", ported same day). Surface:
   `leancli unshield tornado <chainId> <to> <eth|max> [mode] --tail-calls
   TARGET:CALLDATA[:VALUE],...`. Entries are parsed/validated in the verified core
   (`LeanCli/Ethereum/TornadoTailCalls.lean`, native_decide-checked examples), the
   daemon re-validates the JSON and rejects tail calls outside paymaster mode
   before unlocking a slot, and the sidecar re-validates again (defense in depth).
   Fee math per upstream: `forwardValue = amount − fee − Σ(tail values)`, hard
   error when tail values exceed the after-fee amount, payout call omitted at 0.
   The UserOp `callGasLimit` is a calldata heuristic (`80k + 1.5×Σ(per-call)`,
   clamped to [300k, 5M], no `eth_estimateGas` — the delegated account is unfunded
   pre-unshield) written into the SDK worker before it spawns; the paymaster fee
   uses the same dynamic limit, and the quote returns
   `callGasLimit`/`tailCallCount`/`tailValueWei` for the ConfirmGate.

## 4. Won't-port (deliberate divergences)
- **`tui` subcommand disabled upstream (611898f):** upstream disabled its immature TUI
  for the v0.0.1 release; leanCLI's TUI is a first-class, mature surface (38 screens).
  Keep `tui`/`ui`.
- **`derive-railgun-keys` 0.1.1:** leanCLI doesn't use the package (BIP-32 is native).
- **USD pricing** pending the WS-4 decision.

## 5. Recurring upstream-tracking process
No tracking mechanism existed before this doc (zero markdown mentions of kohaku-cli;
only inline "Ported from kohaku-cli src/..." comments in sidecar JS — keep writing those,
now with the upstream SHA: `// Ported from kohaku-cli src/x.ts @ <sha>`).

**Cadence: weekly, and after any upstream push burst.** Checklist:
1. `git -C ../kohaku-cli fetch origin` then
   `git -C ../kohaku-cli log --oneline <last-reviewed-sha>..origin/main`.
2. Diff upstream `package.json` pins vs the previous review
   (`git -C ../kohaku-cli diff <last-reviewed-sha>..origin/main -- package.json`).
3. `npm view` each `@kohaku-eth/*` package (+ `eth-prices`) — compare against BOTH
   upstream's pins and `sidecars/kohaku/package.json`; remember `latest` dist-tags are
   stale, list versions explicitly.
4. Skim the `ethereum/kohaku` monorepo release notes for the new plugin versions;
   flag anything touching signing, delegation, fees, or note selection as
   security-priority.
5. Classify each new upstream item: port / adapt (trust-boundary differences) /
   won't-port — append to §3/§4 and move the "Last reviewed upstream SHA" marker.

Candidate automation (not yet built): `ops/upstream-check.sh` doing steps 1–3
mechanically and printing a report; optionally run on a weekly schedule.

## 6. Suggested sequencing
WS-1 **done** → WS-2 **done** → WS-3 **done** → WS-5 (small fixes, can
interleave) → WS-4 (after the policy decision).
