import React, { useState } from "react";
import { Box, Text } from "ink";
import { Wallet } from "../types.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { hexToBigInt, formatEth } from "../format.js";

type Props = {
  wallet: Wallet;
  onDone: (success: boolean) => void;
};

type Phase =
  | { kind: "form" }
  | { kind: "unlock"; v: Record<string, string> }
  | { kind: "deposit"; v: Record<string, string> }
  | { kind: "error"; message: string };

/** Privacy-Pools deposit. Two distinct secrets:
 *   1. EOA passphrase  → daemon `eoa.unlock`
 *   2. PP passphrase   → daemon `shielded.deposit`
 *  Kept separate so a leak of one doesn't compromise the other. TPM
 *  wallets are gated out at the action menu, but we double-check here. */
export default function ShieldFlow({ wallet, onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "form" });

  if (wallet.kind !== "eoa") {
    return (
      <Layout
        title="Shield deposit"
        subtitle={`${wallet.name} is a TPM/R1 wallet`}
        hint="enter • back · esc • back"
      >
        <Banner
          kind="err"
          text="shield deposits require a secp256k1 EOA signer; not yet supported for TPM."
        />
      </Layout>
    );
  }

  if (phase.kind === "form") {
    const fields: Field[] = [
      {
        name: "amountEth",
        label: "Amount (ETH)",
        placeholder: "0.01",
        validate: (v) =>
          /^[0-9]+(\.[0-9]+)?$/.test(v) ? null : "expected a decimal ETH amount",
      },
      {
        name: "eoaPass",
        label: `Passphrase for EOA '${wallet.name}'`,
        secret: true,
        validate: (v) => (v.length === 0 ? "required" : null),
      },
      {
        name: "ppPass",
        label: "Privacy Pool passphrase",
        secret: true,
        validate: (v) => (v.length === 0 ? "required" : null),
      },
    ];
    return (
      <Layout title={`Shield from ${wallet.name}`}>
        <Form
          fields={fields}
          onSubmit={(v) => setPhase({ kind: "unlock", v })}
          onCancel={() => onDone(false)}
        />
      </Layout>
    );
  }

  if (phase.kind === "unlock") {
    // Inline unlock then auto-advance to deposit.
    return (
      <UnlockThen
        name={wallet.name}
        passphrase={phase.v.eoaPass!}
        onUnlocked={() => setPhase({ kind: "deposit", v: phase.v })}
        onError={(msg) => setPhase({ kind: "error", message: msg })}
      />
    );
  }

  if (phase.kind === "deposit") {
    return (
      <RpcRunner
        title={`Shielding ${phase.v.amountEth} ETH from ${wallet.name}`}
        subtitle="Privacy Pools v1 · Sepolia"
        method="shielded.deposit"
        params={{
          name: wallet.name,
          amountEth: phase.v.amountEth,
          passphrase: phase.v.ppPass,
        }}
        // First-run PP state sync can take 10+ minutes — the SDK
        // walks every relevant on-chain event from the pool's birth.
        // Cached runs return in seconds. 20-minute window covers both
        // with margin so the TUI doesn't give up before the daemon
        // does. Bridge stderr is captured (slice 32) so a real error
        // still surfaces.
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

function UnlockThen({
  name,
  passphrase,
  onUnlocked,
  onError,
}: {
  name: string;
  passphrase: string;
  onUnlocked: () => void;
  onError: (msg: string) => void;
}) {
  React.useEffect(() => {
    let cancelled = false;
    call("eoa.unlock", { name, passphrase }).then((r) => {
      if (cancelled) return;
      if (r.ok) onUnlocked();
      else onError(`unlock failed: ${r.error.message}`);
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Unlocking EOA…">
      <Text color={theme.dim}>verifying passphrase for {name}</Text>
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
