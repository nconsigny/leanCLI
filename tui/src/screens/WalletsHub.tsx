import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import {
  AddressFreshness,
  ChainBalance,
  EoaListEntry,
  TpmListEntry,
  Wallet,
} from "../types.js";
import { formatEth, hexToBigInt } from "../format.js";
import { theme } from "../theme.js";
import { Layout } from "../widgets/Layout.js";
import TabStrip from "../widgets/TabStrip.js";
import Select from "../widgets/Select.js";
import { archiveKey, readArchive } from "../archiveStore.js";

export type WalletsAction = "send" | "swap" | "shield" | "custom";

type Props = {
  refreshKey?: number;
  /** `chain` carries the user's WalletsHub-level chain selection — the
   *  `eoaChain` toggle (mainnet/sepolia) for EOAs, "sepolia" for TPM
   *  wallets (their only supported chain today). Downstream flows
   *  (SendFlow / SwapFlow) pass this through to eoa.send so the call
   *  hits the per-chain endpoint matching what the user just saw on
   *  the balance row. */
  onPick: (action: WalletsAction, wallet: Wallet, chain: string) => void;
  onBack: () => void;
};

type BalanceCell =
  | { state: "pending" }
  | { state: "ok"; wei: bigint; chain?: string }
  | { state: "err"; message: string };

/** 0-link freshness state for one wallet row. Stored separately from
 *  balances so balance fetch is unblocked even when the heavier
 *  getLogs-driven freshness probe stalls or fails. The final 0-link
 *  rule is computed in `isZeroLink` below — it folds in the balance
 *  cell on top of these fields so a balance change repaints the row
 *  without re-firing the freshness probe. */
type FreshnessCell =
  | { state: "pending" }
  | {
      state: "ok";
      /** Pending-tag nonce — 0 means the address never sent a tx. */
      nonce: number;
      /** True iff both ERC-20 in/out getLogs scans returned 0. */
      erc20Clean: boolean;
      /** Daemon-local flag: this daemon previously unshielded to this
       *  address, so any positive balance is PP-sourced. */
      ppFunded: boolean;
      /** True when the daemon could not complete the getLogs scan;
       *  erc20Clean is then treated as "unknown" and the address can
       *  never qualify as 0-link. */
      partial?: boolean;
    }
  | { state: "err" };

/** Final 0-link decision combining freshness + balance + ppFunded.
 *  Rule: nonce=0 AND ERC-20-clean AND (balance=0 OR ppFunded). */
function isZeroLink(fresh: FreshnessCell | undefined, bal: BalanceCell | undefined): boolean {
  if (!fresh || fresh.state !== "ok") return false;
  if (fresh.partial) return false;
  if (fresh.nonce !== 0) return false;
  if (!fresh.erc20Clean) return false;
  if (fresh.ppFunded) return true;
  if (bal?.state === "ok" && bal.wei === 0n) return true;
  return false;
}

/** Balance map key — must include accountIndex so sub-accounts each get
 *  their own balance cell. The archive store uses the same shape so a
 *  single key serves both the balance map and archive lookup. */
const balanceKey = (kind: string, name: string, accountIndex?: number): string =>
  `${kind}:${name}:${accountIndex ?? 0}`;

/** A single sub-account row from `eoa.account.list`. */
type EoaAccount = {
  index: number;
  path: string;
  address: string;
  label?: string | null;
};

const TABS: { label: string; value: WalletsAction; help: string }[] = [
  {
    label: "SEND",
    value: "send",
    help: "Move ETH (or signed calldata) from a wallet to a recipient.",
  },
  {
    label: "SWAP",
    value: "swap",
    help: "Uniswap V3 swap — EOA on mainnet/sepolia, R1/TPM on sepolia.",
  },
  {
    label: "SHIELD",
    value: "shield",
    help: "Privacy Pools deposit. EOA only — TPM/R1 keys can't sign the deposit transcript yet.",
  },
  {
    label: "CUSTOM",
    value: "custom",
    help: "Wallet management — history, refresh, lock/unlock, reveal, plus advanced calldata.",
  },
];

/** Action-first hub. The user picks the action via the top tab strip
 *  (←/→), then selects which wallet to execute it with (↑/↓ + enter).
 *  Replaces the older wallet-first flow (WalletList → ActionPicker)
 *  because the most common question is "do this thing — with which
 *  account?" rather than "what can I do with this account?". */
