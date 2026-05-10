import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import Select from "../widgets/Select.js";
import { Wallet } from "../types.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";

type Props = { wallet: Wallet; onDone: (s: boolean) => void };

type Phase =
  | { kind: "warn" }
  | { kind: "form" }
  | { kind: "run"; passphrase: string };

/** Reveal the BIP-39 mnemonic of an EOA. Three gates:
 *  1. Explicit confirmation screen (Yes/No) so an accidental Enter on
 *     the action menu can't dump secrets.
 *  2. Passphrase prompt (masked).
 *  3. Re-type wallet name in the form to defuse muscle-memory accidents.
 *  Slots without a stored mnemonic (created before retention) fail with
 *  a clear, distinctive error from the daemon. */
export default function RevealMnemonicFlow({ wallet, onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "warn" });

  if (wallet.kind !== "eoa") {
    return (
      <Layout title="Not applicable" hint="enter • back · esc • back">
        <Banner kind="err" text="TPM/R1 wallets have no BIP-39 mnemonic." />
        <BackOnEsc onDone={() => onDone(false)} />
      </Layout>
    );
  }

  if (phase.kind === "warn") {
    return (
      <Layout
        title={`Reveal mnemonic for ${wallet.name}`}
        subtitle="DANGER · the words give full control of the funds"
        hint="↑/↓ move · enter select · esc cancel"
      >
        <Box flexDirection="column" marginBottom={1}>
          <Text color={theme.warn}>
            ⚠ Anyone with these 12/24 words can drain this wallet.
          </Text>
          <Text color={theme.dim}>
            • Make sure no one is looking and no screen recorder is on.
          </Text>
          <Text color={theme.dim}>
            • The TUI runs on the alt-screen, so the words won't land in
              your shell scrollback after you exit.
          </Text>
          <Text color={theme.dim}>
            • If this slot was created before mnemonic retention, the
              daemon will refuse and only the raw seed could be exported.
          </Text>
        </Box>
        <Select
          items={[
            { label: "← Cancel",                         value: "cancel" },
            { label: "I understand — show the mnemonic", value: "go" },
          ]}
          onSelect={(it) => {
            if (it.value === "go") setPhase({ kind: "form" });
            else onDone(false);
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "form") {
    const fields: Field[] = [
      {
        name: "confirmName",
        label: `Type '${wallet.name}' to confirm`,
        validate: (v) =>
          v.trim() === wallet.name ? null : "must match the wallet name exactly",
      },
      {
        name: "passphrase",
        label: `Passphrase for ${wallet.name}`,
        secret: true,
        validate: (v) => (v.length === 0 ? "required" : null),
      },
    ];
    return (
      <Layout title={`Reveal mnemonic for ${wallet.name}`}>
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) =>
            setPhase({ kind: "run", passphrase: v.passphrase ?? "" })
          }
        />
      </Layout>
    );
  }

  return (
    <RpcRunner
      title={`Decrypting mnemonic for ${wallet.name}…`}
      subtitle="passphrase-derived key · ChaCha20-Poly1305"
      method="eoa.revealMnemonic"
      params={{ name: wallet.name, passphrase: phase.passphrase }}
      renderResult={(r: any) => <RevealResult result={r} />}
      onDone={onDone}
    />
  );
}

function RevealResult({ result }: { result: any }) {
  const words: string[] = Array.isArray(result?.mnemonic) ? result.mnemonic : [];
  if (words.length === 0) {
    return <Text color={theme.warn}>(daemon returned no words)</Text>;
  }
  // Render as a numbered grid (4 columns) — easier to verify on paper.
  const cols = 4;
  const rows: string[][] = [];
  for (let i = 0; i < words.length; i += cols) {
    rows.push(words.slice(i, i + cols));
  }
  return (
    <Box flexDirection="column">
      <Text color={theme.warn} bold>
        ⚠ Mnemonic ({words.length} words). Write these down NOW.
      </Text>
      <Box marginTop={1} flexDirection="column">
        {rows.map((row, rIdx) => (
          <Box key={rIdx}>
            {row.map((w, cIdx) => {
              const idx = rIdx * cols + cIdx + 1;
              return (
                <Text key={cIdx}>
                  <Text color={theme.dim}>{String(idx).padStart(2, " ")}. </Text>
                  <Text bold>{w.padEnd(12)}</Text>
                </Text>
              );
            })}
          </Box>
        ))}
      </Box>
      <Box marginTop={1}>
        <Text color={theme.dim}>
          This mnemonic has been printed on a laptop screen — it's only as
          safe as the laptop. For high-value transactions, use a hardware
          wallet.
        </Text>
      </Box>
    </Box>
  );
}

function BackOnEsc({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
