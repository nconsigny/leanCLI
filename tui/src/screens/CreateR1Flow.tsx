import React, { useState } from "react";
import { Box, Text } from "ink";
import { Layout } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";

type Props = { onDone: (success: boolean) => void };

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const MIN_PIN_LENGTH = 4;

/** Inline TPM/R1 wallet creation. Collects wallet name + TPM PIN in a
 *  single sequential form (same pattern as CreateEoaFlow), then sends
 *  `tpm.create` with the PIN. The daemon binds the PIN as the TPM2 key's
 *  `userwithauth` value so the TPM enforces it on every signature. */
export default function CreateR1Flow({ onDone }: Props) {
  const [params, setParams] = useState<{ name: string; pin: string } | null>(
    null,
  );

  if (!params) {
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
      {
        name: "pin",
        label: `TPM PIN (min ${MIN_PIN_LENGTH} chars)`,
        secret: true,
        validate: (v) =>
          v.length < MIN_PIN_LENGTH
            ? `at least ${MIN_PIN_LENGTH} characters`
            : null,
      },
    ];
    return (
      <Layout
        title="Create TPM/R1 wallet"
        subtitle="P-256 key generated inside the TPM and bound to a PIN. Wrong-PIN attempts are rate-limited by the TPM's hardware dictionary-attack lockout."
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) =>
            setParams({ name: v.name ?? "", pin: v.pin ?? "" })
          }
        />
      </Layout>
    );
  }

  return (
    <RpcRunner
      title="Creating TPM/R1 wallet…"
      subtitle={`name: ${params.name} · PIN bound to TPM key`}
      method="tpm.create"
      params={{ name: params.name, pin: params.pin }}
      renderResult={(r: any) => (
        <Box flexDirection="column">
          <Text color={theme.ok}>✓ created</Text>
          {r?.address && (
            <Text color={theme.dim}>address: {r.address}</Text>
          )}
          <Text color={theme.dim}>
            Deploy the smart-account wrapper with: kohaku wallet deploy {params.name}
          </Text>
        </Box>
      )}
      onDone={onDone}
    />
  );
}