export default function WalletsHub({
  refreshKey = 0,
  onPick,
  onBack,
}: Props) {
  const [wallets, setWallets] = useState<Wallet[]>([]);
  const [balances, setBalances] = useState<Record<string, BalanceCell>>({});
  const [freshness, setFreshness] = useState<Record<string, FreshnessCell>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tabIdx, setTabIdx] = useState(0);
  // Archive state lives on disk (see `archiveStore.ts`) and is reloaded
  // on every refresh-key bump so an Archive op elsewhere in the app
  // becomes visible the next time we mount. WalletsHub is the canonical
  // *active* view — archived rows are filtered out unconditionally; the
  // dedicated review surface lives under More commands → Archived
  // accounts (`ArchivedAccountsScreen`).
  const [archived, setArchived] = useState<Set<string>>(() => readArchive());
  // Why: EOA-side chain override. The initial value is fetched from the
  // daemon's network.show (cfg.chainId) on mount so the hub matches the
  // user's actual daemon config — not a hardcoded "mainnet" that
  // silently misroutes balance reads + sends on a testnet daemon. `n`
  // toggles to the other chain and back. TPM rows stay pinned to
  // sepolia (their only supported network today).
  const [eoaChain, setEoaChain] = useState<"mainnet" | "sepolia">("mainnet");
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{ chainId: number }>("network.show", {});
      if (cancelled || !r.ok) return;
      const cid = r.result?.chainId;
      if (cid === 1) setEoaChain("mainnet");
      else if (cid === 11155111) setEoaChain("sepolia");
      // other chain ids: leave the toggle alone (user can flip with n)
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    setArchived(readArchive());
    (async () => {
      const eoaRes = await call<EoaListEntry[]>("eoa.list");
      const tpmRes = await call<TpmListEntry[]>("tpm.listSepoliaAddresses");
      if (cancelled) return;

      const out: Wallet[] = [];

      if (eoaRes.ok && Array.isArray(eoaRes.result)) {
        for (const e of eoaRes.result) {
          if (!e?.name || !e?.address) continue;
          // Push the slot's primary account first.
          out.push({
            kind: "eoa",
            name: e.name,
            address: e.address,
            unlocked: e.unlocked === true,
            accountIndex: 0,
          });
          // Then ask the daemon for any derived sub-accounts on this
          // slot (`eoa.account.add` lands here). Failures are non-fatal
          // — if the call fails we just don't surface sub-accounts for
          // that slot, matching the daemon's "primary always works"
          // contract.
          const sub = await call<{ accounts: EoaAccount[] }>(
            "eoa.account.list",
            { name: e.name },
          );
          if (cancelled) return;
          if (sub.ok && Array.isArray(sub.result?.accounts)) {
            for (const a of sub.result.accounts) {
              if (!a || typeof a.index !== "number") continue;
              if (a.index === 0) continue; // primary already added
              if (!a.address) continue;
              out.push({
                kind: "eoa",
                name: e.name,
                address: a.address,
                unlocked: e.unlocked === true,
                accountIndex: a.index,
                accountLabel: a.label ?? undefined,
                accountPath: a.path,
              });
            }
          }
        }
      }

      if (tpmRes.ok && Array.isArray(tpmRes.result)) {
        for (const t of tpmRes.result) {
          if (!t?.name || !t?.address) continue;
          out.push({ kind: "tpm", name: t.name, address: t.address });
        }
      }

      if (out.length === 0) {
        const failed = !eoaRes.ok ? eoaRes : !tpmRes.ok ? tpmRes : null;
        setError(
          failed && !failed.ok
            ? failed.error.message
            : "no wallets configured — run `kohaku wallet create eoa <name>` or `wallet create r1 <name>`",
        );
      }

      setWallets(out);
      setBalances(
        Object.fromEntries(
          out.map((w) => [
            balanceKey(w.kind, w.name, w.accountIndex),
            { state: "pending" } as BalanceCell,
          ]),
        ),
      );
      setFreshness(
        Object.fromEntries(
          out.map((w) => [
            balanceKey(w.kind, w.name, w.accountIndex),
            { state: "pending" } as FreshnessCell,
          ]),
        ),
      );
      setLoading(false);

      // Sequential balance + freshness fetches per row. Public RPCs
      // throttle bursts and sometimes return `0x0` instead of an error
      // under load, so we keep the per-row probes serial. Freshness
      // runs immediately after the row's balance so a slow getLogs
      // doesn't delay the next row's balance from rendering.
      for (const w of out) {
        if (cancelled) return;
        const params: { address: string; chain?: string } = { address: w.address };
        params.chain = w.kind === "tpm" ? "sepolia" : eoaChain;
        const r = await call<ChainBalance>("chain.balance", params);
        if (cancelled) return;
        const key = balanceKey(w.kind, w.name, w.accountIndex);
        if (!r.ok) {
          setBalances((prev) => ({
            ...prev,
            [key]: { state: "err", message: r.error.message },
          }));
        } else {
          const wei = hexToBigInt(r.result?.balance);
          setBalances((prev) => ({
            ...prev,
            [key]: { state: "ok", wei, chain: r.result?.chain },
          }));
        }
        // Freshness probe. Soft signal — failure never falsely marks
        // a row as "fresh"; we tag it as err and keep the row neutral.
        const fr = await call<AddressFreshness>("chain.addressFreshness", params);
        if (cancelled) return;
        if (!fr.ok) {
          setFreshness((prev) => ({ ...prev, [key]: { state: "err" } }));
          continue;
        }
        const d = fr.result;
        if (!d || typeof d.nonce !== "number") {
          setFreshness((prev) => ({ ...prev, [key]: { state: "err" } }));
          continue;
        }
        const ppFunded = d.ppFunded === true;
        if (d.available !== true) {
          setFreshness((prev) => ({
            ...prev,
            [key]: {
              state: "ok",
              nonce: d.nonce,
              erc20Clean: false,
              ppFunded,
              partial: true,
            },
          }));
          continue;
        }
        const erc20Clean =
          (d.erc20OutCount ?? 0) === 0 && (d.erc20InCount ?? 0) === 0;
        setFreshness((prev) => ({
          ...prev,
          [key]: { state: "ok", nonce: d.nonce, erc20Clean, ppFunded },
        }));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshKey, eoaChain]);

  // Esc / q falls back to the main menu. ←/→ are owned by the TabStrip,
  // ↑/↓/Enter by the Select below — letting Ink dispatch each key to the
  // right consumer keeps the navigation predictable. `n` flips the EOA
  // chain between mainnet and sepolia; the useEffect dep above triggers
  // a re-fetch of every row's balance on the new chain.
  useInput((input, key) => {
    if (key.escape || input === "q") onBack();
    else if (input === "n") {
      setEoaChain((c) => (c === "mainnet" ? "sepolia" : "mainnet"));
    }
  });

  const tab = TABS[tabIdx]!;
  const tabFiltered = filterWalletsForTab(tab.value, wallets);
  // Archived rows are filtered out here unconditionally. The dedicated
  // archive review screen (More commands → Archived accounts) is the one
  // place to inspect or unarchive them.
  const filtered = tabFiltered.filter(
    (w) => !archived.has(archiveKey(w.kind, w.name, w.accountIndex)),
  );

  // Compress the row to: `[kind] name address balance`. Chain moved to
  // the screen-level header; [locked] tag dropped. Sub-accounts indent
  // with a `↳` glyph and use the slot label "/sub" suffix so users see
  // the hierarchy at a glance. Archived rows (only shown when toggled)
  // get a leading \x01 byte so `Select`'s itemRenderer dims them.
  // 0-link rows (nonce=0 AND no ERC-20 history in the lookback window)
  // get a leading \x02 byte so the itemRenderer paints them green —
  // a privacy hint for the SEND/SWAP/SHIELD picker so unshield/rotate
  // destinations stand out.
  const items = filtered.map((w) => {
    const key = balanceKey(w.kind, w.name, w.accountIndex);
    const cell = balances[key];
    const fresh = freshness[key];
    const balPart =
      cell?.state === "ok"
        ? formatEth(cell.wei)
        : cell?.state === "err"
          ? "err"
          : "…";
    const isSub = (w.accountIndex ?? 0) > 0;
    const tag = isSub ? "  ↳ " : (w.kind === "eoa" ? "[eoa]" : "[tpm]");
    const displayName = isSub
      ? (w.accountLabel?.length
          ? `${w.name}/${w.accountLabel}`
          : `${w.name}/#${w.accountIndex}`)
      : w.name;
    const w2: Wallet =
      cell?.state === "ok"
        ? { ...w, balanceWei: cell.wei, balanceChain: cell.chain }
        : w;
    const zero = isZeroLink(fresh, cell);
    const linkTag = zero
      ? fresh?.state === "ok" && fresh.ppFunded && cell?.state === "ok" && cell.wei !== 0n
        ? "  0-link (PP-funded)"
        : "  0-link"
      : "";
    const prefix = zero ? "\x02" : "";
    return {
      label: `${prefix}${tag} ${displayName.padEnd(16)} ${w.address}  ${balPart}${linkTag}`,
      value: key,
      __wallet: w2,
    };
  });

  // Roll the per-row chain labels up into a single header line. We track
  // the EOA chain (whatever the daemon's primary is) and the TPM chain
  // (always sepolia today) separately and only show both badges when
  // they diverge — a single "chain: X" line suffices when they match.
  // EOA falls back to the current `eoaChain` toggle so the header updates
  // the moment `n` is pressed, not only once balances repopulate.
  const eoaChainName = pickChainFor(wallets, balances, "eoa") ?? eoaChain;
  const tpmChainName = pickChainFor(wallets, balances, "tpm");

  return (
    <Layout
      title="Wallets"
      subtitle={`${tab.label} — ${tab.help}`}
      hint="←/→ action · ↑/↓ wallet · enter run · n chain · esc back"
    >
      <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
        {" leanKohaku · wallets "}
      </Text>
      <Box marginTop={1}>
        <TabStrip tabs={TABS} activeIndex={tabIdx} onChange={setTabIdx} />
      </Box>
      {loading && (
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>loading wallets…</Text>
        </Text>
      )}
      {error && <Text color={theme.err}>error: {error}</Text>}
      {!loading && !error && filtered.length === 0 && (
        <Banner
          message={`no wallet supports ${tab.label} yet — try a different action or create one with the main menu`}
        />
      )}
      {!loading && filtered.length > 0 && (
        <Box flexDirection="column">
          <Box marginBottom={1}>
            <Text color={theme.dim}>pick the wallet to execute </Text>
            <Text color={theme.highlight} bold>
              {tab.label}
            </Text>
            <Text color={theme.dim}> with — </Text>
            <ChainBadge eoa={eoaChainName} tpm={tpmChainName} />
          </Box>
          <Select
            items={items}
            onSelect={(it) => {
              const cast = it as typeof items[number];
              // TPM wallets are sepolia-only today; EOAs follow the
              // hub's chain toggle (defaults to mainnet, `n` to flip).
              const chain = cast.__wallet.kind === "tpm" ? "sepolia" : eoaChain;
              onPick(tab.value, cast.__wallet, chain);
            }}
          />
        </Box>
      )}
    </Layout>
  );
}

