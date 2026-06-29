import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { AddressFreshness, ChainBalance, Wallet } from "../types.js";
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

/** One protocol's entry from `defi.positions`. Aave V3 is queried on-chain
 *  (getUserAccountData); Morpho/Curve arrive as `available:false` "coming
 *  soon" until an index path exists. Base amounts are canonical 0x-hex
 *  strings (they exceed 2^53), parsed to bigint here for display. */
type DefiProtocol = {
  protocol: string;
  available: boolean;
  note?: string;
  hasPosition?: boolean;
  /** Decimals of the market base currency (USD ⇒ 8). */
  baseCurrencyDecimals?: number;
  totalCollateralBase?: string;
  totalDebtBase?: string;
  availableBorrowsBase?: string;
  /** 1e18-scaled; uint256-max sentinel when there's no debt. */
  healthFactor?: string;
  reserves?: Array<{
    symbol?: string;
    decimals?: number;
    supplied?: string;
    borrowed?: string;
  }>;
};

type DefiCell =
  | { state: "loading" }
  | { state: "ok"; protocols: DefiProtocol[] }
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

type EthCell =
  | { state: "loading" }
  | { state: "ok"; wei: bigint }
  | { state: "err"; message: string };

/** Local TxJournal entry as returned by `chain.history`. Fields are
 *  best-effort: blockNumber/status/gasUsed are only set after a
 *  successful receipt poll; the array is newest-last per slot. */
type JournalEntry = {
  timestamp: number;
  txHash: string;
  from: string;
  to: string;
  valueWei: string;
  kind: string;
  status?: string;
  blockNumber?: string;
};

type HistoryCell =
  | { state: "loading" }
  | { state: "ok"; entries: JournalEntry[] }
  | { state: "err"; message: string };

/** Cap the right-panel render. The daemon keeps the full ndjson on
 *  disk; pressing `h` jumps to the dedicated HistoryScreen for the
 *  longer list. */
const HISTORY_PANEL_LIMIT = 8;

/** Privacy score derived from `chain.addressFreshness` + native balance.
 *  Rule (matches WalletsHub's `isZeroLink`): the address scores 1° iff
 *  pending nonce = 0 AND no ERC-20 Transfer events involving it in the
 *  lookback window AND (balance = 0 OR this daemon previously
 *  unshielded to it). Any link drops the score to 0°. */
type PrivacyCell =
  | { state: "loading" }
  | { state: "err" }
  | {
      state: "ok";
      score: 0 | 1;
      /** Why the score landed where it did — surfaced as a sub-line so
       *  the user can audit. "PP-funded" reuses Privacy-Pools language. */
      reason: string;
    };

