import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import Select from "../widgets/Select.js";
import TextInput from "ink-text-input";
import RecipientInput from "../widgets/RecipientInput.js";
import { Layout, Banner } from "../widgets/Layout.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { Wallet } from "../types.js";
import { hexToBigInt } from "../format.js";
import SendRawFlow, { SendRawWallet } from "./SendRawFlow.js";

/** Per-token balance map keyed by symbol (uppercase, "ETH" for native).
 *  Built from the daemon's `swap.balances` response. Values are raw base
 *  units (uint256) — never JS Number. `null` means we have not yet
 *  fetched balances; missing key means the token reverted (silently
 *  dropped server-side) or balances haven't loaded yet. */
type BalanceMap = Record<string, bigint>;

/** Build a `BalanceMap` from the daemon's `swap.balances` response array.
 *  Drops any malformed entries silently — the daemon-side fail-soft rule
 *  already handles per-token reverts; this is just a JSON-shape guard. */
function balanceArrayToMap(
  arr: Array<{
    symbol: string;
    address: string | null;
    decimals: number;
    balance: string;
  }>,
): BalanceMap {
  const out: BalanceMap = {};
  for (const e of arr) {
    if (!e || typeof e.symbol !== "string") continue;
    out[e.symbol.toUpperCase()] = hexToBigInt(e.balance);
  }
  return out;
}

/** Format a base-unit balance with up to 6 fractional digits, trimming
 *  trailing zeros. Used in the pick-from / pick-to labels where we have
 *  fixed column space. */
function formatBalanceShort(amount: bigint, decimals: number): string {
  if (decimals === 0) return amount.toString();
  const base = 10n ** BigInt(decimals);
  const whole = amount / base;
  const frac = amount % base;
  if (frac === 0n) return whole.toString();
  let fracStr = frac.toString().padStart(decimals, "0");
  // Truncate (NOT round) to 6 fractional digits to keep the column width
  // bounded. Rounding would risk reporting a balance the user does not
  // actually have.
  if (fracStr.length > 6) fracStr = fracStr.slice(0, 6);
  fracStr = fracStr.replace(/0+$/, "");
  return fracStr.length === 0 ? whole.toString() : `${whole.toString()}.${fracStr}`;
}

/** A registry token as exposed by the daemon's `swap.tokens.list` RPC.
 *  The TUI must NOT duplicate the registry — it's sourced from
 *  `LeanKohaku.Swap.Tokens.registry` via the daemon. */
type DaemonToken = {
  symbol: string;
  name: string;
  address: string;
  decimals: number;
};

/** Synthetic ETH entry shown above the registry. The daemon's swap RPCs
 *  accept the literal "ETH" and map it to WETH internally. */
type EthEntry = { kind: "eth"; symbol: "ETH"; name: "Ether"; decimals: 18 };
type TokenItem =
  | EthEntry
  | (DaemonToken & { kind: "erc20" });

const ETH_ITEM: EthEntry = {
  kind: "eth",
  symbol: "ETH",
  name: "Ether",
  decimals: 18,
};

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;

/** Slippage selector options in basis points (1bp = 0.01%). */
const SLIPPAGE_PRESETS: { label: string; bps: number }[] = [
  { label: "0.1%", bps: 10 },
  { label: "0.5% (default)", bps: 50 },
  { label: "1.0%", bps: 100 },
];

/** A chain known to the registry, with whether the daemon has an RPC URL
 *  configured for it. Names match the daemon's `ChainId.fromString?`
 *  ("mainnet" | "sepolia") so we can pass them straight through to swap.* RPCs. */
type ChainEntry = {
  name: string;
  chainId: number;
  hasRpc: boolean;
};

/** Chain names recognized by the swap-side `ChainId.fromString?`. We refuse
 *  to display chains the daemon does not know how to swap on, even if RPC
 *  is configured (e.g. arbitrum) — registry has no addresses for them. */
const SWAP_CHAINS: ReadonlyArray<{ name: string; chainId: number }> = [
  { name: "mainnet", chainId: 1 },
  { name: "sepolia", chainId: 11155111 },
];

