import React, { useEffect, useState } from "react";
import { Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Wallet } from "../types.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import Select from "../widgets/Select.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import UnlockEoaStep from "./UnlockEoaStep.js";
import SendRawFlow, { SendRawWallet } from "./SendRawFlow.js";

type Props = {
  wallet: Wallet;
  onDone: (success: boolean) => void;
};

type Protocol = "pp" | "railgun";

/** Privacy Pools v1 and Railgun are both Sepolia-only at the contract
 *  layer (see ShieldedRpc.lean's Sepolia pinning). The gated legs are
 *  decoded/simulated/signed against this chain. */
const SHIELD_CHAIN_ID = 11155111;

/** One unsigned shield leg returned by `shielded.prepareDeposit` /
 *  `shielded.railgun.prepareShield`. The bridge emits every numeric field
 *  as 0x-hex (jsonReplacer), so `value` is already a hex-quantity string. */
type PreparedTx = { to: string; value: string; data: string };

/** Defensive: ensure a leg `value` is a 0x-hex quantity before it reaches
 *  SendRawFlow (which feeds it to `hexToBigInt`, a hex-only parser — a bare
 *  decimal would be silently misread). The bridge already emits 0x-hex;
 *  this only rescues a decimal/number slipping through a future change. */
function toHexValue(v: unknown): string {
  if (typeof v === "string") {
    if (v.startsWith("0x") || v.startsWith("0X")) return v;
    try {
      return "0x" + BigInt(v).toString(16);
    } catch {
      return "0x0";
    }
  }
  if (typeof v === "number" || typeof v === "bigint") {
    return "0x" + BigInt(v).toString(16);
  }
  return "0x0";
}

type Phase =
  | { kind: "pickProtocol" }
  | { kind: "form"; protocol: Protocol }
  | { kind: "unlock"; protocol: Protocol; v: Record<string, string> }
  // Building the unsigned shield txns via the daemon's prepare RPC. No
  // signature is produced here — the bridge syncs pool state and returns
  // {to,value,data} legs. Can take 30-60s (10+ min on a cold first sync).
  | { kind: "preparing"; protocol: Protocol; v: Record<string, string> }
  // Routing each prepared leg through the canonical pre-sign gate
  // (SendRawFlow: decode → simulate → ConfirmGate → eoa.send), one at a
  // time. `idx` is the leg currently in the gate.
  | { kind: "gate"; protocol: Protocol; legs: PreparedTx[]; idx: number }
  | { kind: "done"; protocol: Protocol; count: number }
  | { kind: "error"; message: string };

/** Shield deposit. User picks the privacy protocol (Privacy Pools v1 or
 *  Railgun), unlocks the EOA, then the daemon PREPARES the unsigned deposit
 *  legs which are routed through the canonical pre-sign gate before any
 *  signature.
 *
 *  Trust model: a shield is the user's own EOA approving + depositing into a
 *  pool contract — ordinary calldata produced by an untrusted sidecar. So
 *  it MUST flow through the same gate as every other send:
 *
 *    pick → form → unlock EOA
 *      → shielded.prepareDeposit / shielded.railgun.prepareShield  (unsigned legs)
 *      → for each leg: SendRawFlow  (decode → simulate → ConfirmGate → eoa.send)
 *
 *  The one-shot `shielded.deposit` / `shielded.railgun.shield` daemon RPCs
 *  (prepare+sign+broadcast in one call, no ConfirmGate) are NOT used here —
 *  they are retained only for the headless CLI. The user confirms the
 *  actual prepared calldata, not just the amount they typed.
 *
 *  Two distinct secrets per protocol:
 *    EOA passphrase  → daemon `eoa.unlock`
 *    Protocol secret → daemon `shielded.prepareDeposit` (PP) / EOA seed (Railgun)
 *  Kept separate so a leak of one doesn't compromise the other. Each
 *  protocol has its own on-disk encrypted store (PpSecretStore /
 *  RgSecretStore) — no shared key material between them.
 *
 *  Non-EOA wallets are gated out at the action menu, but we double-check here. */
