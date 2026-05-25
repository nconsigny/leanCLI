import React, { useState } from "react";
import { Box, Text } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";
import Form from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";

type RgAction = "balance" | "back";

type Props = { onDone: (s: boolean) => void };

/** Railgun sub-menu. Mirrors PrivacyMenu but routes to
 *  `shielded.railgun.*` RPCs. The Railgun secret store is separate
 *  from the Privacy Pools secret store (RgSecretStore in the daemon),
 *  so the passphrase here is the *Railgun* passphrase. First call
 *  lazy-creates the Railgun secret with the supplied passphrase.
 *
 *  Today this menu only exposes balance. Unshield + transfer are
 *  reachable via raw daemon RPC (shielded.railgun.unshield /
 *  shielded.railgun.transfer); the TUI surfaces will come once the
 *  4337 bundler delegation UX is finalised. */
export default function RailgunMenu({ onDone }: Props) {
  const [pick, setPick] = useState<RgAction | null>(null);
  const [params, setParams] = useState<Record<string, string> | null>(null);

  if (!pick) {
    return (
      <Layout title="Railgun" hint="↑/↓ move · → / enter select · ← / esc back">
        <Select
          items={[
            { label: "Show shielded balance", value: "balance" as RgAction },
            { label: "← Back", value: "back" as RgAction },
          ]}
          arrowNav
          onBack={() => onDone(false)}
          onSelect={(it) => {
            const v = it.value;
            if (v === "back") onDone(false);
            else setPick(v);
          }}
        />
      </Layout>
    );
  }

  if (!params) {
    return (
      <Layout
        title="Railgun balance"
        subtitle="Railgun passphrase (separate from your Privacy Pools secret)"
      >
        <Form
          fields={[
            {
              name: "passphrase",
              label: "Railgun passphrase",
              secret: true,
              validate: (v) => (v.length === 0 ? "required" : null),
            },
          ]}
          onCancel={() => setPick(null)}
          onSubmit={(v) => setParams({ passphrase: v.passphrase ?? "" })}
        />
      </Layout>
    );
  }

  // First-call sync (Subsquid + POI artifact fetch) can take minutes;
  // cached runs return in seconds. 20-minute budget mirrors the PP
  // path so the TUI doesn't give up before the daemon.
  const rgTimeoutMs = 20 * 60 * 1000;

  return (
    <RpcRunner
      title="Railgun: balance"
      method="shielded.railgun.balance"
      params={params}
      timeoutMs={rgTimeoutMs}
      renderResult={(r: any) => <RgBalanceResult result={r} />}
      onDone={onDone}
    />
  );
}

function RgBalanceResult({ result }: { result: any }) {
  // shielded.railgun.balance returns
  //   { chainId, balances: [{ asset: {__type, contract}, amount: bigint }, …] }
  // where amount is JSON-serialised as hex by the bridge.
  const inner = result?.result ?? result;
  const balances: any[] = Array.isArray(inner?.balances) ? inner.balances : [];
  if (balances.length === 0) {
    return (
      <Box flexDirection="column">
        <Text color={theme.warn}>No spendable balance.</Text>
        <Text color={theme.dim}>
          Fresh shields aren't spendable until POI proofs are accepted
          (minutes-to-hours on Sepolia). Re-run balance to refresh.
        </Text>
      </Box>
    );
  }
  return (
    <Box flexDirection="column">
      {balances.map((b: any, i: number) => {
        const asset = b?.asset?.contract ?? JSON.stringify(b?.asset ?? "?");
        const amount = (() => {
          try {
            return BigInt(b?.amount ?? "0").toString();
          } catch {
            return String(b?.amount ?? "?");
          }
        })();
        return (
          <Text key={i}>
            {asset} → {amount}
          </Text>
        );
      })}
    </Box>
  );
}
