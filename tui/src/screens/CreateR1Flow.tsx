import React, { useState } from "react";
import { Box, Text } from "ink";
import { Layout } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";

type Props = { onDone: (success: boolean) => void };

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const MIN_PIN_LENGTH = 4;

type Phase =
  | { kind: "form" }
  | { kind: "creating"; name: string; pin: string }
  | { kind: "deploying"; name: string };

/** Inline TPM/R1 wallet creation. Collects wallet name + TPM PIN (with a
 *  matching confirm field) in a single sequential form, runs `tpm.create`,
 *  then offers a choice between deploying the smart account on Sepolia
 *  immediately or returning to the main menu. */
export default function CreateR1Flow({ onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "form" });

  if (phase.kind === "form") {
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
      {
        name: "confirm",
        label: "Confirm PIN",
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
          onSubmit={(v) => {
            // Match CreateEoaFlow's pattern: on mismatch, re-render the
            // form (cheapest path; user retypes both fields).
            if (v.pin !== v.confirm) {
              setPhase({ kind: "form" });
              return;
            }
            setPhase({
              kind: "creating",
              name: v.name ?? "",
              pin: v.pin ?? "",
            });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "creating") {
    const name = phase.name;
    return (
      <RpcRunner
        title="Creating TPM/R1 wallet…"
        subtitle={`name: ${name} · PIN bound to TPM key`}
        method="tpm.create"
        params={{ name, pin: phase.pin }}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ created</Text>
            {r?.address && <Text color={theme.dim}>address: {r.address}</Text>}
            <Text color={theme.dim}>
              Next: deploy the smart-account wrapper on Sepolia.
            </Text>
          </Box>
        )}
        successActions={[
          {
            label: "Deploy on Sepolia now",
            onSelect: () => setPhase({ kind: "deploying", name }),
          },
          {
            label: "Skip — return to menu (deploy later with `kohaku wallet deploy`)",
            onSelect: () => onDone(true),
          },
        ]}
        onDone={onDone}
      />
    );
  }

  // phase.kind === "deploying"
  return (
    <RpcRunner
      title={`Deploying R1 smart account for ${phase.name} on Sepolia…`}
      subtitle="relayer EOA pays gas · no TPM signature required for deploy"
      method="tpm.deploy"
      params={{ name: phase.name, chain: "sepolia" }}
      renderResult={(r: any) => (
        <Box flexDirection="column">
          <Text color={theme.ok}>✓ deployed</Text>
          {r?.text && <Text color={theme.dim}>{String(r.text).split("\n")[0]}</Text>}
        </Box>
      )}
      onDone={onDone}
    />
  );
}
