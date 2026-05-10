import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import Select from "../widgets/Select.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";
import { EoaListEntry } from "../types.js";

type AccountListEntry = {
  index: number;
  path: string;
  address: string;
  label?: string | null;
};

type Phase =
  | { kind: "loading-wallets" }
  | { kind: "load-error"; message: string }
  | { kind: "no-wallets" }
  | { kind: "pick-wallet"; wallets: EoaListEntry[] }
  | { kind: "loading-accounts"; wallet: EoaListEntry }
  | { kind: "form"; wallet: EoaListEntry; nextIdx: number; existing: AccountListEntry[] }
  | {
      kind: "running";
      wallet: EoaListEntry;
      nextIdx: number;
      params: Record<string, unknown>;
    };

type Props = { onDone: (success: boolean) => void };

/** Parse the hardened "account" component out of a BIP-44 Ethereum path
 *  (`m/44'/60'/<N>'/<change>/<index>`). Returns null on any other shape
 *  so unrecognised paths are simply ignored when computing the next free
 *  hardened slot. */
function parseHardenedAccount(path: string): number | null {
  const m = path.match(/^m\/44'\/60'\/(\d+)'\/\d+\/\d+$/);
  if (!m || !m[1]) return null;
  return parseInt(m[1], 10);
}

/** Pick the next free hardened account number across the slot's existing
 *  paths. We deliberately walk the *hardened* axis (`m/44'/60'/N'/0/0`)
 *  rather than the soft index axis used by MetaMask (`m/44'/60'/0'/0/N`)
 *  so that publishing one account's xpub never reveals the siblings —
 *  hardened derivation cannot be reversed from a parent xpub. */
function nextHardenedAccount(paths: string[]): number {
  let max = -1;
  for (const p of paths) {
    const n = parseHardenedAccount(p);
    if (n !== null && n > max) max = n;
  }
  return max + 1;
}

/** Drives `eoa.account.add` against an explicit hardened-account path so
 *  every new sub-account on a given EOA slot lives on a fresh BIP-32
 *  hardened branch. UX: pick wallet → list its accounts (to compute the
 *  next free hardened number) → enter passphrase + optional label →
 *  daemon derives + persists → result banner. */
export default function AddAccountFlow({ onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "loading-wallets" });

  useEffect(() => {
    if (phase.kind !== "loading-wallets") return;
    let cancelled = false;
    (async () => {
      const r = await call<EoaListEntry[]>("eoa.list");
      if (cancelled) return;
      if (!r.ok) {
        setPhase({ kind: "load-error", message: r.error.message });
        return;
      }
      const ws = (r.result ?? []).filter((w) => w?.name && w?.address);
      if (ws.length === 0) setPhase({ kind: "no-wallets" });
      else setPhase({ kind: "pick-wallet", wallets: ws });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  useEffect(() => {
    if (phase.kind !== "loading-accounts") return;
    let cancelled = false;
    (async () => {
      const r = await call<{ accounts: AccountListEntry[] }>(
        "eoa.account.list",
        { name: phase.wallet.name },
      );
      if (cancelled) return;
      const existing = r.ok ? r.result?.accounts ?? [] : [];
      const nextIdx = nextHardenedAccount(existing.map((a) => a.path ?? ""));
      // First-ever sub-account: skip past the slot's primary at
      // m/44'/60'/0'/0/0 by jumping to 1' so we never collide with the
      // implicit primary account.
      const safeIdx = nextIdx === 0 ? 1 : nextIdx;
      setPhase({
        kind: "form",
        wallet: phase.wallet,
        nextIdx: safeIdx,
        existing,
      });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  useInput((input, key) => {
    // Esc always bails out (except while the daemon RPC is in flight).
    // `q` is treated as a back shortcut on menu/list phases only — when
    // the form phase is active a TextInput owns input focus and the user
    // is typing real characters, including the letter "q" for labels.
    if (phase.kind === "running") return;
    if (key.escape) {
      onDone(false);
      return;
    }
    if (phase.kind === "form") return;
    if (input === "q") onDone(false);
  });

  if (phase.kind === "loading-wallets") {
    return (
      <Layout title="Add account" hint="esc — back">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>loading EOA wallets…</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "load-error") {
    return (
      <Layout title="Add account" hint="esc — back">
        <Banner kind="err" text={phase.message} />
      </Layout>
    );
  }

  if (phase.kind === "no-wallets") {
    return (
      <Layout title="Add account" hint="esc — back">
        <Banner
          kind="warn"
          text="no EOA wallet configured — create one first via 'Create wallet'."
        />
      </Layout>
    );
  }

  if (phase.kind === "pick-wallet") {
    return (
      <Layout
        title="Add account"
        subtitle="pick the EOA to derive a new sub-account from"
        hint="↑/↓ pick · enter confirm · esc back"
      >
        <Select
          items={phase.wallets.map((w) => ({
            label: `${w.name.padEnd(18)} ${w.address}${
              w.unlocked === false ? " [locked]" : ""
            }`,
            value: w.name,
          }))}
          onSelect={(it) => {
            const w = phase.wallets.find((x) => x.name === it.value);
            if (w) setPhase({ kind: "loading-accounts", wallet: w });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "loading-accounts") {
    return (
      <Layout title="Add account" hint="esc — back">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>
            scanning {phase.wallet.name} for the next free hardened branch…
          </Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "form") {
    const path = `m/44'/60'/${phase.nextIdx}'/0/0`;
    const fields: Field[] = [
      {
        name: "label",
        label: "Label (optional)",
        placeholder: "savings, hot, ops, …",
      },
      {
        name: "passphrase",
        label: `Passphrase for ${phase.wallet.name}`,
        secret: true,
        validate: (v) => (v.length === 0 ? "required" : null),
      },
    ];
    return (
      <Layout
        title={`Add account on ${phase.wallet.name}`}
        subtitle={`derivation: ${path}  (BIP-32 hardened — xpub does not leak siblings)`}
        hint="enter — derive · esc — cancel"
      >
        <Box flexDirection="column" marginBottom={1}>
          <Text color={theme.dim}>existing accounts on this slot:</Text>
          {phase.existing.length === 0 ? (
            <Text color={theme.dim}>  (only the primary at m/44'/60'/0'/0/0)</Text>
          ) : (
            phase.existing.map((a) => (
              <Text key={a.index} color={theme.dim}>
                {`  #${a.index}  ${a.path}  ${a.address}${a.label ? `  (${a.label})` : ""}`}
              </Text>
            ))
          )}
        </Box>
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) => {
            const params: Record<string, unknown> = {
              name: phase.wallet.name,
              passphrase: v.passphrase ?? "",
              path,
            };
            const label = (v.label ?? "").trim();
            if (label.length > 0) params.label = label;
            setPhase({
              kind: "running",
              wallet: phase.wallet,
              nextIdx: phase.nextIdx,
              params,
            });
          }}
        />
      </Layout>
    );
  }

  // running
  return (
    <RpcRunner
      title={`Adding account on ${phase.wallet.name}…`}
      subtitle={`derivation: m/44'/60'/${phase.nextIdx}'/0/0`}
      method="eoa.account.add"
      params={phase.params}
      renderResult={(r: any) => (
        <Box flexDirection="column">
          <Banner kind="ok" text="account derived" />
          <Box marginTop={1} flexDirection="column">
            <Text>
              <Text color={theme.dim}>address  </Text>
              <Text>{r?.address ?? "?"}</Text>
            </Text>
            <Text>
              <Text color={theme.dim}>path     </Text>
              <Text>{r?.path ?? "?"}</Text>
            </Text>
            <Text>
              <Text color={theme.dim}>index    </Text>
              <Text>{r?.index ?? "?"}</Text>
            </Text>
            {r?.label && (
              <Text>
                <Text color={theme.dim}>label    </Text>
                <Text>{r.label}</Text>
              </Text>
            )}
          </Box>
        </Box>
      )}
      onDone={onDone}
    />
  );
}
