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
import { archiveKey, readArchive, toggleArchive } from "../archiveStore.js";

export type WalletsAction = "send" | "swap" | "shield" | "unshield" | "manage";

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
    label: "MANAGE",
    value: "manage",
    help: "Per-account admin — EOA: BIP-44 path + cousin sub-accounts. Smart accounts: key rotation / social recovery. Also lists ERC-20 balances from the swap registry.",
  },
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
    help: "Privacy Pools or Railgun deposit. EOA only — TPM/R1 keys can't sign the deposit transcript yet.",
  },
  {
    label: "UNSHIELD",
    value: "unshield",
    help: "Withdraw shielded ETH back to a 0x address (freshly derived sub-account, address-book entry, or paste). EOA only — Railgun's 4337 path is signed by the EOA.",
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
  // Local refresh counter — `r` bumps this to force the discovery
  // useEffect to re-run without needing the parent to bump `refreshKey`.
  // Useful when a row landed `err: chain RPC failed` and the user wants
  // to retry without backing out of the screen.
  const [localRefresh, setLocalRefresh] = useState(0);
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
      // Phase 1: enumerate every wallet kind in parallel. Three independent
      // daemon round-trips collapse to one wall-clock RTT, so primaries
      // render almost immediately instead of after a chain of awaits.
      const [eoaRes, tpmRes, acctRes] = await Promise.all([
        call<EoaListEntry[]>("eoa.list"),
        call<TpmListEntry[]>("tpm.listSepoliaAddresses"),
        // SPHINCS+ hybrid smart accounts via the unified `account.list` RPC.
        // The daemon emits one entry per slot with `type: "sphincs"`. The
        // smart-account address may be empty when the counterfactual hasn't
        // been computed yet — we surface it as the row's address but the
        // detail screen will let the user run "Compute" to populate it.
        call<{ accounts: { type: string; name: string; address: string }[] }>(
          "account.list",
          {},
        ),
      ]);
      if (cancelled) return;

      // Per-row probe — used for primaries (right after Phase 1) and for
      // cousins as each `eoa.account.list` lands in Phase 2. Balance and
      // freshness fire independently; a single slow row no longer holds
      // the rest of the list back.
      const fanout = (w: Wallet) => {
        const params: { address: string; chain?: string } = { address: w.address };
        params.chain = w.kind === "tpm" ? "sepolia" : eoaChain;
        const key = balanceKey(w.kind, w.name, w.accountIndex);
        void call<ChainBalance>("chain.balance", params).then((r) => {
          if (cancelled) return;
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
        });
        // Freshness probe — soft signal: a failure tags `err` and the
        // row stays neutral; never falsely marks "fresh".
        void call<AddressFreshness>("chain.addressFreshness", params).then((fr) => {
          if (cancelled) return;
          if (!fr.ok) {
            setFreshness((prev) => ({ ...prev, [key]: { state: "err" } }));
            return;
          }
          const d = fr.result;
          if (!d || typeof d.nonce !== "number") {
            setFreshness((prev) => ({ ...prev, [key]: { state: "err" } }));
            return;
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
            return;
          }
          const erc20Clean =
            (d.erc20OutCount ?? 0) === 0 && (d.erc20InCount ?? 0) === 0;
          setFreshness((prev) => ({
            ...prev,
            [key]: { state: "ok", nonce: d.nonce, erc20Clean, ppFunded },
          }));
        });
      };

      // Build the primaries-only list: one row per EOA slot, every TPM
      // address, every SPHINCS slot. Cousins get spliced in beneath their
      // primary in Phase 2 as each `eoa.account.list` resolves.
      const eoaSlots =
        eoaRes.ok && Array.isArray(eoaRes.result)
          ? eoaRes.result.filter((e) => !!(e?.name && e?.address))
          : [];

      const primaries: Wallet[] = [];
      for (const e of eoaSlots) {
        primaries.push({
          kind: "eoa",
          name: e.name,
          address: e.address,
          unlocked: e.unlocked === true,
          accountIndex: 0,
        });
      }
      if (tpmRes.ok && Array.isArray(tpmRes.result)) {
        for (const t of tpmRes.result) {
          if (!t?.name || !t?.address) continue;
          primaries.push({ kind: "tpm", name: t.name, address: t.address });
        }
      }
      if (acctRes.ok && Array.isArray(acctRes.result?.accounts)) {
        for (const a of acctRes.result.accounts) {
          if (a?.type !== "sphincs" || !a.name) continue;
          primaries.push({
            kind: "sphincs",
            name: a.name,
            address: a.address ?? "",
          });
        }
      }

      if (primaries.length === 0) {
        const failed = !eoaRes.ok
          ? eoaRes
          : !tpmRes.ok
            ? tpmRes
            : !acctRes.ok
              ? acctRes
              : null;
        setError(
          failed && !failed.ok
            ? failed.error.message
            : "no wallets configured — run `leancli wallet create eoa <name>` or `wallet create r1 <name>`",
        );
      }

      setWallets(primaries);
      setBalances(
        Object.fromEntries(
          primaries.map((w) => [
            balanceKey(w.kind, w.name, w.accountIndex),
            { state: "pending" } as BalanceCell,
          ]),
        ),
      );
      setFreshness(
        Object.fromEntries(
          primaries.map((w) => [
            balanceKey(w.kind, w.name, w.accountIndex),
            { state: "pending" } as FreshnessCell,
          ]),
        ),
      );
      setLoading(false);
      for (const w of primaries) fanout(w);

      // Phase 2: per-slot sub-account discovery, all in flight at once.
      // Failures are non-fatal — if a slot's `eoa.account.list` fails we
      // just don't surface its cousins, matching the daemon's "primary
      // always works" contract. Each slot's cousins splice in directly
      // under their primary as the call resolves, so the BIP-44 hierarchy
      // stays visually grouped.
      for (const e of eoaSlots) {
        void (async () => {
          const sub = await call<{ accounts: EoaAccount[] }>(
            "eoa.account.list",
            { name: e.name },
          );
          if (cancelled) return;
          if (!sub.ok || !Array.isArray(sub.result?.accounts)) return;
          const cousins: Wallet[] = [];
          for (const a of sub.result.accounts) {
            if (!a || typeof a.index !== "number") continue;
            if (a.index === 0) continue; // primary already shown
            if (!a.address) continue;
            cousins.push({
              kind: "eoa",
              name: e.name,
              address: a.address,
              unlocked: e.unlocked === true,
              accountIndex: a.index,
              accountLabel: a.label ?? undefined,
              accountPath: a.path,
            });
          }
          if (cousins.length === 0) return;
          setWallets((prev) => {
            const result = [...prev];
            let primaryIdx = -1;
            for (let i = 0; i < result.length; i++) {
              const w = result[i]!;
              if (
                w.kind === "eoa" &&
                (w.accountIndex ?? 0) === 0 &&
                w.name === e.name
              ) {
                primaryIdx = i;
                break;
              }
            }
            if (primaryIdx === -1) return result;
            // Skip past any cousins already inserted for this slot, so
            // re-renders (or duplicate appends) stay idempotent.
            let insertAt = primaryIdx + 1;
            while (
              insertAt < result.length &&
              result[insertAt]!.kind === "eoa" &&
              result[insertAt]!.name === e.name &&
              (result[insertAt]!.accountIndex ?? 0) > 0
            ) {
              insertAt++;
            }
            result.splice(insertAt, 0, ...cousins);
            return result;
          });
          setBalances((prev) => {
            const next = { ...prev };
            for (const w of cousins) {
              next[balanceKey(w.kind, w.name, w.accountIndex)] = {
                state: "pending",
              };
            }
            return next;
          });
          setFreshness((prev) => {
            const next = { ...prev };
            for (const w of cousins) {
              next[balanceKey(w.kind, w.name, w.accountIndex)] = {
                state: "pending",
              };
            }
            return next;
          });
          for (const w of cousins) fanout(w);
        })();
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshKey, eoaChain, localRefresh]);

  // Track the currently-highlighted row so `a` can act on it without
  // requiring the user to Enter into the action menu first. `null` =
  // either no rows or Select hasn't fired its initial onHighlight yet.
  const [highlightedKey, setHighlightedKey] = useState<string | null>(null);

  // Esc / q falls back to the main menu. ←/→ are owned by the TabStrip,
  // ↑/↓/Enter by the Select below — letting Ink dispatch each key to the
  // right consumer keeps the navigation predictable. `n` flips the EOA
  // chain between mainnet and sepolia; `r` re-runs discovery + balance
  // fanout (useful when a row landed in `err: chain RPC failed`). `a`
  // archives the currently-highlighted wallet (or unarchives if it's
  // somehow visible while archived — toggle semantics). Both `r` and
  // `a` bump a dep on the useEffect above so the wallet list re-fetches.
  useInput((input, key) => {
    if (key.escape || input === "q") onBack();
    else if (input === "n") {
      setEoaChain((c) => (c === "mainnet" ? "sepolia" : "mainnet"));
    } else if (input === "r") {
      setLocalRefresh((k) => k + 1);
    } else if (input === "a" && highlightedKey) {
      // archiveKey/balanceKey share the same `kind|name|idx` shape;
      // `highlightedKey` from the Select callback is the balanceKey we
      // composed for that row. Pass it straight to toggleArchive.
      const next = toggleArchive(highlightedKey);
      setArchived(next);
      setLocalRefresh((k) => k + 1);
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
    // Show the actual daemon error message instead of a bare "err".
    // The row is width-constrained so we cap the message at ~60 chars
    // and prefix with "err: " so it's still easy to scan as a failure.
    // Common surfaces here: "no rpc_url configured ...", "network policy
    // denied method=eth_getBalance ...", transport / connect ENOENT —
    // all of which are actionable; "err" was not.
    const balPart =
      cell?.state === "ok"
        ? formatEth(cell.wei)
        : cell?.state === "err"
          ? `err: ${cell.message.length > 60 ? cell.message.slice(0, 57) + "…" : cell.message}`
          : "…";
    const isSub = (w.accountIndex ?? 0) > 0;
    const tag = isSub ? "  ↳ "
      : w.kind === "eoa" ? "[eoa]"
      : w.kind === "sphincs" ? "[sphincs]"
      : "[tpm]";
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
      hint="←/→ action · ↑/↓ wallet · enter run · n chain · r refresh · a archive · esc back"
    >
      <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
        {" leanCLI · wallets "}
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
            onHighlight={(it) => {
              const cast = it as typeof items[number];
              setHighlightedKey(cast.value);
            }}
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
    case "manage":
      // SwapFlow handles per-wallet eligibility itself (R1 → sepolia
      // only, EOA → mainnet/sepolia), so we don't pre-filter here.
      return wallets;
    case "shield":
    case "unshield":
      // Both protocols (PP + Railgun) sign the broadcast via an EOA —
      // PP through the relayer flow, Railgun via the 4337+7702 delegator.
      // TPM/R1 wallets can't sign these today.
      return wallets.filter((w) => w.kind === "eoa");
  }
}
