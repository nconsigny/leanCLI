import React, { useState } from "react";
import { Box, Text } from "ink";
import Select from "../widgets/Select.js";
import { Layout } from "../widgets/Layout.js";
import Form from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";
import { hexToBigInt, formatEth } from "../format.js";

type VaultAction = "list" | "export" | "import" | "back";

type Props = { onDone: (s: boolean) => void };

// Tornado note sync + secret derivation walks pool events since the pool's
// birth on first run; cached runs are fast. Match the Privacy-Pools budget.
const TC_TIMEOUT_MS = 20 * 60 * 1000;

/** Tornado Cash note vault: inspect this wallet's notes, back them up to a
 *  password-encrypted file, or import a backup and confirm which notes are
 *  yours. All three prompt for a password before any secret is derived. The
 *  export file is sealed by the daemon (NoteVault, ChaCha20-Poly1305); the
 *  plaintext secrets never reach this process. */
export default function TornadoVaultFlow({ onDone }: Props) {
  const [pick, setPick] = useState<VaultAction | null>(null);
  const [params, setParams] = useState<Record<string, string> | null>(null);

  if (!pick) {
    return (
      <Layout
        title="Tornado Cash · notes vault"
        subtitle="password-gated backup & recovery of shielded notes"
        hint="↑/↓ move · → / enter select · ← / esc back"
      >
        <Select
          items={[
            { label: "List my notes (denomination · status · index)", value: "list" as VaultAction },
            { label: "Export notes to an encrypted vault file", value: "export" as VaultAction },
            { label: "Import a vault file & verify ownership", value: "import" as VaultAction },
            { label: "← Back", value: "back" as VaultAction },
          ]}
          arrowNav
          onBack={() => onDone(false)}
          onSelect={(it) => {
            const v = it.value;
            if (v === "back") onDone(false);
            else setPick(v);
          }}
        />
      </Layout>
    );
  }

  if (!params) {
    if (pick === "list") {
      // Listing needs no password — notes are (pool, index), no secret shown.
      // Kept as a zero-field submit so the RpcRunner path below is uniform.
      setTimeout(() => setParams({}), 0);
      return null;
    }
    if (pick === "export") {
      return (
        <Layout title="Export notes to encrypted vault">
          <Form
            fields={[
              {
                name: "path",
                label: "Vault file path to write",
                placeholder: "~/tornado-notes.vault.json",
                validate: (v) => (v.trim().length === 0 ? "required" : null),
              },
              {
                name: "password",
                label: "Vault password (encrypts the backup)",
                secret: true,
                validate: (v) => (v.length < 8 ? "use at least 8 characters" : null),
              },
              {
                name: "confirm",
                label: "Confirm password",
                secret: true,
              },
            ]}
            onCancel={() => setPick(null)}
            onSubmit={(v) => {
              if ((v.password ?? "") !== (v.confirm ?? "")) {
                // Bounce back to the menu; Form has no cross-field validate.
                setPick(null);
                return;
              }
              setParams({ path: v.path ?? "", password: v.password ?? "" });
            }}
          />
        </Layout>
      );
    }
    // import
    return (
      <Layout title="Import notes vault">
        <Form
          fields={[
            {
              name: "path",
              label: "Vault file path to read",
              placeholder: "~/tornado-notes.vault.json",
              validate: (v) => (v.trim().length === 0 ? "required" : null),
            },
            {
              name: "password",
              label: "Vault password",
              secret: true,
              validate: (v) => (v.length === 0 ? "required" : null),
            },
          ]}
          onCancel={() => setPick(null)}
          onSubmit={(v) => setParams({ path: v.path ?? "", password: v.password ?? "" })}
        />
      </Layout>
    );
  }

  const method =
    pick === "list" ? "shielded.tornado.notes" :
    pick === "export" ? "shielded.tornado.vault.export" :
                        "shielded.tornado.vault.import";

  const rpcParams =
    pick === "list" ? { includeSpent: true } : params;

  return (
    <RpcRunner
      title={`Tornado vault: ${pick}`}
      method={method}
      params={rpcParams}
      timeoutMs={TC_TIMEOUT_MS}
      renderResult={(r: any) =>
        pick === "list" ? (
          <NotesResult result={r} />
        ) : pick === "export" ? (
          <ExportResult result={r} />
        ) : (
          <ImportResult result={r} />
        )
      }
      onDone={(s) => {
        setParams(null);
        setPick(null);
        onDone(s);
      }}
    />
  );
}

function unwrap(r: any): any {
  return r?.result ?? r;
}

function NotesResult({ result }: { result: any }) {
  const inner = unwrap(result);
  const notes: any[] = Array.isArray(inner?.notes) ? inner.notes : [];
  if (notes.length === 0) return <Text color={theme.dim}>no notes found for this wallet</Text>;
  return (
    <Box flexDirection="column">
      <Text color={theme.dim}>{notes.length} note(s):</Text>
      {notes.map((n, i) => (
        <Text key={i} color={n.status === "spendable" ? theme.ok : theme.dim}>
          {formatEth(hexToBigInt(n.denominationWei))} · {n.status} · index {String(n.depositIndex)}
        </Text>
      ))}
    </Box>
  );
}

function ExportResult({ result }: { result: any }) {
  const inner = unwrap(result);
  return (
    <Box flexDirection="column">
      <Text color={theme.ok}>backed up {String(inner?.count ?? "?")} note(s)</Text>
      <Text>→ {String(inner?.path ?? "")}</Text>
      <Text color={theme.dim}>keep this file and its password safe — it recovers your notes</Text>
    </Box>
  );
}

function ImportResult({ result }: { result: any }) {
  const inner = unwrap(result);
  const notes: any[] = Array.isArray(inner?.notes) ? inner.notes : [];
  return (
    <Box flexDirection="column">
      <Text color={theme.ok}>
        {String(inner?.mineCount ?? 0)} of {String(inner?.count ?? notes.length)} note(s) belong to this wallet
      </Text>
      {notes.map((n, i) => (
        <Text key={i} color={n.mine ? (n.status === "spendable" ? theme.ok : theme.dim) : theme.warn}>
          {n.mine ? "✓" : "✗"} {formatEth(hexToBigInt(n.denominationWei))} · {n.mine ? n.status : "not yours"} · index {String(n.depositIndex)}
        </Text>
      ))}
    </Box>
  );
}