type Phase =
  | { kind: "load-chains" }
  | { kind: "load-tokens"; chain: ChainEntry; chains: ChainEntry[] }
  | { kind: "load-error"; message: string }
  | {
      kind: "pick-from";
      tokens: TokenItem[];
      chain: ChainEntry;
      chains: ChainEntry[];
    }
  | {
      kind: "pick-to";
      tokens: TokenItem[];
      from: TokenItem;
      chain: ChainEntry;
      chains: ChainEntry[];
    }
  | {
      kind: "enter-amount";
      tokens: TokenItem[];
      from: TokenItem;
      to: TokenItem;
      chain: ChainEntry;
      chains: ChainEntry[];
      draft: string;
      err: string | null;
    }
  | {
      kind: "enter-receiver";
      tokens: TokenItem[];
      from: TokenItem;
      to: TokenItem;
      chain: ChainEntry;
      chains: ChainEntry[];
      amountIn: bigint;
      draft: string;
      err: string | null;
    }
  | {
      kind: "pick-slippage";
      ctx: SwapCtx;
    }
  | { kind: "quoting"; ctx: SwapCtx }
  | { kind: "quote-error"; ctx: SwapCtx; message: string }
  | {
      kind: "review-quote";
      ctx: SwapCtx;
      amountOut: bigint;
      fee: number;
    }
  | {
      kind: "building";
      ctx: SwapCtx;
      amountOut: bigint;
      fee: number;
      slippageBps: number;
    }
  | { kind: "build-error"; ctx: SwapCtx; message: string }
  | {
      kind: "confirm-approval";
      ctx: SwapCtx;
      approval: { to: string; value: string; data: string };
      swap: { to: string; value: string; data: string };
      summary: string;
    }
  | {
      kind: "confirm-swap";
      ctx: SwapCtx;
      swap: { to: string; value: string; data: string };
      summary: string;
    }
  | { kind: "done"; summary: string };

type SwapCtx = {
  chain: ChainEntry;
  chains: ChainEntry[];
  fromAddress: string;
  from: TokenItem;
  to: TokenItem;
  amountIn: bigint;
  recipient: string;
  slippageBps: number;
  tokens: TokenItem[];
};

type Props = {
  /** Active wallet (EOA or TPM/R1). The signing wallet is fixed up front:
   *  the TUI surface that opens the swap screen already knows which slot
   *  the user picked, and TPM/R1 wallets can't share the EOA picker
   *  (different signing path). For R1 wallets the chain selector is
   *  pinned to sepolia because `r1.send*` mainnet does not exist. */
  wallet: Wallet;
  onDone: (success: boolean) => void;
};

/** Parse a decimal string into base units for `decimals`. Returns null on
 *  invalid input, including too-many-fraction-digits. Uses BigInt
 *  exclusively — never JS Number. */
