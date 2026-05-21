import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { Wallet } from "../types.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import { theme } from "../theme.js";
import { formatEth, hexToBigInt, shortAddr } from "../format.js";
import { Action as WalletAction } from "./ActionPicker.js";

/** Maximum number of ERC-20 token rows to surface in the management
 *  view. The swap registry currently has ~10–15 tokens per chain so this
 *  is a soft cap — but the daemon's `swap.balances` fan-out is bounded
 *  in Lean, and we honor that bound TUI-side rather than rendering an
 *  unbounded list if the registry grows. */
const MAX_TOKEN_ROWS = 20;

type Token = {
  symbol: string;
  /** null for native ETH; we filter those out before rendering. */
  address: string | null;
  decimals: number;
  /** Raw hex balance from the daemon, parsed to bigint for sorting + display. */
  balanceWei: bigint;
};

type TokensCell =
  | { state: "loading" }
  | { state: "ok"; tokens: Token[] }
  | { state: "err"; message: string };

/** Sub-account row from `eoa.account.list`. */
type SubAccount = {
  index: number;
  path: string;
  address: string;
  label?: string | null;
};

type SubAcctsCell =
  | { state: "loading" }
  | { state: "ok"; primaryPath: string; accounts: SubAccount[] }
  | { state: "err"; message: string };

type Props = {
  wallet: Wallet;
  /** The chain selected in WalletsHub (mainnet/sepolia for EOAs; sepolia
   *  for TPM). Drives swap.balances + chain.balance. */
  chain: string;
  /** Jump to SendFlow with this ERC-20 pre-selected. */
  onSendToken: (token: { symbol: string; address: string; decimals: number }) => void;
  /** Dispatch one of the generic wallet ops (history / lock-toggle /
   *  reveal-mnemonic / details / balance-refresh / archive / add-account
   *  …) by reusing the existing WalletAction switch in App.tsx. */
  onAction: (a: WalletAction) => void;
  onDone: () => void;
};

/** Per-wallet management surface. Replaces the old CUSTOM tab's generic
 *  ActionPicker with a kind-aware view:
 *    EOA → BIP-44 derivation path of the primary + cousin sub-accounts
 *          (from `eoa.account.list`), each rendered as a row.
 *    TPM → minimal info card (single-key, no derivation tree).
 *  Below the kind block, every wallet sees a Tokens section: a parallel
 *  `swap.balances` fan-out filters the swap registry down to entries
 *  the wallet actually holds. Tokens with `balance > 0` become rows;
 *  selecting one fires SEND with the token preselected so the user can
 *  transfer ERC-20s without going through SWAP. */
