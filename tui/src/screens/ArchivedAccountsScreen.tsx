import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { EoaListEntry, TpmListEntry } from "../types.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import { theme } from "../theme.js";
import { archiveKey, readArchive, toggleArchive } from "../archiveStore.js";

type EoaAccount = {
  index: number;
  path: string;
  address: string;
  label?: string | null;
};

type Row = {
  kind: "eoa" | "tpm";
  name: string;
  accountIndex: number;
  address: string;
  accountLabel?: string;
  archiveKey: string;
};

type Phase =
  | { kind: "loading" }
  | { kind: "ready"; rows: Row[]; archived: Set<string> };

type Props = { onDone: (success: boolean) => void };

/** Dedicated view of every archived primary or sub-account in the wallet
 *  store. The WalletsHub filters these out by default; users come here
 *  via "More commands → Archived accounts" to review or unarchive. We
 *  re-resolve every archived key against the live daemon listings so
 *  rows that point at deleted slots fall off the list automatically. */
export default function ArchivedAccountsScreen({ onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "loading" });

  const reload = async () => {
    setPhase({ kind: "loading" });
    const archivedSet = readArchive();
    if (archivedSet.size === 0) {
      setPhase({ kind: "ready", rows: [], archived: archivedSet });
      return;
    }
    const eoaRes = await call<EoaListEntry[]>("eoa.list");
    const tpmRes = await call<TpmListEntry[]>("tpm.listSepoliaAddresses");
    const rows: Row[] = [];
    if (eoaRes.ok && Array.isArray(eoaRes.result)) {
      for (const e of eoaRes.result) {
        if (!e?.name || !e?.address) continue;
        const primaryKey = archiveKey("eoa", e.name, 0);
        if (archivedSet.has(primaryKey)) {
          rows.push({
            kind: "eoa",
            name: e.name,
            accountIndex: 0,
            address: e.address,
            archiveKey: primaryKey,
          });
        }
        // Pull sub-accounts even when the primary isn't archived — users
        // commonly archive a single derived branch and keep the primary.
        const sub = await call<{ accounts: EoaAccount[] }>(
          "eoa.account.list",
          { name: e.name },
        );
        if (sub.ok && Array.isArray(sub.result?.accounts)) {
          for (const a of sub.result.accounts) {
            if (!a || a.index === 0) continue;
            const k = archiveKey("eoa", e.name, a.index);
            if (!archivedSet.has(k)) continue;
            rows.push({
              kind: "eoa",
              name: e.name,
              accountIndex: a.index,
              address: a.address,
              accountLabel: a.label ?? undefined,
              archiveKey: k,
            });
          }
        }
      }
    }
    if (tpmRes.ok && Array.isArray(tpmRes.result)) {
      for (const t of tpmRes.result) {
        if (!t?.name || !t?.address) continue;
        const k = archiveKey("tpm", t.name, 0);
        if (archivedSet.has(k)) {
          rows.push({
            kind: "tpm",
            name: t.name,
            accountIndex: 0,
            address: t.address,
            archiveKey: k,
          });
        }
      }
    }
    setPhase({ kind: "ready", rows, archived: archivedSet });
  };

  useEffect(() => {
    reload();
  }, []);

  useInput((input, key) => {
    if (key.escape || input === "q") onDone(false);
  });

  if (phase.kind === "loading") {
    return (
      <Layout title="Archived accounts" hint="esc — back">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>scanning wallet store…</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.rows.length === 0) {
    return (
      <Layout title="Archived accounts" hint="esc — back">
        <Banner
          kind="ok"
          text="no archived accounts — every wallet is visible in the main list."
        />
        <Box marginTop={1}>
          <Text color={theme.dim}>
            Archive an account from Wallets → CUSTOM → wallet → Archive.
          </Text>
        </Box>
      </Layout>
    );
  }

  const items = phase.rows.map((r) => {
    const tag = r.accountIndex > 0 ? "  ↳ " : (r.kind === "eoa" ? "[eoa]" : "[tpm]");
    const display =
      r.accountIndex > 0
        ? r.accountLabel?.length
          ? `${r.name}/${r.accountLabel}`
          : `${r.name}/#${r.accountIndex}`
        : r.name;
    return {
      label: `${tag} ${display.padEnd(18)} ${r.address}`,
      value: r.archiveKey,
    };
  });

  return (
    <Layout
      title="Archived accounts"
      subtitle={`${phase.rows.length} archived — pick one to unarchive`}
      hint="↑/↓ move · → / enter unarchive · ← / esc back"
    >
      <Select
        items={items}
        arrowNav
        onBack={() => onDone(false)}
        onSelect={(it) => {
          toggleArchive(it.value);
          // Reload rather than mutate in place so a second archive op
          // elsewhere stays consistent on the next view.
          reload();
        }}
      />
      <Box marginTop={1}>
        <Text color={theme.dim}>
          Selecting a row removes it from the archive — it'll reappear in
          Wallets on the next refresh.
        </Text>
      </Box>
    </Layout>
  );
}
