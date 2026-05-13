import React, { useState } from "react";
import { Box, Text } from "ink";
import { Layout } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";

type Props = { onDone: (success: boolean) => void };

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const MIN_PIN_LENGTH = 4;

/** Inline TPM/R1 wallet creation. The user picks a name and a PIN; the daemon
 *  binds the PIN as the TPM2 key's `userwithauth` value so the TPM itself
 *  enforces it on every signature. Wrong-PIN attempts trigger the TPM's
 *  hardware dictionary-attack lockout. */
export default function CreateR1Flow({ onDone }: Props) {
  const [name, setName] = useState<string | null>(null);
  const [pin, setPin] = useState<string | null>(null);

  if (!name) {
    const fields: Field[] = [
      {
        name: "name",
        label: "Wallet name",
        placeholder: "e.g. daily-r1",
        validate: (v) =>
          NAME_RE.test(v)
            ? null
            : "1–64 chars: letters, digits, '-' or '_'; must start with alnum",
      },
    ];
    return (
      <Layout
        title="Create TPM/R1 wallet"
        subtitle="A P-256 keypair will be generated inside the TPM and bound to a PIN you choose."
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) => setName(v.name ?? null)}
        />
      </Layout>
    );
  }

  if (!pin) {
    const fields: Field[] = [
      {
        name: "pin",
        label: `TPM PIN (min ${MIN_PIN_LENGTH} chars)`,
        secret: true,
        validate: (v) =>
          v.length >= MIN_PIN_LENGTH
            ? null
            : `at least ${MIN_PIN_LENGTH} characters`,
      },
    ];
    return (
      <Layout
        title="Set TPM PIN"
        subtitle={`name: ${name} · this PIN will be required on every signature; the TPM cannot recover it for you`}
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) => setPin(v.pin ?? null)}
        />
      </Layout>
    );
  }

  return (
    <RpcRunner
      title="Creating TPM/R1 wallet…"
      subtitle={`name: ${name} · PIN bound to TPM key`}
      method="tpm.create"
      params={{ name, pin }}
      renderResult={(r: any) => (
        <Box flexDirection="column">
          <Text color={theme.ok}>✓ created</Text>
          {r?.address && (
            <Text color={theme.dim}>address: {r.address}</Text>
          )}
          <Text color={theme.dim}>
            Deploy the smart-account wrapper with: kohaku wallet deploy {name}
          </Text>
        </Box>
      )}
      onDone={onDone}
    />
  );
}
