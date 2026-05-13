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
    // `key` forces a fresh RpcRunner mount when we transition from
    // "creating" to "deploying". Without it React reuses the same
    // component instance because both phases render <RpcRunner /> at
    // the same JSX position; the events/state from create leak into
    // deploy and the deploy useEffect (deps [] ) never re-runs, so
    // tpm.deploy is never actually called.
    return (
      <RpcRunner
        key="r1-create"
        title="Creating TPM/R1 wallet…"
        subtitle={`name: ${name} · PIN bound to TPM key`}
        method="tpm.create"
        params={{ name, pin: phase.pin }}
        renderResult={(r: any) => {
          // Daemon reports `{text, exitCode}` — `text` carries the status line.
          // alreadyExists has exitCode 0 (intentional, so scripts can re-run
          // create idempotently), so we cannot rely on exitCode alone.
          const text = typeof r?.text === "string" ? r.text : "";
          const exitCode = typeof r?.exitCode === "number" ? r.exitCode : 0;
          const alreadyExisted = /status:\s*already exists/i.test(text);
          const created = /status:\s*created/i.test(text);
          if (alreadyExisted) {
            return (
              <Box flexDirection="column">
                <Text color={theme.warn}>
                  ⚠ A TPM key named "{name}" already exists. NOT recreated;
                  the PIN you typed was NOT bound to it.
                </Text>
                <Text color={theme.dim}>
                  If the existing slot was created under the old fprintd build,
                  delete it and retry with a fresh name:
                </Text>
                <Text color={theme.dim}>
                  rm -rf .leankohaku/keystore/tpm2/{name}
                </Text>
              </Box>
            );
          }
          if (!created || exitCode !== 0) {
            return (
              <Box flexDirection="column">
                <Text color={theme.err}>✗ create did not report success</Text>
                {text && <Text color={theme.dim}>{text.slice(0, 400)}</Text>}
              </Box>
            );
          }
          return (
            <Box flexDirection="column">
              <Text color={theme.ok}>✓ created (PIN bound to TPM key)</Text>
              <Text color={theme.dim}>
                Next: deploy the smart-account wrapper on Sepolia.
              </Text>
            </Box>
          );
        }}
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
      key="r1-deploy"
      title={`Deploying R1 smart account for ${phase.name} on Sepolia…`}
      subtitle="relayer EOA pays gas · no TPM signature required for deploy"
      method="tpm.deploy"
      params={{ name: phase.name, chain: "sepolia" }}
      renderResult={(r: any) => {
        // tpm.deploy also returns {text, exitCode}. The deploy script
        // exits non-zero on failure; idempotent re-runs over an already-
        // deployed slot exit 0 with a "already deployed" hint in text.
        const text = typeof r?.text === "string" ? r.text : "";
        const exitCode = typeof r?.exitCode === "number" ? r.exitCode : 1;
        if (exitCode !== 0) {
          return (
            <Box flexDirection="column">
              <Text color={theme.err}>✗ deploy failed (exit {exitCode})</Text>
              {text && <Text color={theme.dim}>{text.slice(0, 600)}</Text>}
            </Box>
          );
        }
        const alreadyDeployed = /already deployed/i.test(text);
        return (
          <Box flexDirection="column">
            <Text color={theme.ok}>
              {alreadyDeployed ? "✓ already deployed" : "✓ deployed"}
            </Text>
            {text && (
              <Text color={theme.dim}>{text.split("\n")[0]}</Text>
            )}
          </Box>
        );
      }}
      onDone={onDone}
    />
  );
}
