import React, { useState } from "react";
import { Text } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";
import Form from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";
import { hexToBigInt, formatEth } from "../format.js";
import UnshieldFlow from "./UnshieldFlow.js";

type PpAction =
  | "balance"
  | "reveal"
  | "import"
  | "delete"
  | "unshield"
  | "back";

type Props = { onDone: (s: boolean) => void };

/** Privacy Pools sub-menu. Every leaf is a passphrase + RpcRunner. */
export default function PrivacyMenu({ onDone }: Props) {
  const [pick, setPick] = useState<PpAction | null>(null);
  const [params, setParams] = useState<Record<string, string> | null>(null);

  if (!pick) {
    return (
      <Layout title="Privacy Pools" hint="↑/↓ move · → / enter select · ← / esc back">
        <Select
          items={[
            { label: "Show shielded balance",                 value: "balance" as PpAction },
            { label: "Reveal stored mnemonic (one-shot)",      value: "reveal" as PpAction },
            { label: "Import a 12/24-word mnemonic",           value: "import" as PpAction },
            { label: "Delete the stored PP secret (warning)", value: "delete" as PpAction },
            { label: "Unshield to a recipient",                value: "unshield" as PpAction },
            { label: "← Back",                                 value: "back" as PpAction },
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

  // Unshield is a self-contained multi-phase flow (recipient picker
  // → amount/passphrase → dispatch). It owns its own daemon RPC so we
  // delegate before the params/RpcRunner wrapping that the other
  // leaves still share.
  if (pick === "unshield") {
    return (
      <UnshieldFlow
        onDone={(s) => {
          setPick(null);
          onDone(s);
        }}
      />
    );
  }

  if (!params) {
    if (pick === "import") {
      return (
        <Layout title="Import Privacy Pool mnemonic">
          <Form
            fields={[
              { name: "mnemonic", label: "BIP-39 mnemonic (quote-free)", validate: (v) => v.split(/\s+/).length >= 12 ? null : "expected ≥12 words" },
              { name: "passphrase", label: "Privacy Pool passphrase", secret: true, validate: (v) => v.length === 0 ? "required" : null },
            ]}
            onCancel={() => setPick(null)}
            onSubmit={(v) => setParams({ mnemonic: v.mnemonic ?? "", passphrase: v.passphrase ?? "" })}
          />
        </Layout>
      );
    }
    return (
      <Layout title={pick === "balance" ? "Show shielded balance" : pick === "reveal" ? "Reveal mnemonic" : "Delete stored PP secret"}>
        <Form
          fields={[
            { name: "passphrase", label: "Privacy Pool passphrase", secret: true, validate: (v) => v.length === 0 ? "required" : null },
          ]}
          onCancel={() => setPick(null)}
          onSubmit={(v) => setParams({ passphrase: v.passphrase ?? "" })}
        />
      </Layout>
    );
  }

  const method =
    pick === "balance" ? "shielded.balance" :
    pick === "reveal"  ? "shielded.reveal"  :
    pick === "import"  ? "shielded.import"  :
                         "shielded.delete";

  // PP-state sync (balance) and import both trigger the same chain
  // walk the deposit flow does — first-run can take 10+ minutes
  // because the bridge scans every relevant on-chain event since the
  // pool's birth. Cached runs return in seconds. 20-minute window
  // covers both. reveal and delete are local-only and finish fast;
  // they pay no penalty for the larger budget.
  const ppTimeoutMs = 20 * 60 * 1000;

  return (
    <RpcRunner
      title={`Privacy Pools: ${pick}`}
      method={method}
      params={params}
      timeoutMs={ppTimeoutMs}
      renderResult={(r: any) =>
        pick === "balance" ? (
          <BalanceResult result={r} />
        ) : pick === "reveal" ? (
          <Text color={theme.warn}>{r?.mnemonic ?? JSON.stringify(r)}</Text>
        ) : (
          <Text>{JSON.stringify(r, null, 2)}</Text>
        )
      }
      onDone={onDone}
    />
  );
}

function BalanceResult({ result }: { result: any }) {
  // Daemon shape: { balances: [{ amount: "0x…", tag: "pending" | other }, …] }.
  // The Lean CLI sums by tag (Runtime.lean:1675-1687); mirror that here.
  const inner = result?.result ?? result;
  const entries: any[] = Array.isArray(inner?.balances) ? inner.balances : [];
  let confirmed = 0n;
  let pending = 0n;
  for (const e of entries) {
    const wei = hexToBigInt(e?.amount);
    if (e?.tag === "pending") pending += wei;
    else confirmed += wei;
  }
  return (
    <>
      <Text>confirmed: {formatEth(confirmed)}</Text>
      <Text>pending:   {formatEth(pending)}</Text>
      <Text color={theme.dim}>total:     {formatEth(confirmed + pending)}</Text>
    </>
  );
}
