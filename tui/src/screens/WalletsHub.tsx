import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import {
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
  onPick: (action: WalletsAction, wallet: Wallet) => void;
  onBack: () => void;
};

type BalanceCell =
  | { state: "pending" }
  | { state: "ok"; wei: bigint; chain?: string }
  | { state: "err"; message: string };

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
      setLoading(false);

      // Sequential balance fetches — public RPCs throttle bursts and
      // sometimes return `0x0` instead of an error under load.
      for (const w of out) {
        if (cancelled) return;
        const params: { address: string; chain?: string } = { address: w.address };
        if (w.kind === "tpm") params.chain = "sepolia";
        const r = await call<ChainBalance>("chain.balance", params);
        if (cancelled) return;
        const key = balanceKey(w.kind, w.name, w.accountIndex);
        if (!r.ok) {
          setBalances((prev) => ({
            ...prev,
            [key]: { state: "err", message: r.error.message },
          }));
          continue;
        }
        const wei = hexToBigInt(r.result?.balance);
        setBalances((prev) => ({
          ...prev,
          [key]: { state: "ok", wei, chain: r.result?.chain },
        }));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshKey]);

  // Esc / q falls back to the main menu. ←/→ are owned by the TabStrip,
  // ↑/↓/Enter by the Select below — letting Ink dispatch each key to the
  // right consumer keeps the navigation predictable.
  useInput((input, key) => {
    if (key.escape || input === "q") onBack();
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
  const items = filtered.map((w) => {
    const key = balanceKey(w.kind, w.name, w.accountIndex);
    const cell = balances[key];
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
    return {
      label: `${tag} ${displayName.padEnd(16)} ${w.address}  ${balPart}`,
      value: key,
      __wallet: w2,
    };
  });

  // Roll the per-row chain labels up into a single header line. We track
  // the EOA chain (whatever the daemon's primary is) and the TPM chain
  // (always sepolia today) separately and only show both badges when
  // they diverge — a single "chain: X" line suffices when they match.
  const eoaChainName = pickChainFor(wallets, balances, "eoa");
  const tpmChainName = pickChainFor(wallets, balances, "tpm");

  return (
    <Layout
      title="Wallets"
      subtitle={`${tab.label} — ${tab.help}`}
      hint="←/→ action · ↑/↓ wallet · enter run · esc back"
    >
      <Box
        flexDirection="column"
        borderStyle="double"
        borderColor={theme.koiRed}
        paddingX={2}
        paddingY={0}
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
                onPick(tab.value, cast.__wallet);
              }}
            />
          </Box>
        )}
      </Box>
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