type Props = {
  wallet: Wallet;
  /** The chain selected in WalletsHub (mainnet/sepolia for EOAs).
   *  Drives swap.balances + chain.balance. */
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
  const [defi, setDefi] = useState<DefiCell>({ state: "loading" });
  const [subs, setSubs] = useState<SubAcctsCell>({ state: "loading" });
  const [eth, setEth] = useState<EthCell>({ state: "loading" });
  const [privacy, setPrivacy] = useState<PrivacyCell>({ state: "loading" });
  const [history, setHistory] = useState<HistoryCell>({ state: "loading" });

  // Native ETH balance + freshness fan-out. Run in parallel with the
  // token + sub-account fetches above so the header repaints as soon
  // as the cheapest call lands. The freshness probe drives the privacy
  // score; it needs the eth-balance result to disambiguate "0-link
  // PP-funded" from "0-link with on-chain balance" — so the privacy
  // computation waits on BOTH and runs once they're in.
  useEffect(() => {
    let cancelled = false;
    const params = { address: wallet.address, chain };
    // ETH balance — fire and forget; result lands in `eth`.
    void call<ChainBalance>("chain.balance", params).then((r) => {
      if (cancelled) return;
      if (!r.ok) {
        setEth({ state: "err", message: r.error.message });
        return;
      }
      setEth({ state: "ok", wei: hexToBigInt(r.result?.balance) });
    });
    // Freshness — independent. Combined with `eth` below to produce
    // the final score.
    void call<AddressFreshness>("chain.addressFreshness", params).then((fr) => {
      if (cancelled) return;
      if (!fr.ok) {
        setPrivacy({ state: "err" });
        return;
      }
      const d = fr.result;
      if (!d || typeof d.nonce !== "number") {
        setPrivacy({ state: "err" });
        return;
      }
      // Stash the freshness fields on a closure-local marker; the
      // settling effect below joins them with the eth result. We model
      // this as a transient "loading w/ partial data" by reusing the
      // state shape — store the partial-evaluated score now and let
      // the eth-arrival effect finalize the "balance=0" branch.
      const ppFunded = d.ppFunded === true;
      const nonce = d.nonce;
      const erc20Clean =
        d.available === true &&
        (d.erc20OutCount ?? 0) === 0 &&
        (d.erc20InCount ?? 0) === 0;
      // We need eth to finalize the score. Set a sentinel; the
      // joining effect below picks this up.
      setPrivacyFreshness({ nonce, erc20Clean, ppFunded, available: d.available === true });
    });
    return () => {
      cancelled = true;
    };
  }, [wallet.address, chain]);

  // Freshness fields landed but score is finalized only once we also
  // have the ETH balance (the "0-link" rule folds in balance=0 OR
  // PP-funded). Kept in its own state cell rather than threaded
  // through `privacy` so the freshness probe can return without
  // blocking the eth call.
  const [privacyFreshness, setPrivacyFreshness] = useState<
    | null
    | { nonce: number; erc20Clean: boolean; ppFunded: boolean; available: boolean }
  >(null);

  useEffect(() => {
    if (!privacyFreshness) return;
    if (eth.state === "loading") return;
    // Compute final score. Mirrors WalletsHub's `isZeroLink`:
    //   nonce=0 AND erc20Clean AND (balance=0 OR ppFunded) ⇒ 1° (0-link).
    //   Any link OR freshness unavailable ⇒ 0° (or err if eth errored).
    if (eth.state === "err") {
      setPrivacy({ state: "err" });
      return;
    }
    if (!privacyFreshness.available) {
      setPrivacy({
        state: "ok",
        score: 0,
        reason: "freshness scan unavailable — RPC capped getLogs",
      });
      return;
    }
    const { nonce, erc20Clean, ppFunded } = privacyFreshness;
    const balZero = eth.wei === 0n;
    if (nonce === 0 && erc20Clean && (balZero || ppFunded)) {
      setPrivacy({
        state: "ok",
        score: 1,
        reason: ppFunded && !balZero
          ? "0-link · PP-funded receiver"
          : "0-link · fresh address (no on-chain history)",
      });
    } else {
      // Spell out which condition tripped so the user knows what to do
      // about it (rotate, unshield, etc.).
      const reasons: string[] = [];
      if (nonce !== 0) reasons.push(`nonce=${nonce}`);
      if (!erc20Clean) reasons.push("ERC-20 transfers in window");
      if (!balZero && !ppFunded) reasons.push("non-zero ETH balance");
      setPrivacy({
        state: "ok",
        score: 0,
        reason: `linked · ${reasons.join(" · ") || "see freshness probe"}`,
      });
    }
  }, [privacyFreshness, eth]);

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

  // Local TxJournal fan-out. Slot-scoped (`name` is the slot), so a
  // sub-account view shows the whole slot's actions — same shape as
  // the dedicated HistoryScreen behind the `h` shortcut. Newest-last in
  // the file; we reverse for display so the freshest action is on top.
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const r = await call<JournalEntry[]>("chain.history", {
        name: wallet.name,
        limit: HISTORY_PANEL_LIMIT,
      });
      if (cancelled) return;
      if (!r.ok) {
        setHistory({ state: "err", message: r.error.message });
        return;
      }
      const arr = Array.isArray(r.result) ? r.result : [];
      setHistory({ state: "ok", entries: [...arr].reverse() });
    })();
    return () => {
      cancelled = true;
    };
  }, [wallet.name]);

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

  // DeFi-holdings fan-out via `defi.positions`. Read-only: the daemon
  // eth_calls Aave V3's getUserAccountData (policy-gated, like
  // swap.balances) and decodes it in Lean; Morpho/Curve come back as
  // available:false "coming soon". Runs in parallel with the token
  // fan-out so a slow protocol read never blocks the token list.
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const r = await call<{ protocols: DefiProtocol[] }>("defi.positions", {
        chainId: chain,
        address: wallet.address,
      });
      if (cancelled) return;
      if (!r.ok) {
        setDefi({ state: "err", message: r.error.message });
        return;
      }
      setDefi({ state: "ok", protocols: r.result?.protocols ?? [] });
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
    else if (input === "u" && wallet.kind === "eoa") onAction("unstick");
  });

  // Header subtitle prefers our locally-loaded eth balance; falls back
  // to the wallet.balanceWei the hub may have already populated; finally
  // to a pending tick. This way landing on the manage screen always
  // reflects the freshest read, even if WalletsHub's parallel fan-out
  // was still in flight when the user pressed enter.
  const balanceLine =
    eth.state === "ok"
      ? formatEth(eth.wei)
      : wallet.balanceWei !== undefined
        ? formatEth(wallet.balanceWei)
        : "(balance pending)";

  const tokenItems = buildTokenItems(tokens);

  return (
    <Layout
      title={`Manage ${wallet.name}`}
      subtitle={`${shortAddr(wallet.address)} · ${balanceLine} · ${chain}`}
      hint={`↑/↓ token · enter — send token · h history · d details · r refresh${wallet.kind === "eoa" ? " · l lock · a add-account · u unstick-nonce" : ""} · esc back`}
    >
      <Box flexDirection="row">
        <Box flexDirection="column" flexGrow={1} flexBasis={0} minWidth={0}>
          {wallet.kind === "eoa" && <EoaBlock wallet={wallet} subs={subs} />}
          <Box marginTop={1} flexDirection="column">
            <Text color={theme.primary} bold>
              Native balance + privacy
            </Text>
            <NativeRow eth={eth} chain={chain} />
            <PrivacyRow privacy={privacy} />
          </Box>
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
          <Box marginTop={1} flexDirection="column">
            <Text color={theme.primary} bold>
              DeFi positions
            </Text>
            <DefiSection defi={defi} />
          </Box>
        </Box>
        <Box
          marginLeft={2}
          flexDirection="column"
          flexGrow={1}
          flexBasis={0}
          minWidth={0}
        >
          <HistoryPanel history={history} />
        </Box>
      </Box>
    </Layout>
  );
}