function parseDecimal(input: string, decimals: number): bigint | null {
  const s = input.trim();
  if (!/^[0-9]+(\.[0-9]+)?$/.test(s)) return null;
  const [whole, frac = ""] = s.split(".");
  if (frac.length > decimals) return null;
  const padded = (frac + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(padded || "0");
}

/** Format a base-units amount as a decimal string with up to `decimals`
 *  fractional digits, trimming trailing zeros. */
function formatBaseUnits(amount: bigint, decimals: number): string {
  if (decimals === 0) return amount.toString();
  const base = 10n ** BigInt(decimals);
  const whole = amount / base;
  const frac = amount % base;
  if (frac === 0n) return whole.toString();
  const fracStr = frac.toString().padStart(decimals, "0").replace(/0+$/, "");
  return `${whole.toString()}.${fracStr}`;
}

/** Uniswap V3 swap screen. Pure UI: every chain interaction is a daemon
 *  RPC and signing is delegated to `SendRawFlow` (the canonical
 *  ConfirmGate path). The daemon enforces approval correctness; we just
 *  hand off the {to,value,data} blobs it returns and confirm both
 *  approval + swap separately. */
export default function SwapFlow({ wallet, onDone }: Props) {
  const fromAddress = wallet.address;
  // R1 wallets only have a sepolia signing path today (`r1.sendRawSepolia`);
  // hide mainnet from the chain cycle so `n` cannot land us on a chain
  // where signing would fail at the very last step.
  const isR1 = wallet.kind === "tpm";
  const sendRawWallet: SendRawWallet = {
    kind: wallet.kind,
    name: wallet.name,
    address: wallet.address,
  };
  const [phase, setPhase] = useState<Phase>({ kind: "load-chains" });
  // Per-token balances for the from-picker / to-picker labels. Lifted
  // above the phase ADT because balances persist across phase
  // transitions (pick-from → pick-to → enter-amount → back) and we
  // don't want to thread them through every phase variant. `null`
  // means "not yet fetched"; an empty map means "fetched, none ready".
  const [balances, setBalances] = useState<BalanceMap | null>(null);
  const [refreshingBalances, setRefreshingBalances] = useState(false);

  // Step 1a: ask the daemon which chains have RPC URLs configured
  // (`network set-rpc-chain` entries). Pick the one the daemon flags as
  // current if it has RPC; otherwise pick the first configured chain we
  // know how to swap on. Never hardcode chainId — chain selection is the
  // daemon's job, and the daemon refuses chains with no RPC at the
  // `endpointForChain` boundary.
  useEffect(() => {
    if (phase.kind !== "load-chains") return;
    let cancelled = false;
    (async () => {
      const ping = await call<{
        chainId?: number;
        chains?: Array<{ name: string; chainId: number; hasRpc: boolean }>;
      }>("daemon.ping");
      if (cancelled) return;
      if (!ping.ok) {
        return setPhase({
          kind: "load-error",
          message: `daemon.ping failed: ${ping.error.message}`,
        });
      }
      // Build the chain list strictly from daemon state. We only surface
      // chains the swap registry knows ("mainnet"/"sepolia") — others have
      // no addresses on file even if the user registered an RPC.
      const configured = new Set(
        (ping.result?.chains ?? [])
          .filter((c) => c && c.hasRpc)
          .map((c) => c.name),
      );
      const currentDaemonChainId = ping.result?.chainId;
      // R1 (TPM) wallets only have a sepolia signing path today, so we
      // restrict the chain list at source rather than letting the user
      // pick a chain we can't broadcast on.
      const allowed = isR1
        ? SWAP_CHAINS.filter((c) => c.name === "sepolia")
        : SWAP_CHAINS;
      const chains: ChainEntry[] = allowed.map((c) => ({
        name: c.name,
        chainId: c.chainId,
        hasRpc: configured.has(c.name),
      }));
      const ready = chains.filter((c) => c.hasRpc);
      if (ready.length === 0) {
        return setPhase({
          kind: "load-error",
          message: isR1
            ? "R1 wallets can only swap on sepolia — register an RPC with `kohaku network set-rpc-chain sepolia <url>`"
            : "no swappable chain has an RPC configured — register one with `kohaku network set-rpc-chain mainnet <url>` or `… sepolia <url>`",
        });
      }
      // Prefer the daemon's "current" chain *only* if its RPC is configured.
      // Otherwise fall back to the first ready chain — never silently dial
      // a chain that has no RPC.
      // ready.length ≥ 1 is enforced by the early-return above, so ready[0] is safe.
      const preferred: ChainEntry =
        ready.find((c) => c.chainId === currentDaemonChainId) ?? ready[0]!;
      setPhase({ kind: "load-tokens", chain: preferred, chains });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  // Step 1b: pull the token registry AND the per-token balances for the
  // selected chain in parallel. We don't block tokens on balances — if
  // balances are slower (typical on busy public RPCs) we render the
  // pick-from screen with a placeholder column and update once the
  // balance fan-out resolves. Re-runs every time `chain` changes (toggle
  // key flips the phase back through here).
  useEffect(() => {
    if (phase.kind !== "load-tokens") return;
    const { chain, chains } = phase;
    let cancelled = false;
    (async () => {
      // Race tokens + balances. The daemon's `swap.*` handlers parse
      // `chainId` as a *string* ("mainnet" / "sepolia" / numeric); pass
      // the canonical name so `paramStringD` does not silently fall
      // back to "mainnet".
      const tokensP = call<{ tokens: DaemonToken[] }>("swap.tokens.list", {
        chainId: chain.name,
      });
      const balancesP = call<{
        balances: Array<{
          symbol: string;
          address: string | null;
          decimals: number;
          balance: string;
        }>;
      }>("swap.balances", { chainId: chain.name, address: fromAddress });

      const r = await tokensP;
      if (cancelled) return;
      if (!r.ok) {
        return setPhase({
          kind: "load-error",
          message: `swap.tokens.list failed: ${r.error.message}`,
        });
      }
      const reg = (r.result?.tokens ?? []).map(
        (t) => ({ ...t, kind: "erc20" as const }),
      );
      const tokens: TokenItem[] = [ETH_ITEM, ...reg];

      // Reset balances for the new chain; advance to pick-from
      // immediately so the user is not blocked on balance fan-out.
      setBalances(null);
      setRefreshingBalances(false);
      setPhase({ kind: "pick-from", tokens, chain, chains });

      // Patch in balances when they arrive (fail-soft on RPC error —
      // the placeholder column just stays in place).
      const b = await balancesP;
      if (cancelled) return;
      if (b.ok) {
        setBalances(balanceArrayToMap(b.result?.balances ?? []));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind, phase.kind === "load-tokens" ? phase.chain.name : ""]);

  // Wizard-level navigation rule: sub-components (ink-select-input,
  // ink-text-input) own ↑/↓ and ←/→ where they need them; the wizard
  // frame only registers left/right on review-style phases between
  // sub-components (currently `review-quote`) and a left-only handler on
  // pages where → would skip a required selection. Chain toggle is
  // bound to `n` and is safe everywhere because no embedded widget uses
  // that key.

  if (phase.kind === "load-chains" || phase.kind === "load-tokens") {
    const sub =
      phase.kind === "load-tokens"
        ? `Loading ${phase.chain.name} token registry…`
        : "Asking the daemon which chains are configured…";
    return (
      <Layout title="Uniswap V3 swap" subtitle={sub}>
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>
            {phase.kind === "load-tokens"
              ? "fetching swap.tokens.list"
              : "fetching daemon.ping"}
          </Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "load-error") {
    return (
      <Layout title="Cannot start swap" hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  if (phase.kind === "pick-from") {
    const items = phase.tokens.map((t) => {
      const sym = t.symbol.toUpperCase();
      const bal = balances ? balances[sym] : undefined;
      const balCol =
        balances === null
          ? "" // placeholder while balances load late
          : bal === undefined
            ? "—"
            : formatBalanceShort(bal, t.decimals);
      const isZero = bal !== undefined && bal === 0n;
      const label = `${t.symbol.padEnd(8)}  ${t.name.padEnd(28)}${balCol.padStart(14)}`;
      return {
        label: isZero ? "" + label : label,
        value: t.symbol,
        dim: isZero,
      };
    });
    const balanceStatus =
      balances === null
        ? "loading balances…"
        : refreshingBalances
          ? "refreshing balances…"
          : "press r to refresh balances";
    return (
      <Layout
        title="Swap — pick the token to sell"
        subtitle={`${chainHeader(phase.chain, phase.chains, isR1)} · sender ${fromAddress}`}
        hint="↑/↓ move · enter pick · n cycle chain · r refresh balances · esc cancel"
      >
        <BackOnEsc onDone={() => onDone(false)} />
        <ChainToggleOnN
          chain={phase.chain}
          chains={phase.chains}
          onSwitch={(c) => {
            // Switching chains discards the old balances; load-tokens
            // will re-fan-out for the new chain.
            setBalances(null);
            setRefreshingBalances(false);
            setPhase({ kind: "load-tokens", chain: c, chains: phase.chains });
          }}
          enabled={!isR1}
        />
        <RefreshBalancesOnR
          chainName={phase.chain.name}
          address={fromAddress}
          enabled={!refreshingBalances}
          onStart={() => setRefreshingBalances(true)}
          onResult={(map) => {
            if (map !== null) setBalances(map);
            setRefreshingBalances(false);
          }}
        />
        {isR1 && (
          <Box marginBottom={1}>
            <Text color={theme.warn}>
              R1 wallets: ERC20 sells need 2 biometric prompts (approve + swap); ETH sells need 1.
            </Text>
          </Box>
        )}
        <Box marginBottom={1}>
          <Text color={theme.dim}>{balanceStatus}</Text>
        </Box>
        <Select
          items={items}
          onSelect={(it) => {
            const from = phase.tokens.find((t) => t.symbol === it.value);
            if (from)
              setPhase({
                kind: "pick-to",
                tokens: phase.tokens,
                from,
                chain: phase.chain,
                chains: phase.chains,
              });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "pick-to") {
    const choices = phase.tokens.filter((t) => t.symbol !== phase.from.symbol);
    const r1NeedsTwoPrompts = isR1 && phase.from.symbol !== "ETH";
    const goBackToPickFrom = () =>
      setPhase({
        kind: "pick-from",
        tokens: phase.tokens,
        chain: phase.chain,
        chains: phase.chains,
      });
    return (
      <Layout
        title={`Swap ${phase.from.symbol} → ?`}
        subtitle={`${chainHeader(phase.chain, phase.chains, isR1)} · pick the token to receive`}
        hint="↑/↓ move · enter pick · ← back · esc back"
      >
        <BackOnEsc onDone={goBackToPickFrom} />
        {r1NeedsTwoPrompts && (
          <Box marginBottom={1}>
            <Text color={theme.warn}>
              R1 ERC20 sell: 2 biometric prompts will be requested (approve + swap).
            </Text>
          </Box>
        )}
        {/* Wizard-frame ← only — sub-component owns ↑/↓/enter. → would
            require a token, so it's a no-op here (handled by SelectInput
            consuming enter once a token is highlighted). */}
        <WizardLeftOnly onLeft={goBackToPickFrom} />
        <Select
          items={choices.map((t) => {
            const sym = t.symbol.toUpperCase();
            const bal = balances ? balances[sym] : undefined;
            const balCol =
              balances === null
                ? ""
                : bal === undefined
                  ? "—"
                  : formatBalanceShort(bal, t.decimals);
            return {
              label: `${t.symbol.padEnd(8)}  ${t.name.padEnd(28)}${balCol.padStart(14)}`,
              value: t.symbol,
            };
          })}
          onSelect={(it) => {
            const to = choices.find((t) => t.symbol === it.value);
            if (!to) return;
            // Token → ETH: daemon explicitly rejects in this slice.
            // Surface a clear hint right here rather than waiting for
            // swap.uniV3.build to fail.
            if (to.kind === "eth" && phase.from.kind !== "eth") {
              return setPhase({
                kind: "build-error",
                ctx: stubCtx(
                  phase.chain,
                  phase.chains,
                  fromAddress,
                  phase.from,
                  to,
                  phase.tokens,
                ),
                message:
                  "token → ETH unwrap is not yet supported in this slice. Pick WETH as the destination instead.",
              });
            }
            setPhase({
              kind: "enter-amount",
              tokens: phase.tokens,
              from: phase.from,
              to,
              chain: phase.chain,
              chains: phase.chains,
              draft: "",
              err: null,
            });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "enter-amount") {
    return (
      <Layout
        title={`Swap ${phase.from.symbol} → ${phase.to.symbol}`}
        subtitle={`${chainHeader(phase.chain, phase.chains, isR1)} · amount in ${phase.from.symbol} (decimals ${phase.from.decimals})`}
        hint="enter — next · esc — back"
      >
        <BackOnEsc
          onDone={() =>
            setPhase({
              kind: "pick-to",
              tokens: phase.tokens,
              from: phase.from,
              chain: phase.chain,
              chains: phase.chains,
            })
          }
        />
        {/* Wizard-frame arrows are NOT bound here: ink-text-input owns
            ←/→ for cursor movement. Esc still goes back. */}
        <Box>
          <Text color={theme.dim}>amount: </Text>
          <TextInput
            value={phase.draft}
            placeholder="0.1"
            onChange={(v) =>
              setPhase({ ...phase, draft: v, err: null })
            }
            onSubmit={(v) => {
              const parsed = parseDecimal(v, phase.from.decimals);
              if (parsed === null || parsed === 0n) {
                return setPhase({
                  ...phase,
                  err: `expected a decimal with ≤${phase.from.decimals} fractional digits and > 0`,
                });
              }
              setPhase({
                kind: "enter-receiver",
                tokens: phase.tokens,
                from: phase.from,
                to: phase.to,
                chain: phase.chain,
                chains: phase.chains,
                amountIn: parsed,
                draft: "",
                err: null,
              });
            }}
          />
        </Box>
        {phase.err && (
          <Box marginTop={1}>
            <Text color={theme.err}>{phase.err}</Text>
          </Box>
        )}
      </Layout>
    );
  }

  if (phase.kind === "enter-receiver") {
    return (
      <Layout
        title={`Swap ${phase.from.symbol} → ${phase.to.symbol}`}
        subtitle={`Recipient (default: sender ${fromAddress}). Leave blank to use sender.`}
        hint="enter — next · esc — back"
      >
        <BackOnEsc
          onDone={() =>
            setPhase({
              kind: "enter-amount",
              tokens: phase.tokens,
              from: phase.from,
              to: phase.to,
              chain: phase.chain,
              chains: phase.chains,
              draft: formatBaseUnits(phase.amountIn, phase.from.decimals),
              err: null,
            })
          }
        />
        {/* Wizard-frame arrows are NOT bound here for the same reason as
            enter-amount: ink-text-input owns ←/→. */}
        <Box>
          <Text color={theme.dim}>recipient: </Text>
          <RecipientInput
            value={phase.draft}
            placeholder="(blank = sender)"
            excludeAddress={fromAddress}
            onChange={(v) => setPhase({ ...phase, draft: v, err: null })}
            onSubmit={(v) => {
              const trimmed = v.trim();
              const recipient = trimmed.length === 0 ? fromAddress : trimmed;
              if (!ADDR_RE.test(recipient)) {
                return setPhase({
                  ...phase,
                  err: "recipient must be a 0x-prefixed 20-byte address",
                });
              }
              setPhase({
                kind: "pick-slippage",
                ctx: {
                  chain: phase.chain,
                  chains: phase.chains,
                  fromAddress,
                  from: phase.from,
                  to: phase.to,
                  amountIn: phase.amountIn,
                  recipient: recipient.toLowerCase(),
                  slippageBps: 50,
                  tokens: phase.tokens,
                },
              });
            }}
          />
        </Box>
        {phase.err && (
          <Box marginTop={1}>
            <Text color={theme.err}>{phase.err}</Text>
          </Box>
        )}
      </Layout>
    );
  }

  if (phase.kind === "pick-slippage") {
    const goBack = () =>
      setPhase({
        kind: "enter-receiver",
        tokens: phase.ctx.tokens,
        from: phase.ctx.from,
        to: phase.ctx.to,
        chain: phase.ctx.chain,
        chains: phase.ctx.chains,
        amountIn: phase.ctx.amountIn,
        draft:
          phase.ctx.recipient.toLowerCase() === fromAddress.toLowerCase()
            ? ""
            : phase.ctx.recipient,
        err: null,
      });
    return (
      <Layout
        title={`Swap ${phase.ctx.from.symbol} → ${phase.ctx.to.symbol}`}
        subtitle={`${chainHeader(phase.ctx.chain, phase.ctx.chains, isR1)} · pick max slippage tolerance`}
        hint="↑/↓ move · enter pick · ← back · esc back"
      >
        <BackOnEsc onDone={goBack} />
        {/* Slippage uses ink-select-input which only consumes ↑/↓; ←/→
            is free. → would advance into "quoting" but the user must
            still pick a slippage level, so → is a no-op here. */}
        <WizardLeftOnly onLeft={goBack} />
        <Select
          items={SLIPPAGE_PRESETS.map((s) => ({
            label: s.label,
            value: String(s.bps),
          }))}
          onSelect={(it) => {
            const bps = Number(it.value);
            setPhase({
              kind: "quoting",
              ctx: { ...phase.ctx, slippageBps: bps },
            });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "quoting") {
    return (
      <QuoteStep
        ctx={phase.ctx}
        onResult={(amountOut, fee) =>
          setPhase({
            kind: "review-quote",
            ctx: phase.ctx,
            amountOut,
            fee,
          })
        }
        onError={(message) =>
          setPhase({ kind: "quote-error", ctx: phase.ctx, message })
        }
      />
    );
  }

  if (phase.kind === "quote-error") {
    return (
      <Layout title="Quote failed" hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  if (phase.kind === "review-quote") {
    const minOut =
      (phase.amountOut * BigInt(10000 - phase.ctx.slippageBps)) / 10000n;
    const advance = () =>
      setPhase({
        kind: "building",
        ctx: phase.ctx,
        amountOut: phase.amountOut,
        fee: phase.fee,
        slippageBps: phase.ctx.slippageBps,
      });
    const goBack = () =>
      setPhase({
        kind: "pick-slippage",
        ctx: phase.ctx,
      });
    return (
      <Layout
        title={`Quote: ${phase.ctx.from.symbol} → ${phase.ctx.to.symbol}`}
        subtitle={`${chainHeader(phase.ctx.chain, phase.ctx.chains, isR1)} · Uniswap V3 fee tier: ${(phase.fee / 10000).toFixed(2)}%`}
        hint="enter — build & confirm · → next · ← back · esc — cancel"
      >
        <BackOnEsc onDone={() => onDone(false)} />
        <ConfirmOnEnter onConfirm={advance} />
        {/* Pure review step — no input widget here, so wizard ←/→ is
            safe and matches user expectation. */}
        <WizardArrows onLeft={goBack} onRight={advance} />
        <Text>
          <Text color={theme.dim}>amount in:    </Text>
          {formatBaseUnits(phase.ctx.amountIn, phase.ctx.from.decimals)}{" "}
          {phase.ctx.from.symbol}
        </Text>
        <Text>
          <Text color={theme.dim}>amount out:   </Text>
          {formatBaseUnits(phase.amountOut, phase.ctx.to.decimals)}{" "}
          {phase.ctx.to.symbol}
        </Text>
        <Text>
          <Text color={theme.dim}>min received: </Text>
          {formatBaseUnits(minOut, phase.ctx.to.decimals)}{" "}
          {phase.ctx.to.symbol}{" "}
          <Text color={theme.dim}>
            (slippage {phase.ctx.slippageBps / 100}%)
          </Text>
        </Text>
        <Text>
          <Text color={theme.dim}>recipient:    </Text>
          {phase.ctx.recipient}
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "building") {
    const minOut =
      (phase.amountOut * BigInt(10000 - phase.slippageBps)) / 10000n;
    return (
      <BuildStep
        ctx={phase.ctx}
        amountOutMin={minOut}
        fee={phase.fee}
        onResult={(swap, approval) => {
          const summary =
            `${formatBaseUnits(phase.ctx.amountIn, phase.ctx.from.decimals)} ${phase.ctx.from.symbol} → ` +
            `≥${formatBaseUnits(minOut, phase.ctx.to.decimals)} ${phase.ctx.to.symbol}`;
          if (approval) {
            return setPhase({
              kind: "confirm-approval",
              ctx: phase.ctx,
              approval,
              swap,
              summary,
            });
          }
          setPhase({
            kind: "confirm-swap",
            ctx: phase.ctx,
            swap,
            summary,
          });
        }}
        onError={(message) =>
          setPhase({ kind: "build-error", ctx: phase.ctx, message })
        }
      />
    );
  }

  if (phase.kind === "build-error") {
    return (
      <Layout title="Build failed" hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  // Approval first. The daemon already determined approval is needed
  // (insufficient allowance vs. amountIn). We hand the {to,value,data}
  // off to SendRawFlow — the canonical ConfirmGate path. After
  // SendRawFlow returns success, we advance to the swap (NOT batched —
  // user re-confirms each tx).
  if (phase.kind === "confirm-approval") {
    return (
      <SendRawFlow
        chainId={phase.ctx.chain.chainId}
        wallet={sendRawWallet}
        tx={{
          ...phase.approval,
          rationale: `Approve Uniswap V3 router to spend ${phase.ctx.from.symbol}${
            isR1 ? " (R1: biometric prompt #1 of 2)" : " (required before swap)"
          }`,
        }}
        onDone={(success) => {
          if (!success) return onDone(false);
          setPhase({
            kind: "confirm-swap",
            ctx: phase.ctx,
            swap: phase.swap,
            summary: phase.summary,
          });
        }}
      />
    );
  }

  if (phase.kind === "confirm-swap") {
    return (
      <SendRawFlow
        chainId={phase.ctx.chain.chainId}
        wallet={sendRawWallet}
        tx={{
          ...phase.swap,
          rationale: `Uniswap V3 swap: ${phase.summary}`,
        }}
        onDone={(success) => {
          if (!success) return onDone(false);
          setPhase({
            kind: "done",
            summary: phase.summary,
          });
        }}
      />
    );
  }

  // phase.kind === "done"
  return (
    <Layout
      title="Swap complete"
      subtitle={phase.summary}
      hint="enter / esc — back to menu"
    >
      <Text color={theme.ok}>✓ swap submitted</Text>
      <BackOnInput onDone={() => onDone(true)} />
    </Layout>
  );
}

function QuoteStep({
  ctx,
  onResult,
  onError,
}: {
  ctx: SwapCtx;
  onResult: (amountOut: bigint, fee: number) => void;
  onError: (msg: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{
        amountOut: number | string;
        fee: number;
      }>("swap.uniV3.quote", {
        // chainId is a *string* on the daemon side (`ChainId.fromString?`
        // accepts "mainnet" / "sepolia"). Sending a number would silently
        // fall back to "mainnet" via paramStringD.
        chainId: ctx.chain.name,
        tokenIn: ctx.from.symbol,
        tokenOut: ctx.to.symbol,
        // amountIn must be a JSON integer string per the daemon's `asNat`
        // contract. BigInt is serialized correctly by daemon.ts.
        amountIn: ctx.amountIn,
      });
      if (cancelled) return;
      if (!r.ok) return onError(r.error.message);
      const amt = r.result?.amountOut;
      const fee = r.result?.fee;
      try {
        const amountOut = typeof amt === "bigint" ? amt : BigInt(amt as any);
        if (amountOut === 0n)
          return onError("quoter returned 0 — no liquidity for this pair");
        onResult(amountOut, Number(fee));
      } catch (e) {
        onError(`malformed quote response: ${String(e)}`);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Quoting…" subtitle={`${ctx.from.symbol} → ${ctx.to.symbol}`}>
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>
          asking the Uniswap V3 quoter (trying 0.05%, 0.3%, 1.0% fee tiers)
        </Text>
      </Text>
    </Layout>
  );
}

function BuildStep({
  ctx,
  amountOutMin,
  fee,
  onResult,
  onError,
}: {
  ctx: SwapCtx;
  amountOutMin: bigint;
  fee: number;
  onResult: (
    swap: { to: string; value: string; data: string },
    approval: { to: string; value: string; data: string } | null,
  ) => void;
  onError: (msg: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<any>("swap.uniV3.build", {
        chainId: ctx.chain.name,
        fromAddress: ctx.fromAddress,
        tokenIn: ctx.from.symbol,
        tokenOut: ctx.to.symbol,
        amountIn: ctx.amountIn,
        amountOutMin,
        fee,
        recipient: ctx.recipient,
      });
      if (cancelled) return;
      if (!r.ok) return onError(r.error.message);
      const txField = r.result?.tx;
      if (!txField || typeof txField.to !== "string") {
        return onError("daemon returned no swap tx");
      }
      const swap = {
        to: txField.to,
        value: bigintToHex(txField.value),
        data: typeof txField.data === "string" ? txField.data : "0x",
      };
      const a = r.result?.approval;
      const approval =
        a && typeof a === "object" && typeof a.to === "string"
          ? {
              to: a.to,
              value: bigintToHex(a.value),
              data: typeof a.data === "string" ? a.data : "0x",
            }
          : null;
      onResult(swap, approval);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout
      title="Building calldata…"
      subtitle="encoding exactInputSingle / approval"
    >
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>asking the daemon for swap.uniV3.build</Text>
      </Text>
    </Layout>
  );
}

/** The daemon emits `value` as a JSON integer; SendRawFlow's pipeline
 *  expects a hex string (it round-trips through hexToBigInt). Normalize
 *  here. Accepts bigint, number, string (decimal or hex), or null. */
function bigintToHex(v: unknown): string {
  if (v === null || v === undefined) return "0x0";
  if (typeof v === "string") {
    if (v.startsWith("0x") || v.startsWith("0X")) return v;
    try {
      return "0x" + BigInt(v).toString(16);
    } catch {
      return "0x0";
    }
  }
  if (typeof v === "number" || typeof v === "bigint") {
    try {
      return "0x" + BigInt(v).toString(16);
    } catch {
      return "0x0";
    }
  }
  return "0x0";
}

function stubCtx(
  chain: ChainEntry,
  chains: ChainEntry[],
  fromAddress: string,
  from: TokenItem,
  to: TokenItem,
  tokens: TokenItem[],
): SwapCtx {
  return {
    chain,
    chains,
    fromAddress,
    from,
    to,
    amountIn: 0n,
    recipient: fromAddress,
    slippageBps: 50,
    tokens,
  };
}

/** Render the chain header line shown in subtitles. Always communicates
 *  *which* chain we're on, plus a hint when toggling is available or
 *  blocked because no other chain has an RPC configured. For R1 wallets
 *  the list is sepolia-only — surface that explicitly so the user knows
 *  why `n` is a no-op. */
function chainHeader(
  chain: ChainEntry,
  chains: ChainEntry[],
  isR1: boolean = false,
): string {
  if (isR1) {
    return `chain ${chain.name} (sepolia only for R1 wallets)`;
  }
  const ready = chains.filter((c) => c.hasRpc);
  if (ready.length <= 1) {
    const others = chains
      .filter((c) => !c.hasRpc)
      .map((c) => c.name)
      .join(", ");
    return others.length > 0
      ? `chain ${chain.name} (only ${chain.name} configured · add ${others} via \`kohaku network set-rpc-chain ${chains.find((c) => !c.hasRpc)?.name ?? "<chain>"} <url>\`)`
      : `chain ${chain.name}`;
  }
  return `chain ${chain.name} (n to cycle)`;
}

/** Wizard-frame chain toggle. Listens for `n` (lowercase) and cycles to
 *  the next chain that has an RPC configured. No-op when only one chain
 *  has RPC, or when `enabled === false` (R1 wallets pin to sepolia).
 *  Does NOT consume up/down/enter/esc — those still belong to whatever
 *  sub-component is in focus. */
function ChainToggleOnN({
  chain,
  chains,
  onSwitch,
  enabled = true,
}: {
  chain: ChainEntry;
  chains: ChainEntry[];
  onSwitch: (next: ChainEntry) => void;
  enabled?: boolean;
}) {
  useInput((input) => {
    if (!enabled) return;
    if (input !== "n" && input !== "N") return;
    const ready = chains.filter((c) => c.hasRpc);
    if (ready.length <= 1) return;
    const idx = ready.findIndex((c) => c.name === chain.name);
    // ready.length ≥ 2 enforced by the guard above.
    onSwitch(ready[(idx + 1) % ready.length]!);
  });
  return null;
}

/** Wizard-frame ←/→ for review-style steps that have no embedded input
 *  widget consuming horizontal arrows. Pragmatic rule: only mount on
 *  phases between sub-components (review-quote). */
function WizardArrows({
  onLeft,
  onRight,
}: {
  onLeft: () => void;
  onRight: () => void;
}) {
  useInput((_, key) => {
    if (key.leftArrow) onLeft();
    else if (key.rightArrow) onRight();
  });
  return null;
}

/** Wizard-frame ← only — used on phases where → would skip a required
 *  selection (token-pick, slippage-pick): there is no valid "next" yet,
 *  so → is intentionally a no-op. */
function WizardLeftOnly({ onLeft }: { onLeft: () => void }) {
  useInput((_, key) => {
    if (key.leftArrow) onLeft();
  });
  return null;
}

function BackOnEsc({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.escape) onDone();
  });
  return null;
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}

function ConfirmOnEnter({ onConfirm }: { onConfirm: () => void }) {
  useInput((_, key) => {
    if (key.return) onConfirm();
  });
  return null;
}

/** Listens for `r` (lowercase or uppercase) on the from-picker phase
 *  and re-fetches `swap.balances` for the same address+chain. Does NOT
 *  collide with `n` (chain toggle); both keys are uniquely bound here.
 *  Disabled while a refresh is in flight to prevent fan-out storms. */
function RefreshBalancesOnR({
  chainName,
  address,
  enabled,
  onStart,
  onResult,
}: {
  chainName: string;
  address: string;
  enabled: boolean;
  onStart: () => void;
  onResult: (balances: BalanceMap | null) => void;
}) {
  useInput((input) => {
    if (!enabled) return;
    if (input !== "r" && input !== "R") return;
    onStart();
    (async () => {
      const r = await call<{
        balances: Array<{
          symbol: string;
          address: string | null;
          decimals: number;
          balance: string;
        }>;
      }>("swap.balances", { chainId: chainName, address });
      if (r.ok) {
        onResult(balanceArrayToMap(r.result?.balances ?? []));
      } else {
        // Fail-soft: keep old balances on transient RPC error so the
        // user doesn't lose context. Surface only by returning `null`
        // (caller chooses whether to overwrite).
        onResult(null);
      }
    })();
  });
  return null;
}
