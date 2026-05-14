import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import Select from "../widgets/Select.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { shortAddr } from "../format.js";

type Props = { onDone: (success: boolean) => void };

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const MIN_PIN_LENGTH = 4;

type EoaSlot = { name: string; address: string };

type Phase =
  | { kind: "form" }
  | { kind: "creating"; name: string; pin: string }
  | { kind: "deploy-pick"; name: string }
  | { kind: "deploy-eoa-load"; name: string }
  | { kind: "deploy-eoa-pick"; name: string; eoas: EoaSlot[] }
  | { kind: "deploy-eoa-form"; name: string; deployer: EoaSlot }
  | { kind: "deploy-error"; name: string; message: string }
  | {
      kind: "deploying";
      name: string;
      params: Record<string, unknown>;
      via: "env" | "eoa";
    };

/** Inline TPM/R1 wallet creation. Collects wallet name + TPM PIN (with a
 *  matching confirm field) in a single sequential form, runs `tpm.create`,
 *  then offers a choice of deployer (.env relayer or an in-wallet EOA)
 *  before launching `tpm.deploy`. */
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
        key="r1-create"
        title="Creating TPM/R1 wallet…"
        subtitle={`name: ${name} · PIN bound to TPM key`}
        method="tpm.create"
        params={{ name, pin: phase.pin }}
        renderResult={(r: any) => {
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
                  Delete the old slot and retry with a fresh name:
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
                Next: pick a deployer to pay gas for the R1 smart account
                deployment.
              </Text>
            </Box>
          );
        }}
        successActions={[
          {
            label: "Deploy on Sepolia now",
            onSelect: () => setPhase({ kind: "deploy-pick", name }),
          },
          {
            label:
              "Skip — return to menu (deploy later with `kohaku wallet deploy`)",
            onSelect: () => onDone(true),
          },
        ]}
        onDone={onDone}
      />
    );
  }

  if (phase.kind === "deploy-pick") {
    // Two relayer choices: a wallet EOA (we'll unlock + derive pk) or
    // the `.env` / shell-exported SEPOLIA_DEPLOYER_PRIVATE_KEY. The
    // wallet-EOA path is the user-friendly default since the daemon's
    // .env autoload covers the env path automatically when the file
    // exists.
    return (
      <Layout
        title="Pick a deployer"
        subtitle={`who pays gas for the ${phase.name} R1 smart-account deploy on Sepolia?`}
        hint="↑/↓ move · enter pick · esc cancel"
      >
        <Select
          items={[
            {
              label: "Use a wallet EOA (recommended)",
              value: "eoa",
            },
            {
              label:
                "Use .env relayer (SEPOLIA_DEPLOYER_PRIVATE_KEY from .env or shell)",
              value: "env",
            },
          ]}
          onSelect={(it) => {
            if (it.value === "env") {
              setPhase({
                kind: "deploying",
                name: phase.name,
                params: { name: phase.name, chain: "sepolia", deployer: "env" },
                via: "env",
              });
            } else {
              setPhase({ kind: "deploy-eoa-load", name: phase.name });
            }
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "deploy-eoa-load") {
    return (
      <DeployerEoaLoader
        onLoaded={(eoas) =>
          setPhase({ kind: "deploy-eoa-pick", name: phase.name, eoas })
        }
        onError={(message) =>
          setPhase({ kind: "deploy-error", name: phase.name, message })
        }
      />
    );
  }

  if (phase.kind === "deploy-eoa-pick") {
    if (phase.eoas.length === 0) {
      return (
        <Layout title="No deployer EOA available" hint="esc — back">
          <Banner
            kind="err"
            text="No EOA wallets configured. Create one with `kohaku wallet create eoa <name>` or use the .env deployer instead."
          />
        </Layout>
      );
    }
    return (
      <Layout
        title="Pick deployer EOA"
        subtitle="this EOA's private key will pay gas for the R1 deploy; passphrase prompted next"
        hint="↑/↓ move · enter pick · esc cancel"
      >
        <Select
          items={phase.eoas.map((e) => ({
            label: `${e.name.padEnd(16)}  ${shortAddr(e.address)}`,
            value: e.name,
          }))}
          onSelect={(it) => {
            const eoa = phase.eoas.find((e) => e.name === it.value);
            if (eoa) {
              setPhase({
                kind: "deploy-eoa-form",
                name: phase.name,
                deployer: eoa,
              });
            }
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "deploy-eoa-form") {
    const fields: Field[] = [
      {
        name: "passphrase",
        label: `Passphrase for ${phase.deployer.name}`,
        secret: true,
        validate: (v) => (v.length === 0 ? "required" : null),
      },
    ];
    return (
      <Layout
        title={`Unlock ${phase.deployer.name} to deploy`}
        subtitle={`address: ${phase.deployer.address}`}
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) =>
            setPhase({
              kind: "deploying",
              name: phase.name,
              via: "eoa",
              params: {
                name: phase.name,
                chain: "sepolia",
                deployer: "eoa",
                deployerEoa: phase.deployer.name,
                deployerPassphrase: v.passphrase ?? "",
              },
            })
          }
        />
      </Layout>
    );
  }

  if (phase.kind === "deploy-error") {
    return (
      <Layout title="Deployer setup failed" hint="enter / esc — back to menu">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }

  // phase.kind === "deploying"
  return (
    <RpcRunner
      key="r1-deploy"
      title={`Deploying R1 smart account for ${phase.name} on Sepolia…`}
      subtitle={
        phase.via === "eoa"
          ? "wallet EOA pays gas · TPM key isn't used (P-256 sig not needed for deploy)"
          : ".env relayer pays gas · TPM key isn't used (P-256 sig not needed for deploy)"
      }
      method="tpm.deploy"
      params={phase.params}
      renderResult={(r: any) => {
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
            {text && <Text color={theme.dim}>{text.split("\n")[0]}</Text>}
          </Box>
        );
      }}
      onDone={onDone}
    />
  );
}

/** Load EOAs from the daemon for the deployer picker. Returned list is
 *  whatever `eoa.list` reports, address-mapped for display + identity. */
function DeployerEoaLoader({
  onLoaded,
  onError,
}: {
  onLoaded: (eoas: EoaSlot[]) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<any[]>("eoa.list");
      if (cancelled) return;
      if (!r.ok) return onError(`eoa.list failed: ${r.error.message}`);
      const list = Array.isArray(r.result) ? r.result : [];
      const eoas: EoaSlot[] = [];
      for (const e of list) {
        if (e?.name && e?.address) {
          eoas.push({ name: e.name, address: e.address });
        }
      }
      onLoaded(eoas);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Loading EOAs…">
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>asking the daemon for deployer candidates</Text>
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