export default function ManageWalletScreen({
  wallet,
  chain,
  onSendToken,
  onAction,
  onDone,
}: Props) {
  const [tokens, setTokens] = useState<TokensCell>({ state: "loading" });
  const [subs, setSubs] = useState<SubAcctsCell>({ state: "loading" });

  // Sub-account fan-out (EOA only). Runs in parallel with the token
  // fan-out below — neither blocks the other, so a slow swap.balances
  // doesn't keep the BIP-44 tree hidden.
  useEffect(() => {
    if (wallet.kind !== "eoa") {
      setSubs({ state: "ok", primaryPath: "", accounts: [] });
      return;
    }
    let cancelled = false;
    void (async () => {
      // Why: `eoa.account.list` returns ALL accounts including index 0;
      // we surface the primary's path as the header line and treat
      // the rest as cousins.
      const r = await call<{
        accounts: SubAccount[];
      }>("eoa.account.list", { name: wallet.name });
      if (cancelled) return;
      if (!r.ok) {
        setSubs({ state: "err", message: r.error.message });
        return;
      }
      const list = r.result?.accounts ?? [];
      const primary = list.find((a) => a.index === 0);
      const cousins = list.filter((a) => a.index !== 0);
      setSubs({
        state: "ok",
        primaryPath: primary?.path ?? "m/44'/60'/0'/0/0",
        accounts: cousins,
      });
    })();
    return () => {
      cancelled = true;
    };
  }, [wallet.kind, wallet.name]);

  // Token discovery via `swap.balances`. The daemon already fans out
  // ERC-20 balanceOf + native eth_getBalance in parallel (one IO.asTask
  // per token); we just await its single response. Fail-soft: if the
  // call errors we surface the message; per-token reverts are dropped
  // daemon-side and never reach us.
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const b = await call<{
        balances: Array<{
          symbol: string;
          address: string | null;
          decimals: number;
          balance: string;
        }>;
      }>("swap.balances", { chainId: chain, address: wallet.address });
      if (cancelled) return;
      if (!b.ok) {
        setTokens({ state: "err", message: b.error.message });
        return;
      }
      const all = (b.result?.balances ?? [])
        .map((e) => ({
          symbol: String(e.symbol ?? "").toUpperCase(),
          address: typeof e.address === "string" ? e.address : null,
          decimals: typeof e.decimals === "number" ? e.decimals : 18,
          balanceWei: hexToBigInt(e.balance),
        }))
        // Native ETH is shown in the row header above; only ERC-20 entries
        // go in this section.
        .filter((t) => t.address !== null)
        // List-if-balance-exists rule: a token only takes a row when the
        // user actually has some. Zero-balance registry entries are
        // hidden — picking SEND there would be a no-op.
        .filter((t) => t.balanceWei > 0n)
        // Cap to MAX_TOKEN_ROWS. Sort by balance desc first so the cap
        // keeps the most-held tokens visible.
        .sort((a, b) =>
          a.balanceWei === b.balanceWei
            ? a.symbol.localeCompare(b.symbol)
            : a.balanceWei > b.balanceWei
              ? -1
              : 1,
        )
        .slice(0, MAX_TOKEN_ROWS);
      setTokens({ state: "ok", tokens: all });
    })();
    return () => {
      cancelled = true;
    };
  }, [chain, wallet.address]);

  useInput((input, key) => {
    if (key.escape || input === "q") onDone();
    // Single-char shortcuts to the most common ops. Mirrors the original
    // CUSTOM-tab ActionPicker so muscle memory carries over.
    else if (input === "h") onAction("history");
    else if (input === "d") onAction("details");
    else if (input === "r") onAction("balance-refresh");
    else if (input === "l" && wallet.kind === "eoa") onAction("lock-toggle");
    else if (input === "a" && wallet.kind === "eoa") onAction("add-account");
  });

  const balanceLine =
    wallet.balanceWei !== undefined
      ? formatEth(wallet.balanceWei)
      : "(balance pending)";

  const tokenItems = buildTokenItems(tokens);

  return (
    <Layout
      title={`Manage ${wallet.name}`}
      subtitle={`${shortAddr(wallet.address)} · ${balanceLine} · ${chain}`}
      hint="↑/↓ token · enter — send token · h history · d details · r refresh · l lock · a add-account · esc back"
    >
      {wallet.kind === "eoa" && <EoaBlock wallet={wallet} subs={subs} />}
      {wallet.kind === "tpm" && <TpmBlock wallet={wallet} />}
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.primary} bold>
          Tokens (swap registry)
        </Text>
        {tokens.state === "loading" && (
          <Text>
            <Text color={theme.primary}>
              <Spinner type="dots" />
            </Text>{" "}
            <Text color={theme.dim}>
              fanning out balanceOf across the swap registry…
            </Text>
          </Text>
        )}
        {tokens.state === "err" && (
          <Banner kind="err" text={`swap.balances failed: ${tokens.message}`} />
        )}
        {tokens.state === "ok" && tokens.tokens.length === 0 && (
          <Text color={theme.dim}>
            no ERC-20 balances detected on the swap registry for this wallet on{" "}
            {chain}.
          </Text>
        )}
        {tokens.state === "ok" && tokens.tokens.length > 0 && (
          <Select
            items={tokenItems}
            onSelect={(it) => {
              const cast = it as (typeof tokenItems)[number];
              if (!cast.__token) return;
              onSendToken({
                symbol: cast.__token.symbol,
                address: cast.__token.address!,
                decimals: cast.__token.decimals,
              });
            }}
          />
        )}
      </Box>
    </Layout>
  );
}

