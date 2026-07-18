import { useEffect, useRef, useState } from "react";
import { call } from "../daemon.js";
import { hexToBigInt } from "../format.js";
import { usePoll } from "./poll.js";

/**
 * Wallet-box data. Cadence is deliberately tiered by cost:
 *
 *  - enumeration (`account.list` + `eoa.list`)  — on mount / manual `r`.
 *    account.list is the single unified enumerator (eoa/sphincs);
 *    eoa.list adds lock state. NOTE the daemon emits `locked` (
 *    Helpers.lean slotMetadataJson) — NOT the `unlocked` field the old
 *    TUI type guessed at — so we read `locked` and invert.
 *  - native balances (`chain.balance`)          — sequential, every 60s
 *    poll tick (single eth_getBalance, routed through the active provider
 *    so it's consensus-verified under provider=helios; falls back to
 *    direct RPC if the light client is down).
 *  - ERC-20 (`swap.balances`)                   — SLOWEST tier, every 300s
 *    (+ manual `r`). It's a large verified eth_call fan-out (one balanceOf
 *    per registry token per wallet), so it gets its own tier far above the
 *    60s balance loop; the wallet pane renders the non-zero rows per
 *    wallet when the pane has spare height.
 *  - shielded (railgun + privacy pools)         — ON DEMAND only (`s`).
 *    Both spawn the privacy sidecar and can take 30-60s+ on first call
 *    (Subsquid sync / POI fetch) and require an unlocked wallet. They
 *    must never sit on a poll loop.
 *
 * chain.addressFreshness (2x address-less eth_getLogs per address) is
 * deliberately NOT fetched here — too heavy for a dashboard loop.
 */

export type TokenBalance = { symbol: string; decimals: number; balance: bigint };
export type AaveReserveBalance = {
  symbol: string;
  decimals: number;
  supplied: bigint;
  borrowed: bigint;
};

/** Compact Aave V3 position for the dashboard row, derived from
 *  `defi.positions`. `null` once fetched but the wallet holds no Aave
 *  position (or the read was unavailable); `undefined` until first load. */
export type AaveSummary = {
  /** base-currency (USD, `baseDecimals`) collateral / debt as raw uint256. */
  collateralBase: bigint;
  debtBase: bigint;
  /** 1e18-scaled health factor (uint256-max sentinel when debt = 0). */
  healthFactor: bigint;
  baseDecimals: number;
  reserves: AaveReserveBalance[];
};

export type WalletRow = {
  kind: "eoa" | "sphincs";
  name: string;
  address: string;
  /** chain used for this row's balance reads. */
  chain: string;
  locked?: boolean;
  wei?: bigint;
  balErr?: string;
  tokens?: TokenBalance[];
  /** Aave V3 position summary; null = none/unavailable, undefined = pending. */
  defiAave?: AaveSummary | null;
};

/** StateVault (partial state node) summary for the wallet pane's vault
 *  line, from `vault.status`. A LOCAL-ONLY read (SQLite behind the
 *  daemon socket, no network round-trip), so it can ride a poll loop
 *  without fighting the verified-read budget. `null` = daemon has no
 *  vault.* family yet (older daemon) or the read failed — the pane
 *  simply omits the line. */
export type VaultSummary = {
  enabled: boolean;
  tokens: number;
  accounts: number;
  slots: number;
  headers: number;
  /** Latest pinned head for the active chain; null until first
   *  `vault head` / `vault pin`. */
  head: { block: number; tier: string } | null;
};

export type ShieldedState =
  | { kind: "idle" }
  | { kind: "syncing" }
  | {
      kind: "done";
      railgun: { count: number; lines: string[] } | { err: string };
      pp: { count: number; lines: string[] } | { err: string };
    };

export type WalletData = {
  rows: WalletRow[];
  /** rows beyond the display cap, mentioned in the footer line. */
  droppedRows: number;
  enumErr: string | null;
  shielded: ShieldedState;
  /** Partial-state-node summary; null until loaded / when unsupported. */
  vault: VaultSummary | null;
  refresh: () => void;
  syncShielded: () => void;
};

// ── Shared cache ──────────────────────────────────────────────────────
// The dashboard's `useWalletData` is the single balance/token poller. Other
// screens mounted alongside it (notably the SPHINCS account hub, which App
// renders as a dashboard sub-flow while the Dashboard stays mounted) read
// its already-fetched balances from this module singleton instead of firing
// their own slow verified `chain.balance` / `swap.balances` reads. It is a
// display-only cache; nothing here feeds a signing decision.
let sharedWalletData: WalletData | null = null;
const sharedListeners = new Set<() => void>();