function Banner({ message }: { message: string }) {
  return (
    <Box paddingX={1}>
      <Text color={theme.warn}>⚠ {message}</Text>
    </Box>
  );
}

function pickChainFor(
  wallets: Wallet[],
  balances: Record<string, BalanceCell>,
  kind: "eoa" | "tpm",
): string | undefined {
  for (const w of wallets) {
    if (w.kind !== kind) continue;
    const c = balances[balanceKey(w.kind, w.name)];
    if (c?.state === "ok" && c.chain) return c.chain;
  }
  return undefined;
}

function ChainBadge({ eoa, tpm }: { eoa?: string; tpm?: string }) {
  // No chains resolved yet → silent. Single chain (or only one kind
  // present) → "chain: X". Mismatch → both badges so the user always
  // knows which kind dispatches to which network.
  if (!eoa && !tpm) return null;
  const same = eoa && tpm && eoa === tpm;
  if (same || (eoa && !tpm) || (!eoa && tpm)) {
    const label = (eoa ?? tpm)!;
    return (
      <>
        <Text color={theme.dim}>chain </Text>
        <Text color={theme.highlight} bold>
          {label}
        </Text>
      </>
    );
  }
  return (
    <>
      <Text color={theme.dim}>EOA </Text>
      <Text color={theme.highlight} bold>
        {eoa}
      </Text>
      <Text color={theme.dim}>  ·  TPM </Text>
      <Text color={theme.highlight} bold>
        {tpm}
      </Text>
    </>
  );
}

function filterWalletsForTab(action: WalletsAction, wallets: Wallet[]): Wallet[] {
  switch (action) {
    case "send":
    case "swap":
    case "custom":
      // SwapFlow handles per-wallet eligibility itself (R1 → sepolia
      // only, EOA → mainnet/sepolia), so we don't pre-filter here.
      return wallets;
    case "shield":
      return wallets.filter((w) => w.kind === "eoa");
  }
}
