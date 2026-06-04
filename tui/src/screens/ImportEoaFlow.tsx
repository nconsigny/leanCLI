import React, { useState } from "react";
import { Box, Text } from "ink";
import { Layout } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";

type Props = { onDone: (s: boolean) => void };

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const PATH_RE = /^m(\/[0-9]+'?)+$/;

/** Inline mnemonic import (`leancli wallet import`). */
export default function ImportEoaFlow({ onDone }: Props) {
  const [params, setParams] = useState<Record<string, string> | null>(null);

  if (!params) {
    const fields: Field[] = [
      {
        name: "name",
        label: "Wallet name",
        validate: (v) => (NAME_RE.test(v) ? null : "1–64 alnum/-/_, alnum start"),
      },
      {
        name: "mnemonic",
        label: "BIP-39 mnemonic",
        placeholder: "12 or 24 words",
        validate: (v) =>
          v.split(/\s+/).filter(Boolean).length >= 12
            ? null
            : "expected at least 12 words",
      },
      {
        name: "derivationPath",
        label: "Derivation path (optional)",
        placeholder: "m/44'/60'/0'/0/0",
        validate: (v) =>
          v.length === 0 || PATH_RE.test(v) ? null : "expected BIP-32 path",
      },
      {
        name: "passphrase",
        label: "Passphrase to encrypt at rest",
        secret: true,
        validate: (v) => (v.length < 8 ? "min 8 chars" : null),
      },
    ];
    return (
      <Layout
        title="Import EOA from mnemonic"
        subtitle="The mnemonic is sent to the local daemon over UDS and never leaves this host."
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) =>
            setParams({
              name: v.name ?? "",
              mnemonic: v.mnemonic ?? "",
              passphrase: v.passphrase ?? "",
              ...(v.derivationPath ? { derivationPath: v.derivationPath } : {}),
            })
          }
        />
      </Layout>
    );
  }

  return (
    <RpcRunner
      title="Importing EOA…"
      subtitle={`name: ${params.name}`}
      method="eoa.import"
      params={params}
      renderResult={(r: any) => (
        <Box flexDirection="column">
          <Text color={theme.ok}>✓ imported</Text>
          <Text color={theme.dim}>address: {r?.address ?? "(unknown)"}</Text>
        </Box>
      )}
      onDone={onDone}
    />
  );
}