function publishWalletData(d: WalletData): void {
  sharedWalletData = d;
  for (const l of sharedListeners) l();
}

/** Subscribe to the dashboard's live wallet data. Returns `null` when the
 *  dashboard poller isn't mounted (e.g. a full-screen route), so callers
 *  fall back to their own reads. */
export function useSharedWalletData(): WalletData | null {
  const [, force] = useState(0);
  useEffect(() => {
    const l = () => force((x) => x + 1);
    sharedListeners.add(l);
    // Re-read on mount in case data landed before we subscribed.
    l();
    return () => {
      sharedListeners.delete(l);
    };
  }, []);
  return sharedWalletData;
}

/** Find the poller's cached row for a smart-account / EOA address (case
 *  insensitive). `null` if the cache is empty or the address isn't in the
 *  current chain's enumerated set. */
export function sharedRowFor(
  data: WalletData | null,
  address: string | null | undefined,
): WalletRow | null {
  if (!data || !address) return null;
  const a = address.toLowerCase();
  return data.rows.find((r) => r.address?.toLowerCase() === a) ?? null;
}

const ROW_CAP = 6;

type AccountEntry = { type: string; name: string; address: string };

/** Best-effort, display-only rendering of one opaque shielded-balance
 *  entry. The daemon forwards the upstream plugin's per-asset entries
 *  verbatim (ShieldedRpc.lean does not reshape), so we probe the common
 *  field names and fall back to a clipped JSON dump. */
function describeShieldedEntry(e: unknown): string {
  if (e === null || typeof e !== "object") return String(e);
  const o = e as Record<string, unknown>;
  const sym =
    typeof o.symbol === "string" ? o.symbol
    : typeof o.tokenSymbol === "string" ? o.tokenSymbol
    : typeof o.asset === "string" ? `${(o.asset as string).slice(0, 10)}…`
    : "asset";
  const amt = o.amount ?? o.balance ?? o.value ?? o.amountWei;
  if (typeof amt === "string" || typeof amt === "number") {
    const v = typeof amt === "string" && amt.startsWith("0x") ? hexToBigInt(amt).toString() : String(amt);
    return `${sym} ${v.length > 24 ? v.slice(0, 24) + "…" : v}`;
  }
  let raw: string;
  try {
    raw = JSON.stringify(o);
  } catch {
    raw = "(unrenderable)";
  }
  return raw.length > 40 ? raw.slice(0, 40) + "…" : raw;
}

function shieldedSection(
  r: { ok: true; result: unknown } | { ok: false; error: { message: string } },
): { count: number; lines: string[] } | { err: string } {
  if (!r.ok) return { err: r.error.message };
  // Flat {chainId, balances:[...]} — the daemon forwards the bridge
  // result without the legacy {ok,result} wrap (ShieldedRpc.lean:128-140
  // maps bridge errors to RPC errors instead).
  const body = r.result && typeof r.result === "object" ? (r.result as Record<string, unknown>) : {};
  const balances = Array.isArray(body.balances) ? body.balances : [];
  return {
    count: balances.length,
    lines: balances.slice(0, 2).map(describeShieldedEntry),
  };
}