/** Right-side recent-actions panel. Sources from `chain.history` (the
 *  local TxJournal — every send/sphincs-userop/shielded prepare appends
 *  one row), so this surfaces actions taken through *this* daemon
 *  rather than a full on-chain transfer scan. Press `h` for the
 *  full-length HistoryScreen. */
function HistoryPanel({ history }: { history: HistoryCell }) {
  return (
    <Box flexDirection="column">
      <Text color={theme.primary} bold>
        Recent actions
      </Text>
      <Text color={theme.dim}>(local journal · press `h` for full view)</Text>
      {history.state === "loading" && (
        <Box marginTop={1}>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>
          <Text color={theme.dim}>{" reading journal…"}</Text>
        </Box>
      )}
      {history.state === "err" && (
        <Box marginTop={1}>
          <Banner kind="err" text={`chain.history failed: ${history.message}`} />
        </Box>
      )}
      {history.state === "ok" && history.entries.length === 0 && (
        <Box marginTop={1}>
          <Text color={theme.dim}>no journal entries for this slot yet.</Text>
        </Box>
      )}
      {history.state === "ok" && history.entries.length > 0 && (
        <Box flexDirection="column" marginTop={1}>
          {history.entries.map((e, i) => (
            <CompactHistoryRow key={i} entry={e} />
          ))}
        </Box>
      )}
    </Box>
  );
}

/** Three-line compact row: status+kind+value · short to · short tx.
 *  Tighter than HistoryScreen's `HistoryRow` so several entries fit
 *  in the side panel without crowding out the left column. */