export default function ShieldFlow({ wallet, onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "pickProtocol" });

  if (wallet.kind !== "eoa") {
    return (
      <Layout
        title="Shield deposit"
        subtitle={`${wallet.name} is not an EOA wallet`}
        hint="enter • back · esc • back"
      >
        <Banner
          kind="err"
          text="shield deposits require a secp256k1 EOA signer."
        />
      </Layout>
    );
  }

  if (phase.kind === "pickProtocol") {
    return (
      <Layout
        title={`Shield from ${wallet.name}`}
        subtitle="pick a privacy backend"
        hint="↑/↓ move · → / enter select · ← / esc cancel"
      >
        <Select
          items={[
            {
              label: "Privacy Pools v1 (0xBow) — Sepolia · ASP-gated unshield",
              value: "pp" as Protocol,
            },
            {
              label: "Railgun — Sepolia · POI-gated · 4337 + 7702 unshield",
              value: "railgun" as Protocol,
            },
          ]}
          arrowNav
          onBack={() => onDone(false)}
          onSelect={(it) => setPhase({ kind: "form", protocol: it.value })}
        />
      </Layout>
    );
  }

  if (phase.kind === "form") {
    // EOA unlock has been factored out into UnlockEoaStep. Privacy Pools
    // still needs a *second* passphrase (PpSecretStore — kept as a
    // separate encrypted store), but Railgun shares the EOA's BIP-39
    // seed (derives at its own BIP-32 paths) and so doesn't ask for a
    // distinct passphrase: the EOA unlock alone is enough.
    const isRailgun = phase.protocol === "railgun";
    const fields: Field[] = [
      {
        name: "amountEth",
        label: "Amount (ETH)",
        placeholder: "0.01",
        validate: (v) =>
          /^[0-9]+(\.[0-9]+)?$/.test(v) ? null : "expected a decimal ETH amount",
      },
      ...(isRailgun
        ? []
        : [
            {
              name: "protocolPass",
              label: "Privacy Pool passphrase",
              secret: true,
              validate: (v: string) => (v.length === 0 ? "required" : null),
            } satisfies Field,
          ]),
    ];
    const title = isRailgun
      ? `Shield from ${wallet.name} → Railgun`
      : `Shield from ${wallet.name} → Privacy Pools`;
    return (
      <Layout title={title}>
        <Form
          fields={fields}
          onSubmit={(v) => setPhase({ kind: "unlock", protocol: phase.protocol, v })}
          onCancel={() => setPhase({ kind: "pickProtocol" })}
        />
      </Layout>
    );
  }

  if (phase.kind === "unlock") {
    return (
      <UnlockEoaStep
        wallet={wallet}
        onUnlocked={() =>
          setPhase({ kind: "preparing", protocol: phase.protocol, v: phase.v })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  if (phase.kind === "preparing") {
    return (
      <PrepareShieldStep
        wallet={wallet}
        protocol={phase.protocol}
        v={phase.v}
        onReady={(legs) => {
          if (legs.length === 0) {
            setPhase({
              kind: "error",
              message: "prepare returned no transactions — check daemon logs",
            });
          } else {
            setPhase({ kind: "gate", protocol: phase.protocol, legs, idx: 0 });
          }
        }}
        onError={(message) => setPhase({ kind: "error", message })}
      />
    );
  }

  if (phase.kind === "gate") {
    const { legs, idx } = phase;
    const leg = legs[idx]!;
    const protoLabel = phase.protocol === "railgun" ? "Railgun" : "Privacy Pools";
    const signer: SendRawWallet = {
      kind: "eoa",
      name: wallet.name,
      address: wallet.address,
    };
    // Each leg goes through SendRawFlow's decode → simulate → ConfirmGate →
    // eoa.send. The EOA is already unlocked (UnlockEoaStep above), so
    // SendRawFlow's own UnlockEoaStep short-circuits — no second prompt.
    // eoa.send waits for the receipt daemon-side, so leg N mines before
    // leg N+1 simulates (the approve must land before the deposit).
    // `key` forces a fresh SendRawFlow per leg so its internal state resets.
    return (
      <SendRawFlow
        key={idx}
        tx={{
          to: leg.to,
          value: toHexValue(leg.value),
          data: leg.data,
          rationale: `${protoLabel} shield · leg ${idx + 1} of ${legs.length}`,
        }}
        chainId={SHIELD_CHAIN_ID}
        wallet={signer}
        onDone={(success) => {
          // Esc / failure on any leg aborts the whole shield. A partial
          // shield (e.g. approve sent, deposit cancelled) is left as-is;
          // the user can retry — the prepare path is idempotent.
          if (!success) {
            onDone(false);
            return;
          }
          if (idx + 1 < legs.length) {
            setPhase({ kind: "gate", protocol: phase.protocol, legs, idx: idx + 1 });
          } else {
            setPhase({ kind: "done", protocol: phase.protocol, count: legs.length });
          }
        }}
      />
    );
  }

  if (phase.kind === "done") {
    const protoLabel = phase.protocol === "railgun" ? "Railgun" : "Privacy Pools";
    return (
      <Layout
        title="Shield complete"
        subtitle={`${protoLabel} · Sepolia`}
        hint="enter / esc — back"
      >
        <Banner
          kind="ok"
          text={`${phase.count} transaction${phase.count === 1 ? "" : "s"} confirmed and broadcast.`}
        />
        <Text color={theme.dim}>
          Shielded balance becomes spendable once the pool indexes your
          deposit (Railgun POI can take minutes to hours).
        </Text>
        <BackOnInput onDone={() => onDone(true)} />
      </Layout>
    );
  }

  return (
    <Layout title="Shield deposit failed" hint="enter / esc — back">
      <Banner kind="err" text={phase.message} />
      <BackOnInput onDone={() => onDone(false)} />
    </Layout>
  );
}

/** Calls the daemon's prepare RPC to build the unsigned shield legs. No
 *  signature is produced here. Shown as a spinner because the bridge syncs
 *  pool state (30-60s typical; 10+ min on a cold first run). */
function PrepareShieldStep({
  wallet,
  protocol,
  v,
  onReady,
  onError,
}: {
  wallet: { name: string; address: string };
  protocol: Protocol;
  v: Record<string, string>;
  onReady: (legs: PreparedTx[]) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const isRailgun = protocol === "railgun";
      const method = isRailgun
        ? "shielded.railgun.prepareShield"
        : "shielded.prepareDeposit";
      const params: Record<string, string> = {
        name: wallet.name,
        amountEth: v.amountEth ?? "0",
      };
      // PP keeps its second secret in PpSecretStore; Railgun shares the EOA
      // seed (no second passphrase to plumb).
      if (!isRailgun && v.protocolPass) params.passphrase = v.protocolPass;

      // First-run state sync can take 10+ minutes (PP walks from the 0xBow
      // entrypoint deployment; Railgun from its smart-wallet + POI start
      // block). 20-min cap matches the old one-shot path's budget.
      const resp = await call<any>(method, params, { timeoutMs: 20 * 60 * 1000 });
      if (cancelled) return;
      if (!resp.ok) {
        onError(`prepare failed: ${resp.error.message}`);
        return;
      }
      const r = resp.result ?? {};
      const raw = r.txns ?? r.txs ?? r.transactions ?? r.result?.txns ?? [];
      const legs: PreparedTx[] = (Array.isArray(raw) ? raw : [])
        .map((t: any) => ({
          to: String(t?.to ?? ""),
          value: toHexValue(t?.value),
          data: String(t?.data ?? "0x"),
        }))
        .filter((t: PreparedTx) => t.to.length > 0);
      onReady(legs);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const protoLabel = protocol === "railgun" ? "Railgun" : "Privacy Pools";
  return (
    <Layout title={`Preparing shield → ${protoLabel}`} subtitle="Sepolia">
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>
          building unsigned deposit txns (syncing pool state — first run can
          take several minutes)…
        </Text>
      </Text>
    </Layout>
  );
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
