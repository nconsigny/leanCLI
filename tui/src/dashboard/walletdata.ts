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
 *  - ERC-20 (`swap.balances`)                   — NOT polled here. It's a
 *    large verified eth_call fan-out (one balanceOf per registry token),
 *    so token discovery runs only on the wallet-hub screen on demand.
 *  - shielded (railgun + privacy pools)         — ON DEMAND only (`s`).
 *    Both spawn the privacy sidecar and can take 30-60s+ on first call
 *    (Subsquid sync / POI fetch) and require an unlocked wallet. They
 *    must never sit on a poll loop.
 *
 * chain.addressFreshness (2x address-less eth_getLogs per address) is
 * deliberately NOT fetched here — too heavy for a dashboard loop.
 */

export type TokenBalance = { symbol: string; decimals: number; balance: bigint };

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
  refresh: () => void;
  syncShielded: () => void;
};

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
  const [refreshKey, setRefreshKey] = useState(0);
  const [shieldedBusy, setShieldedBusy] = useState(false);
  // Live mirror of `rows` so the balance poll can iterate the current
  // list without adding `rows` to its dep array (which would restart
  // the interval on every balance landing).
  const rowsRef = useRef<WalletRow[]>([]);
  rowsRef.current = rows;
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
            // keep last-known balances across re-enumeration to avoid flicker
            wei: old?.chain === chain ? old.wei : undefined,
            tokens: old?.chain === chain ? old.tokens : undefined,
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
      // ETH balance ONLY on the dashboard: one verified eth_getBalance per
      // row (chain.balance routes through the active provider). Token
      // discovery (swap.balances) is intentionally NOT polled here — it's a
      // large verified eth_call fan-out (one balanceOf per registry token,
      // now serialized through the verifier), so it runs only on the
      // wallet-hub screen (ManageWalletScreen) on demand, not continuously.
      // Slowed to 60s (was 20s) to keep the verified-read + privacy cost low.
      for (let i = 0; i < snapshot.length; i++) {
        if (isCancelled()) return;
        const row = snapshot[i];
        if (!row) continue;
        // Skip rows with no address yet (uncomputed SPHINCS counterfactual).
        if (!row.address) continue;
        const b = await call<{ balance: string }>("chain.balance", {
          address: row.address,
          chain: row.chain,
        });
        if (isCancelled()) return;
        setRows((prev) =>
          prev.map((p) =>
            p.address === row.address && p.chain === row.chain
              ? b.ok
                ? { ...p, wei: hexToBigInt(b.result?.balance), balErr: undefined }
                : { ...p, balErr: b.error.message }
              : p,
          ),
        );
      }
    },
    60_000,
    [activeChain, refreshKey, enabled],
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

  return {
    rows,
    droppedRows,
    enumErr,
    shielded,
    refresh: () => {
      // Manual refresh re-runs the native-balance pass (usePoll fires on dep
      // change). Token discovery isn't polled on the dashboard — it's
      // wallet-hub only — so 'r' never triggers a registry-wide eth_call
      // fan-out regardless of how many times it's pressed.
      setRefreshKey((k) => k + 1);
    },
    syncShielded,
  };
}