function EoaBlock({
  wallet,
  subs,
}: {
  wallet: Wallet;
  subs: SubAcctsCell;
}) {
  return (
    <Box flexDirection="column">
      <Text color={theme.primary} bold>
        EOA (BIP-39 / BIP-44)
      </Text>
      {subs.state === "loading" && (
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>loading BIP-44 tree…</Text>
        </Text>
      )}
      {subs.state === "err" && (
        <Banner kind="err" text={`eoa.account.list failed: ${subs.message}`} />
      )}
      {subs.state === "ok" && (
        <Box flexDirection="column">
          <Text>
            <Text color={theme.dim}>primary path </Text>
            <Text>{subs.primaryPath}</Text>
          </Text>
          <Text>
            <Text color={theme.dim}>primary addr </Text>
            <Text>{wallet.address}</Text>
          </Text>
          {subs.accounts.length === 0 ? (
            <Text color={theme.dim}>
              no cousin accounts — press `a` to derive one (BIP-32 hardened branch).
            </Text>
          ) : (
            <Box flexDirection="column" marginTop={1}>
              <Text color={theme.dim}>cousins ({subs.accounts.length}):</Text>
              {subs.accounts.map((a) => (
                <Text key={a.index}>
                  <Text color={theme.dim}>{`  ↳ #${a.index} `}</Text>
                  <Text>{(a.label ?? "").padEnd(10)}</Text>{" "}
                  <Text color={theme.dim}>{a.path}</Text>{" "}
                  <Text>{a.address}</Text>
                </Text>
              ))}
            </Box>
          )}
        </Box>
      )}
    </Box>
  );
}

function TpmBlock({ wallet }: { wallet: Wallet }) {
  return (
    <Box flexDirection="column">
      <Text color={theme.primary} bold>
        TPM / R1 (P-256 hardware key)
      </Text>
      <Text>
        <Text color={theme.dim}>name </Text>
        <Text>{wallet.name}</Text>
      </Text>
      <Text>
        <Text color={theme.dim}>addr </Text>
        <Text>{wallet.address}</Text>
      </Text>
      <Text color={theme.dim}>
        TPM keys are single-purpose: no BIP-44 derivation, no cousins. Rotation
        requires re-enrolling a fresh TPM-bound key.
      </Text>
    </Box>
  );
}

function buildTokenItems(tokens: TokensCell): Array<{
  label: string;
  value: string;
  __token?: Token;
}> {
  if (tokens.state !== "ok") return [];
  return tokens.tokens.map((t) => {
    const amount = formatTokenAmount(t.balanceWei, t.decimals);
    return {
      label: `${t.symbol.padEnd(8)} ${amount.padStart(20)}  ${t.address}`,
      value: `${t.symbol}:${t.address}`,
      __token: t,
    };
  });
}

/** Format a base-units balance with up to 6 trimmed fractional digits.
 *  Truncates (not rounds) so we never display more than the wallet
 *  actually holds. Symmetric with SwapFlow's `formatBalanceShort`; kept
 *  local rather than imported to avoid pulling SwapFlow's whole module
 *  for one helper. */
function formatTokenAmount(amount: bigint, decimals: number): string {
  if (decimals === 0) return amount.toString();
  const base = 10n ** BigInt(decimals);
  const whole = amount / base;
  const frac = amount % base;
  if (frac === 0n) return whole.toString();
  let fracStr = frac.toString().padStart(decimals, "0");
  if (fracStr.length > 6) fracStr = fracStr.slice(0, 6);
  fracStr = fracStr.replace(/0+$/, "");
  return fracStr.length === 0 ? whole.toString() : `${whole.toString()}.${fracStr}`;
}