export function useWalletData(
  activeChain: string | null,
  /** When false, the balance poll is paused — used to stop background
   *  polling while the user isn't looking at the wallet (e.g. they're in
   *  the network monitor). Flipping it back to true triggers an immediate
   *  refresh. Defaults true so other callers are unaffected. */
  enabled: boolean = true,
): WalletData {
  const [rows, setRows] = useState<WalletRow[]>([]);
  const [droppedRows, setDroppedRows] = useState(0);
  const [enumErr, setEnumErr] = useState<string | null>(null);
  const [shielded, setShielded] = useState<ShieldedState>({ kind: "idle" });
  const [vault, setVault] = useState<VaultSummary | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [shieldedBusy, setShieldedBusy] = useState(false);
  // Live mirror of `rows` so the balance poll can iterate the current
  // list without adding `rows` to its dep array (which would restart
  // the interval on every balance landing).
  const rowsRef = useRef<WalletRow[]>([]);
  rowsRef.current = rows;
  // Stable identity of the row SET (chain+address only — NOT balances) so the
  // balance poll re-fires when enumeration adds/changes rows, but is NOT
  // restarted when a `wei` value lands (which would relaunch the interval on
  // every balance). Without this, the first enumeration after mount populates
  // `rows` AFTER the balance poll already ran against an empty snapshot, so
  // balances stayed blank until the next 60s tick or a manual `r`.
  const rowsKey = rows.map((r) => `${r.chain}:${r.address}`).join("|");
  // Per-(chain,address) balance cache so rotating chains shows the last-known
  // value for that chain INSTANTLY (then refreshes), instead of clearing to a
  // spinner every switch. Keyed "chain:address"; survives re-enumeration.
  const balCacheRef = useRef<Map<string, bigint>>(new Map());
  // Liveness guard for the manual one-shot shielded sync, which is NOT
  // driven by usePoll (so it has no isCancelled): a 30-240s sidecar call
  // can resolve after the dashboard unmounts.
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  // Enumeration: re-run on mount, manual refresh, or chain change.
  usePoll(
    async (isCancelled) => {
      if (!activeChain) return;
      const [acct, eoas] = await Promise.all([
        call<{ accounts: AccountEntry[] }>("account.list", {}),
        call<{ name: string; locked?: boolean }[]>("eoa.list", []),
      ]);
      if (isCancelled()) return;
      if (!acct.ok) {
        setEnumErr(acct.error.message);
        return;
      }
      setEnumErr(null);
      const lockByName = new Map<string, boolean>();
      if (eoas.ok && Array.isArray(eoas.result)) {
        for (const e of eoas.result) {
          if (e && typeof e.name === "string") lockByName.set(e.name, e.locked === true);
        }
      }
      const all = (acct.result.accounts ?? []).filter(
        (a): a is AccountEntry & { type: "eoa" | "sphincs" } => {
          if (!a) return false;
          if (a.type === "eoa") return !!a.address;
          // SPHINCS slots can exist before their CREATE2 counterfactual
          // address is computed (account.list emits address=""). Keep
          // them so the user sees the slot + a "finish setup" hint
          // rather than a silently-missing row; the balance poll below
          // skips rows with no address.
          return a.type === "sphincs";
        },
      );
      setDroppedRows(Math.max(0, all.length - ROW_CAP));
      setRows((prev) => {
        // Key by kind+name (not address): uncomputed SPHINCS rows share
        // an empty address and would otherwise collide.
        const prevByKey = new Map(prev.map((p) => [`${p.kind}:${p.name}`, p]));
        return all.slice(0, ROW_CAP).map((a) => {
          // SPHINCS accounts are sepolia-only today; EOAs follow the
          // daemon's active chain.
          const chain = a.type === "eoa" ? activeChain : "sepolia";
          const old = prevByKey.get(`${a.type}:${a.name}`);
          return {
            kind: a.type,
            name: a.name,
            address: a.address,
            chain,
            locked: a.type === "eoa" ? (lockByName.get(a.name) ?? undefined) : undefined,
            // Show the cached balance for THIS chain immediately (instant on
            // chain rotate); fall back to the un-re-enumerated last value, else
            // undefined (spinner) until the poll lands.
            wei:
              (a.address ? balCacheRef.current.get(`${chain}:${a.address}`) : undefined) ??
              (old?.chain === chain ? old.wei : undefined),
            tokens: old?.chain === chain ? old.tokens : undefined,
            defiAave: old?.chain === chain ? old.defiAave : undefined,
          };
        });
      });
    },
    120_000,
    [activeChain, refreshKey],
  );

  // ETH balance only: sequential per row through the active provider.
  usePoll(
    async (isCancelled) => {
      // Paused when the wallet isn't in view (see `enabled`) — no background
      // balance traffic while the user is elsewhere (e.g. network monitor).
      if (!enabled) return;
      const snapshot = rowsRef.current;
      // ETH balance ONLY on this loop: one verified eth_getBalance per row
      // (chain.balance routes through the active provider). Token discovery
      // (swap.balances) has its own far slower 300s tier below — it's a
      // large verified eth_call fan-out (one balanceOf per registry token,
      // serialized through the verifier) and must never ride this loop.
      // Slowed to 60s (was 20s) to keep the verified-read + privacy cost low.
      //
      // Fired CONCURRENTLY, not sequentially: rows can sit on different
      // chains (EOAs follow the active chain, SPHINCS is sepolia-only), and a
      // single helios cold consensus sync on one chain can take tens of
      // seconds. A sequential loop made every later row wait behind that one
      // slow read — e.g. the sepolia SPHINCS balance stuck behind a cold
      // mainnet EOA sync. Each read now lands independently and updates its
      // own row. (Verified reads are still serialized daemon-side; this only
      // removes the TUI-side head-of-line block so fast chains paint first.)
      await Promise.all(
        snapshot.map(async (row) => {
          // Skip rows with no address yet (uncomputed SPHINCS counterfactual).
          if (!row || !row.address) return;
          // Balances read through the active verified provider (helios on
          // mainnet and Sepolia-via-Nimbus, or colibri, per LEANCLI_PROVIDER),
          // so the dashboard shows consensus-verified values consistent with
          // the "provider" setting — no bypass to direct RPC. The generous
          // timeout covers helios's one-time cold consensus sync on the first
          // read after a daemon restart (~10-30s); steady-state verified reads
          // are ~1-2s. (The daemon's chain.balance still accepts a per-call
          // backend:"rpc" override — mirroring tx.simulate — if a fast display
          // path is ever wanted again; the dashboard just no longer forces it.)
          const b = await call<{ balance: string }>("chain.balance", {
            address: row.address,
            chain: row.chain,
          }, { timeoutMs: 180_000 });
          if (isCancelled()) return;
          if (b.ok) {
            const wei = hexToBigInt(b.result?.balance);
            // Cache per (chain,address) so a later switch back to this chain is
            // instant.
            balCacheRef.current.set(`${row.chain}:${row.address}`, wei);
            setRows((prev) =>
              prev.map((p) =>
                p.address === row.address && p.chain === row.chain
                  ? { ...p, wei, balErr: undefined }
                  : p,
              ),
            );
          } else {
            setRows((prev) =>
              prev.map((p) =>
                p.address === row.address && p.chain === row.chain
                  ? { ...p, balErr: b.error.message }
                  : p,
              ),
            );
          }
        }),
      );
    },
    60_000,
    [activeChain, refreshKey, enabled, rowsKey],
  );

  // DeFi positions: one light `defi.positions` per row (a single
  // getUserAccountData eth_call for Aave; Morpho/Curve are "coming soon"
  // markers, no read). Its own slow tier (180s) so it never rides the
  // 60s balance loop, and fail-soft: a per-row error leaves `defiAave`
  // as-is rather than blanking the row. Paused with `enabled` like the
  // balance poll.
  usePoll(
    async (isCancelled) => {
      if (!enabled) return;
      const snapshot = rowsRef.current;
      await Promise.all(
        snapshot.map(async (row) => {
          if (!row || !row.address) return;
          const r = await call<{
            protocols: Array<{
              protocol: string;
              available?: boolean;
              hasPosition?: boolean;
              baseCurrencyDecimals?: number;
              totalCollateralBase?: string;
              totalDebtBase?: string;
              healthFactor?: string;
              reserves?: Array<{
                symbol?: string;
                decimals?: number;
                supplied?: string;
                borrowed?: string;
              }>;
            }>;
          }>("defi.positions", { chainId: row.chain, address: row.address }, { timeoutMs: 180_000 });
          if (isCancelled()) return;
          if (!r.ok) return; // fail-soft: keep last-known
          const aave = (r.result?.protocols ?? []).find((p) => p.protocol === "aave-v3");
          const summary: AaveSummary | null =
            aave && aave.available === true && aave.hasPosition === true
              ? {
                  collateralBase: hexToBigInt(aave.totalCollateralBase),
                  debtBase: hexToBigInt(aave.totalDebtBase),
                  healthFactor: hexToBigInt(aave.healthFactor),
                  baseDecimals: aave.baseCurrencyDecimals ?? 8,
                  reserves: (aave.reserves ?? [])
                    .map((x) => ({
                      symbol: x.symbol ?? "?",
                      decimals: x.decimals ?? 18,
                      supplied: hexToBigInt(x.supplied),
                      borrowed: hexToBigInt(x.borrowed),
                    }))
                    .filter((x) => x.supplied > 0n || x.borrowed > 0n),
                }
              : null;
          setRows((prev) =>
            prev.map((p) =>
              p.address === row.address && p.chain === row.chain
                ? { ...p, defiAave: summary }
                : p,
            ),
          );
        }),
      );
    },
    180_000,
    [activeChain, refreshKey, enabled, rowsKey],
  );

  // ERC-20 balances: one `swap.balances` registry fan-out per row. This is
  // the expensive read (a verified balanceOf eth_call per registry token,
  // serialized daemon-side), so it sits on the SLOWEST tier — 300s + manual
  // `r` — and is paused with `enabled` like the other polls. Fail-soft: an
  // error leaves the row's last-known tokens in place. Native ETH (address
  // null) is dropped — the head line already shows it — as are zero rows.
  usePoll(
    async (isCancelled) => {
      if (!enabled) return;
      const snapshot = rowsRef.current;
      await Promise.all(
        snapshot.map(async (row) => {
          if (!row || !row.address) return;
          const b = await call<{
            balances: Array<{ symbol: string; address: string | null; decimals: number; balance: string }>;
          }>("swap.balances", { chainId: row.chain, address: row.address }, { timeoutMs: 180_000 });
          if (isCancelled()) return;
          if (!b.ok) return; // fail-soft: keep last-known
          const tokens: TokenBalance[] = (b.result?.balances ?? [])
            .filter((t) => t && t.address !== null)
            .map((t) => ({
              symbol: t.symbol ?? "?",
              decimals: t.decimals ?? 18,
              balance: hexToBigInt(t.balance),
            }))
            .filter((t) => t.balance > 0n);
          setRows((prev) =>
            prev.map((p) =>
              p.address === row.address && p.chain === row.chain ? { ...p, tokens } : p,
            ),
          );
        }),
      );
    },
    300_000,
    [activeChain, refreshKey, enabled, rowsKey],
  );

  // StateVault summary: one `vault.status` per tick. Purely local
  // (daemon-side SQLite row counts + one indexed header lookup — no
  // network, no verifier), so 120s is generous; it rides the manual `r`
  // refresh too. Fail-soft: an error (including "method not found" from
  // a pre-vault daemon) leaves `vault` as-is / null and the pane omits
  // the line. Display-only, like everything in this cache.
  usePoll(
    async (isCancelled) => {
      if (!enabled || !activeChain) return;
      const r = await call<{
        enabled: boolean;
        counts?: Record<string, number>;
        head?: { block?: number; tier?: string } | null;
      }>("vault.status", { chain: activeChain });
      if (isCancelled() || !r.ok) return;
      const counts = r.result?.counts ?? {};
      const head =
        r.result?.head && typeof r.result.head.block === "number"
          ? { block: r.result.head.block, tier: r.result.head.tier ?? "rpc" }
          : null;
      setVault({
        enabled: r.result?.enabled === true,
        tokens: counts.token_meta ?? 0,
        accounts: counts.accounts ?? 0,
        slots: counts.storage ?? 0,
        headers: counts.headers ?? 0,
        head,
      });
    },
    120_000,
    [activeChain, refreshKey, enabled],
  );

  // Owned-account re-pin: ask the daemon to re-prove every wallet-owned
  // account at the current verified head (`vault.pinAccounts`). The
  // daemon already auto-pins at startup; this keeps the "as of block N"
  // pins fresh while the dashboard is open. Each tick costs one head
  // capture per chain + one eth_getProof per account — real network
  // reads — so it sits on the SLOWEST tier (15 min) and is paused with
  // `enabled`. Fire-and-forget: results land in the vault and the 120s
  // status poll above surfaces them; errors (including a pre-vault
  // daemon) are ignored.
  usePoll(
    async (isCancelled) => {
      if (!enabled) return;
      const r = await call("vault.pinAccounts", {}, { timeoutMs: 180_000 });
      if (isCancelled() || !r.ok) return;
    },
    900_000,
    [refreshKey, enabled],
  );

  const syncShielded = () => {
    if (shieldedBusy) return;
    setShieldedBusy(true);
    setShielded({ kind: "syncing" });
    void (async () => {
      // First call spawns the privacy sidecar + syncs pool/POI state:
      // 30-60s+ is normal, so the timeout is far above call()'s 60s
      // default. Requires an unlocked wallet (railgun derives from the
      // EOA seed; PP needs its secret) — errors render verbatim.
      const [rg, pp] = await Promise.all([
        call<unknown>("shielded.railgun.balance", {}, { timeoutMs: 240_000 }),
        call<unknown>("shielded.balance", {}, { timeoutMs: 240_000 }),
      ]);
      if (!mountedRef.current) return;
      setShielded({
        kind: "done",
        railgun: shieldedSection(rg as never),
        pp: shieldedSection(pp as never),
      });
      setShieldedBusy(false);
    })();
  };

  const data: WalletData = {
    rows,
    droppedRows,
    enumErr,
    shielded,
    vault,
    refresh: () => {
      // Manual refresh re-runs every read tier (usePoll fires on dep
      // change), INCLUDING the ERC-20 registry fan-out — so 'r' is the
      // "I just moved tokens, show me now" escape hatch between the slow
      // 300s token ticks.
      setRefreshKey((k) => k + 1);
    },
    syncShielded,
  };
  // Publish to the shared cache so sibling screens (SPHINCS hub) reuse these
  // balances instead of re-reading. Runs on every data change.
  useEffect(() => {
    publishWalletData(data);
  });
  return data;
}
