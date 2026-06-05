# CHANGES — Stream E (swap / DeFi)

**Outcome: already in the target state — no code change needed; Cat 11 intact.** This stream is
best-effort consolidation, and the consolidation was already done in prior work. Verified:

- **Cat 11 proved & intact** (`Invariants/Swap.lean`): `slippageZeroIsIdentity` (0-bps slippage is the
  identity on `amountOut`) and `balancesCandidates_addressOn_some` (every balance candidate is a
  `(token, addr)` pair with the address present). Build green, untouched.
- **Already consolidated to single RPC arms** — no per-action duplicate daemon RPCs to remove:
  - Aave: one `aave.prepare` handler (`MiscRpc.lean`) dispatching `supply|withdraw|borrow|repay|setCollateral`.
  - Swap: `swap.tokens.list` / `swap.balances` / `swap.quote` / `swap.prepare` (`SwapRpc.lean`).
- **Reads already go through `chain.ethCall`** (Quoter/Pool/Aave reads in `Swap/UniV3.lean`,
  `Swap/Prepare.lean`, `Aave/Prepare.lean`, `MiscRpc`/`SwapRpc`) — no protocol-specific read RPCs duplicating it.
- **Swap UI already on the standard gate**: `SwapFlow` feeds the canonical `decode → simulate → ConfirmGate`
  via `SendRawFlow` (confirmed in Stream C's TUI pass — no bespoke confirm path).
- **All DeFi skills kept** (your decision — consolidate, don't delete): `aave`, `uniswap`,
  `swap-uniswap-v3`, `morpho` (skill-only — no Lean module), `fxusd`, `bold-liquity`, `cowswap`.
  Maintained core = uniswap/aave/morpho; long tail retained in-tree.

## Reference (documented, not changed)
- **Uniswap V3 fee-tier routing** (`SwapRpc.lean:171`): quotes are tried across `[500, 3000, 10000]` bps
  via `QuoterV2.quoteExactInputSingle`; best quote wins. The 100-bps (0.01%) stable-stable tier is
  deliberately skipped (conservative — avoids spurious thin-pool routes). Parametrizing the tier list is
  a possible future improvement, not a current need.
- **Supported token set** (`Swap/Tokens.lean`): curated; USDC/USDT carry `addressMainnet := none`
  (Sepolia-only by the earlier token pruning) and `TokenRegistry.fromSwapToken` emits "Sepolia only" for them.

No commit-worthy code change; this doc records the verified state for the Stream-F reconciliation.
