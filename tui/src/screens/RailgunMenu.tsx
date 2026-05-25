import React, { useState } from "react";
import { Box, Text } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";

type RgAction = "balance" | "back";

type Props = { onDone: (s: boolean) => void };

/** Railgun sub-menu. Routes to `shielded.railgun.*` RPCs.
 *
 *  No Railgun-specific passphrase here: the Railgun keystore is rooted
 *  at the default EOA's BIP-39 seed (Railgun derives at its own BIP-32
 *  paths, disjoint from BIP-44 Ethereum). The same unlock surface that
 *  unlocks the EOA (master KEK / TPM / per-slot passphrase) gates this
 *  flow — if the default wallet is currently unlocked, balance just
 *  works. If it's locked, the daemon returns -32012 (EOA slot locked)
 *  and the user lands on a generic error page; the fix is `kohaku
 *  wallet unlock <name>` (or unlock the master).
 *
 *  Today this menu only exposes balance. Unshield + transfer are
 *  reachable via raw daemon RPC; their TUI surfaces will come once
 *  the 4337 bundler delegation UX is finalised. */
export default function RailgunMenu({ onDone }: Props) {
  const [pick, setPick] = useState<RgAction | null>(null);

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

  // First-call sync (Subsquid + POI artifact fetch) can take minutes;
  // cached runs return in seconds. 20-minute budget mirrors the PP
  // path so the TUI doesn't give up before the daemon.
  const rgTimeoutMs = 20 * 60 * 1000;

  return (
    <RpcRunner
      title="Railgun: balance"
      subtitle="default wallet must be unlocked"
      method="shielded.railgun.balance"
      params={{}}
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
