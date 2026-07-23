import React, { useEffect, useState } from "react";
import { Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import { theme } from "../theme.js";
import { Wallet, EoaListEntry } from "../types.js";
import { formatEthCompact } from "../format.js";
import { useSharedWalletData } from "../dashboard/walletdata.js";
import ShieldFlow from "./ShieldFlow.js";
import WalletUnshieldFlow from "./WalletUnshieldFlow.js";

type Props = {
  action: "shield" | "unshield";
  onDone: (success: boolean) => void;
};

type Phase =
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "pick"; wallets: Wallet[] }
  | { kind: "flow"; wallet: Wallet };

/** One-keystroke shield/unshield entry (dashboard `S` / `U`, main-menu
 *  quick entries). Collapses the WalletsHub detour to its essence: pick
 *  the EOA (auto-picked when there is exactly one), then jump straight
 *  into the existing ShieldFlow / WalletUnshieldFlow — same flows, same
 *  gates, fewer screens. Display-only until the wrapped flow's own
 *  pre-sign pipeline takes over; this wrapper never builds calldata. */
export default function QuickPrivacyFlow({ action, onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "loading" });
  // Live dashboard balances (when the dashboard poller is mounted) so the
  // picker can annotate rows without firing its own verified reads.
  const shared = useSharedWalletData();

  useEffect(() => {
    let cancelled = false;
    (async () => {
      // Shield/unshield are EOA-only everywhere (both protocols sign or
      // authorize via the EOA slot), so enumerate EOA slots directly.
      // NOTE the daemon emits `locked` (Helpers.lean slotMetadataJson),
      // not the `unlocked` the legacy TUI type guessed at — read both.
      const r = await call<Array<EoaListEntry & { locked?: boolean }>>(
        "eoa.list",
      );
      if (cancelled) return;
      if (!r.ok) {
        setPhase({ kind: "error", message: r.error.message });
        return;
      }
      const wallets: Wallet[] = (Array.isArray(r.result) ? r.result : [])
        .filter((e) => !!(e?.name && e?.address))
        .map((e) => ({
          kind: "eoa" as const,
          name: e.name,
          address: e.address,
          unlocked:
            e.locked !== undefined ? e.locked === false : e.unlocked === true,
          accountIndex: 0,
        }));
      if (wallets.length === 0) {
        setPhase({
          kind: "error",
          message:
            "no EOA wallets configured — create one first (Wallets → CREATE)",
        });
        return;
      }
      // The common case: exactly one EOA → no picker at all.
      if (wallets.length === 1) {
        setPhase({ kind: "flow", wallet: wallets[0]! });
        return;
      }
      setPhase({ kind: "pick", wallets });
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const title = action === "shield" ? "Shield" : "Unshield";

  if (phase.kind === "loading") {
    return (
      <Layout title={title} subtitle="loading wallets…">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>enumerating EOA wallets…</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "error") {
    return (
      <Layout title={title} hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  if (phase.kind === "pick") {
    return (
      <Layout
        title={`${title} — pick the wallet`}
        subtitle={
          action === "shield"
            ? "which EOA funds the deposit?"
            : "which EOA owns the shielded notes?"
        }
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={phase.wallets.map((w) => {
            const row = shared?.rows.find(
              (r) => r.address.toLowerCase() === w.address.toLowerCase(),
            );
            const bal =
              row?.wei !== undefined ? `  ${formatEthCompact(row.wei, 4)}` : "";
            return {
              label: `${w.name.padEnd(16)} ${w.address}${bal}`,
              value: w.name,
            };
          })}
          arrowNav
          onBack={() => onDone(false)}
          onSelect={(it) => {
            const w = phase.wallets.find((x) => x.name === it.value);
            if (w) setPhase({ kind: "flow", wallet: w });
          }}
        />
      </Layout>
    );
  }

  // phase.kind === "flow" — hand off to the existing gated flows.
  return action === "shield" ? (
    <ShieldFlow wallet={phase.wallet} onDone={onDone} />
  ) : (
    <WalletUnshieldFlow wallet={phase.wallet} onDone={onDone} />
  );
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
