import React, { useState } from "react";
import { Box, Text } from "ink";
import { Wallet } from "../types.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import Select from "../widgets/Select.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";
import { hexToBigInt, formatEth } from "../format.js";
import UnlockEoaStep from "./UnlockEoaStep.js";

type Props = {
  wallet: Wallet;
  onDone: (success: boolean) => void;
};

type Protocol = "pp" | "railgun";

type Phase =
  | { kind: "pickProtocol" }
  | { kind: "form"; protocol: Protocol }
  | { kind: "unlock"; protocol: Protocol; v: Record<string, string> }
  | { kind: "deposit"; protocol: Protocol; v: Record<string, string> }
  | { kind: "error"; message: string };

/** Shield deposit. User first picks the privacy protocol (Privacy Pools
 *  v1 or Railgun), then unlocks the EOA, then deposits.
 *
 *  Two distinct secrets per protocol:
 *    EOA passphrase  → daemon `eoa.unlock`
 *    Protocol secret → daemon `shielded.deposit` (PP) or `shielded.railgun.shield`
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
          setPhase({ kind: "deposit", protocol: phase.protocol, v: phase.v })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  if (phase.kind === "deposit") {
    const isRailgun = phase.protocol === "railgun";
    const method = isRailgun ? "shielded.railgun.shield" : "shielded.deposit";
    const subtitle = isRailgun
      ? "Railgun · Sepolia"
      : "Privacy Pools v1 · Sepolia";
    const params: Record<string, string> = {
      name: wallet.name,
      amountEth: phase.v.amountEth ?? "0",
    };
    // PP keeps its second secret in PpSecretStore; Railgun shares the
    // EOA seed (no second passphrase to plumb).
    if (!isRailgun && phase.v.protocolPass) {
      params.passphrase = phase.v.protocolPass;
    }
    return (
      <RpcRunner
        title={`Shielding ${phase.v.amountEth} ETH from ${wallet.name}`}
        subtitle={subtitle}
        method={method}
        params={params}
        // First-run state sync can take 10+ minutes — both protocols
        // walk every relevant on-chain event from their pool's birth
        // (PP: 0xBow entrypoint deployment; Railgun: smart wallet
        // deployment + POI start block). Cached runs return in seconds.
        // 20-minute window covers both with margin so the TUI doesn't
        // give up before the daemon does. Bridge stderr is captured so
        // a real error still surfaces.
        timeoutMs={20 * 60 * 1000}
        renderResult={(r) => <ShieldResult result={r} />}
        onDone={onDone}
      />
    );
  }

  return (
    <Layout title="Shield deposit failed" hint="enter • back · esc • back">
      <Banner kind="err" text={phase.message} />
    </Layout>
  );
}

function ShieldResult({ result }: { result: any }) {
  const sent = Array.isArray(result?.sent) ? result.sent : [];
  if (sent.length === 0) {
    return (
      <Text color={theme.warn}>
        deposit returned no broadcast txs — check daemon logs
      </Text>
    );
  }
  return (
    <Box flexDirection="column">
      {sent.map((tx: any, i: number) => {
        const status = tx?.status ?? "?";
        const txHash = tx?.txHash ?? "(no hash)";
        const block = hexToBigInt(tx?.blockNumber);
        const value = (() => {
          try {
            return BigInt(tx?.value ?? "0");
          } catch {
            return 0n;
          }
        })();
        return (
          <Box key={i} flexDirection="column" marginBottom={1}>
            <Text>
              <Text color={status === "success" ? theme.ok : theme.err}>
                {status === "success" ? "✓" : "✗"}
              </Text>{" "}
              {txHash}
            </Text>
            <Text color={theme.dim}>
              {"  "}value {formatEth(value)} · block {block.toString()}
            </Text>
            <Text color={theme.dim}>
              {"  "}https://sepolia.etherscan.io/tx/{txHash}
            </Text>
          </Box>
        );
      })}
    </Box>
  );
}