function CompactHistoryRow({ entry }: { entry: JournalEntry }) {
  const status = entry.status ?? "?";
  const glyph = status === "success" ? "✓" : status === "revert" ? "✗" : "·";
  const glyphColor =
    status === "success" ? theme.ok : status === "revert" ? theme.err : theme.warn;
  let valueWei = 0n;
  try {
    valueWei = entry.valueWei ? BigInt(entry.valueWei) : 0n;
  } catch {}
  const when =
    entry.timestamp > 0
      ? new Date(entry.timestamp * 1000).toISOString().slice(0, 16).replace("T", " ")
      : "";
  return (
    <Box flexDirection="column" marginBottom={1}>
      <Box>
        <Text color={glyphColor} bold>
          {glyph}
        </Text>
        <Text> </Text>
        <Text color={theme.accent}>{entry.kind || "?"}</Text>
        {valueWei > 0n && (
          <>
            <Text>{"  "}</Text>
            <Text bold color={theme.primary}>
              {formatEth(valueWei)}
            </Text>
          </>
        )}
        {when && (
          <>
            <Text>{"  "}</Text>
            <Text color={theme.dim}>{when}</Text>
          </>
        )}
      </Box>
      {entry.to && (
        <Box>
          <Text color={theme.dim}>{"  to "}</Text>
          <Text>{shortAddr(entry.to)}</Text>
        </Box>
      )}
      {entry.txHash && (
        <Box>
          <Text color={theme.dim}>{"  tx "}</Text>
          <Text color={theme.dim}>{entry.txHash}</Text>
        </Box>
      )}
    </Box>
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

function NativeRow({ eth, chain }: { eth: EthCell; chain: string }) {
  if (eth.state === "loading") {
    return (
      <Text>
        <Text color={theme.dim}>{`${chain.padEnd(8)} `}</Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>loading ETH balance…</Text>
      </Text>
    );
  }
  if (eth.state === "err") {
    return (
      <Text>
        <Text color={theme.dim}>{`${chain.padEnd(8)} `}</Text>
        <Text color={theme.err}>err: {eth.message.slice(0, 80)}</Text>
      </Text>
    );
  }
  return (
    <Text>
      <Text color={theme.dim}>{`${chain.padEnd(8)} `}</Text>
      <Text>{formatEth(eth.wei)}</Text>
    </Text>
  );
}

/** Render the privacy score as `N°` plus a one-line reason. 1° == fully
 *  unlinked (0-link in the rest of the TUI's language); 0° == any
 *  on-chain link from this address. Errors render as "?°" so the user
 *  can tell "probe failed" apart from "we know it's linked". */
function PrivacyRow({ privacy }: { privacy: PrivacyCell }) {
  if (privacy.state === "loading") {
    return (
      <Text>
        <Text color={theme.dim}>privacy </Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>scoring address…</Text>
      </Text>
    );
  }
  if (privacy.state === "err") {
    return (
      <Text>
        <Text color={theme.dim}>privacy </Text>
        <Text color={theme.warn}>?°</Text>
        <Text color={theme.dim}> (freshness probe failed)</Text>
      </Text>
    );
  }
  const color = privacy.score === 1 ? theme.ok : theme.dim;
  return (
    <Text>
      <Text color={theme.dim}>privacy </Text>
      <Text color={color} bold>
        {privacy.score}°
      </Text>
      <Text color={theme.dim}> · {privacy.reason}</Text>
    </Text>
  );
}

/** DeFi-holdings block. One row per protocol: Aave V3 prefers token
 *  supplied/borrowed rows plus health factor; Morpho/Curve render
 *  their "coming soon" note. Read-only — selecting a row does nothing
 *  (positions are managed through the chat/agent flow, not here). */
function DefiSection({ defi }: { defi: DefiCell }) {
  if (defi.state === "loading") {
    return (
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>querying Aave position…</Text>
      </Text>
    );
  }
  if (defi.state === "err") {
    return <Banner kind="err" text={`defi.positions failed: ${defi.message}`} />;
  }
  if (defi.protocols.length === 0) {
    return <Text color={theme.dim}>no DeFi protocols reported.</Text>;
  }
  return (
    <Box flexDirection="column">
      {defi.protocols.map((p) => (
        <DefiProtocolRow key={p.protocol} p={p} />
      ))}
    </Box>
  );
}

/** Human label for a protocol id from the daemon (`aave-v3` → `Aave V3`). */
function labelForProtocol(id: string): string {
  switch (id) {
    case "aave-v3":
      return "Aave V3";
    case "morpho":
      return "Morpho";
    case "curve":
      return "Curve";
    default:
      return id;
  }
}

function DefiProtocolRow({ p }: { p: DefiProtocol }) {
  const name = labelForProtocol(p.protocol).padEnd(9);
  // Unavailable (undeployed chain, read error, or "coming soon") → dim note.
  if (!p.available) {
    return (
      <Text>
        <Text color={theme.dim}>{name} </Text>
        <Text color={theme.dim}>{p.note ?? "unavailable"}</Text>
      </Text>
    );
  }
  // Available but fresh/empty → no position rather than HF ∞.
  if (!p.hasPosition) {
    return (
      <Text>
        <Text>{name} </Text>
        <Text color={theme.dim}>no open position</Text>
      </Text>
    );
  }
  const dec = p.baseCurrencyDecimals ?? 8;
  const collateral = formatUsdBase(p.totalCollateralBase, dec);
  const debt = formatUsdBase(p.totalDebtBase, dec);
  const suppliedTokens = formatAaveReserveSide(p.reserves, "supplied");
  const borrowedTokens = formatAaveReserveSide(p.reserves, "borrowed");
  const hf = formatHealthFactor(p.healthFactor, p.totalDebtBase);
  return (
    <Text>
      <Text>{name} </Text>
      <Text color={theme.dim}>supplied </Text>
      <Text>{suppliedTokens ?? collateral}</Text>
      <Text color={theme.dim}> · borrowed </Text>
      <Text>{borrowedTokens ?? debt}</Text>
      <Text color={theme.dim}> · HF </Text>
      <Text color={healthFactorColor(hf)} bold>
        {hf}
      </Text>
    </Text>
  );
}

function formatAaveReserveSide(
  reserves: DefiProtocol["reserves"] | undefined,
  side: "supplied" | "borrowed",
): string | null {
  const parts = (reserves ?? [])
    .map((r) => {
      const raw = side === "supplied" ? r.supplied : r.borrowed;
      if (!raw) return null;
      const amount = hexToBigInt(raw);
      if (amount === 0n) return null;
      return `${formatTokenAmount(amount, r.decimals ?? 18)} ${r.symbol ?? "token"}`;
    })
    .filter((x): x is string => !!x);
  return parts.length > 0 ? parts.join(" · ") : null;
}

/** Format a base-currency `uint256` (0x-hex) as a `$` amount with 2
 *  fractional digits. Aave's base ccy is USD with 8 decimals. */
function formatUsdBase(hex: string | undefined, decimals: number): string {
  if (!hex) return "$0.00";
  const v = hexToBigInt(hex);
  const base = 10n ** BigInt(decimals);
  const whole = v / base;
  const cents = ((v % base) * 100n) / base;
  return `$${whole.toString()}.${cents.toString().padStart(2, "0")}`;
}

/** Format the 1e18-scaled health factor to 2 dp. With zero debt the Pool
 *  returns uint256-max, so we short-circuit to ∞ off the debt field rather
 *  than rendering an astronomically large number. */
function formatHealthFactor(
  hfHex: string | undefined,
  debtHex: string | undefined,
): string {
  if (!debtHex || hexToBigInt(debtHex) === 0n) return "∞";
  if (!hfHex) return "?";
  const hf = hexToBigInt(hfHex);
  const base = 10n ** 18n;
  const whole = hf / base;
  const frac = ((hf % base) * 100n) / base;
  return `${whole.toString()}.${frac.toString().padStart(2, "0")}`;
}

/** Health-factor risk colour: ∞ / comfortable → ok, thin → warn, near
 *  liquidation (< 1.1) → err. */
function healthFactorColor(hf: string): string {
  if (hf === "∞") return theme.ok;
  const n = Number(hf);
  if (!Number.isFinite(n)) return theme.dim;
  if (n < 1.1) return theme.err;
  if (n < 1.5) return theme.warn;
  return theme.ok;
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
