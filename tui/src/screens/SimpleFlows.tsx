import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import Select from "../widgets/Select.js";
import { Wallet } from "../types.js";
import { Layout } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";
import { formatEth, hexToBigInt } from "../format.js";

/** Lock or unlock an EOA. Called from the action picker; we infer which
 *  direction based on `wallet.unlocked`. */
export function LockToggleFlow({
  wallet,
  onDone,
}: {
  wallet: Wallet;
  onDone: (success: boolean) => void;
}) {
  const [pass, setPass] = useState<string | null>(null);

  if (wallet.kind !== "eoa") {
    return (
      <Layout title="Not applicable" hint="enter • back · esc • back">
        <Text color={theme.warn}>TPM/R1 wallets aren't lock/unlock-gated.</Text>
      </Layout>
    );
  }

  if (wallet.unlocked) {
    return (
      <RpcRunner
        title={`Lock ${wallet.name}`}
        method="eoa.lock"
        params={{ name: wallet.name }}
        renderResult={() => <Text color={theme.ok}>locked</Text>}
        onDone={onDone}
      />
    );
  }

  if (!pass) {
    const fields: Field[] = [
      {
        name: "passphrase",
        label: `Passphrase for ${wallet.name}`,
        secret: true,
        validate: (v) => (v.length === 0 ? "required" : null),
      },
    ];
    return (
      <Layout title={`Unlock ${wallet.name}`}>
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) => setPass(v.passphrase ?? "")}
        />
      </Layout>
    );
  }

  return (
    <RpcRunner
      title={`Unlocking ${wallet.name}…`}
      method="eoa.unlock"
      params={{ name: wallet.name, passphrase: pass }}
      renderResult={() => <Text color={theme.ok}>unlocked</Text>}
      onDone={onDone}
    />
  );
}

/** Resolve an ENS name → address. */
export function ResolveFlow({ onDone }: { onDone: (s: boolean) => void }) {
  const [name, setName] = useState<string | null>(null);
  if (!name) {
    return (
      <Layout title="Resolve ENS name">
        <Form
          fields={[
            {
              name: "ens",
              label: "ENS name",
              placeholder: "vitalik.eth",
              validate: (v) =>
                v.length === 0 ? "required" : v.includes(".") ? null : "expected dotted name",
            },
          ]}
          onCancel={() => onDone(false)}
          onSubmit={(v) => setName(v.ens ?? null)}
        />
      </Layout>
    );
  }
  return (
    <RpcRunner
      title={`Resolving ${name}…`}
      method="chain.resolveName"
      params={{ name }}
      renderResult={(r: any) => (
        <>
          <Text>address: {r?.address ?? "(none)"}</Text>
          <Text color={theme.dim}>chainId: {r?.chainId ?? "?"}</Text>
        </>
      )}
      onDone={onDone}
    />
  );
}

/** Daemon ping + version. */
export function DaemonScreen({ onDone }: { onDone: (s: boolean) => void }) {
  return (
    <RpcRunner
      title="Daemon status"
      method="daemon.version"
      params={[]}
      renderResult={(r: any) => (
        <>
          <Text color={theme.ok}>✓ daemon reachable</Text>
          <Text color={theme.dim}>{JSON.stringify(r, null, 2)}</Text>
        </>
      )}
      onDone={onDone}
    />
  );
}

/** Wallet show — passes the result through as JSON for now. */
export function DetailsScreen({
  wallet,
  onDone,
}: {
  wallet: Wallet;
  onDone: (s: boolean) => void;
}) {
  return (
    <RpcRunner
      title={`Details: ${wallet.name}`}
      method={wallet.kind === "eoa" ? "eoa.show" : "tpm.listSepolia"}
      params={wallet.kind === "eoa" ? { name: wallet.name } : []}
      onDone={onDone}
    />
  );
}

/** Local TxJournal history for the wallet (chain.history takes `name`). */
export function HistoryScreen({
  wallet,
  onDone,
}: {
  wallet: Wallet;
  onDone: (s: boolean) => void;
}) {
  return (
    <RpcRunner
      title={`History: ${wallet.name}`}
      subtitle="local journal entries (most recent last)"
      method="chain.history"
      params={{ name: wallet.name, limit: 20 }}
      renderResult={(r: any) => <HistoryRows rows={Array.isArray(r) ? r : []} />}
      onDone={onDone}
    />
  );
}

function HistoryRows({ rows }: { rows: any[] }) {
  if (rows.length === 0) {
    return <Text color={theme.dim}>no journal entries yet</Text>;
  }
  // Each row is its own <Box> — that forces a new flex row, so when the
  // terminal is narrow the wrap stays *within* one entry instead of
  // weaving columns from neighbouring entries together.
  return (
    <Box flexDirection="column">
      {rows.map((e, i) => (
        <HistoryRow key={i} entry={e} />
      ))}
    </Box>
  );
}

function HistoryRow({ entry }: { entry: any }) {
  const status: string = entry?.status ?? "?";
  const kind: string = entry?.kind ?? "?";
  const txHash: string = entry?.txHash ?? "";
  const to: string = entry?.to ?? "";
  const valueWei = (() => {
    try {
      const raw = entry?.valueWei;
      return raw === undefined || raw === null ? 0n : BigInt(raw);
    } catch {
      return 0n;
    }
  })();

  const glyph = status === "success" ? "✓" : status === "revert" ? "✗" : "·";
  const glyphColor =
    status === "success" ? theme.ok : status === "revert" ? theme.err : theme.warn;
  const valueText = valueWei > 0n ? formatEth(valueWei) : "—";

  // Two lines per entry with full untruncated addresses + txHashes:
  //   line 1 — semantic glyph, kind (accent), value (bold)
  //   line 2 — "to" + tx, dim, indented so it visually groups under L1
  // Each line is its own <Box> so flex layout treats them as separate
  // rows; if the terminal is narrow line 2 wraps cleanly within the entry.
  return (
    <Box flexDirection="column" marginBottom={1}>
      <Box>
        <Text color={glyphColor} bold>
          {glyph}
        </Text>
        <Text> </Text>
        <Text color={theme.accent}>{kind}</Text>
        {valueWei > 0n && (
          <>
            <Text>{"  "}</Text>
            <Text bold color={theme.primary}>
              {valueText}
            </Text>
          </>
        )}
      </Box>
      {to && (
        <Box>
          <Text color={theme.dim}>{"  to "}</Text>
          <Text>{to}</Text>
        </Box>
      )}
      {txHash && (
        <Box>
          <Text color={theme.dim}>{"  tx "}</Text>
          <Text color={theme.dim}>{txHash}</Text>
        </Box>
      )}
    </Box>
  );
}

/** chain.balance — re-renders the daemon's view of the wallet's balance.
 *  Daemon returns hex wei; we convert to a human-readable ETH amount so
 *  the user doesn't have to read `0x16345785d8a0000`. TPM slots query
 *  sepolia explicitly because they have no mainnet signing path. */
export function BalanceRefreshScreen({
  wallet,
  onDone,
}: {
  wallet: Wallet;
  onDone: (s: boolean) => void;
}) {
  const params: { address: string; chain?: string } = { address: wallet.address };
  if (wallet.kind === "tpm") params.chain = "sepolia";
  return (
    <RpcRunner
      title={`Balance: ${wallet.name}`}
      method="chain.balance"
      params={params}
      renderResult={(r: any) => {
        const wei = hexToBigInt(r?.balance);
        const chainLabel: string = r?.chain ?? (wallet.kind === "tpm" ? "sepolia" : "mainnet");
        const block: string = r?.block ?? "latest";
        return (
          <Box flexDirection="column">
            <Box>
              <Text bold color={theme.primary}>
                {formatEth(wei)}
              </Text>
              <Text color={theme.dim}>{`  on ${chainLabel} @ ${block}`}</Text>
            </Box>
            <Text color={theme.dim}>
              {wallet.address}  ·  raw {r?.balance ?? "0x0"}
            </Text>
          </Box>
        );
      }}
      onDone={onDone}
    />
  );
}

/** A static "more commands" screen with a hint that these are CLI-only
 *  for now. Honest about scope. */
export type MoreAction =
  | "resolve"
  | "decode-intent"
  | "decode-typed-data"
  | "llm-draft"
  | "archived-accounts"
  | "daemon"
  | "back";

export function MoreCommandsScreen({
  onDone,
  onPick,
}: {
  onDone: (s: boolean) => void;
  onPick: (a: MoreAction) => void;
}) {
  useInput((_, key) => {
    if (key.escape) onDone(false);
  });

  const items: { label: string; value: MoreAction }[] = [
    { label: "Ask the agent (NL → calldata draft)",           value: "llm-draft" },
    { label: "Decode transaction (ERC-7730)",                 value: "decode-intent" },
    { label: "Decode typed data (EIP-712)",                   value: "decode-typed-data" },
    { label: "Resolve ENS name",                              value: "resolve" },
    { label: "Archived accounts",                             value: "archived-accounts" },
    { label: "Daemon status",                                 value: "daemon" },
    { label: "← Back",                                         value: "back" },
  ];

  return (
    <Layout
      title="More commands"
      subtitle="Less-frequent flows. Most CLI verbs still live in the shell — run `kohaku help`."
      hint="↑/↓ move · → / enter select · ← / esc back"
    >
      <Select
        items={items}
        arrowNav
        onBack={() => onDone(false)}
        onSelect={(it: { value: MoreAction }) =>
          it.value === "back" ? onDone(false) : onPick(it.value)
        }
      />
      <Text color={theme.dim}>
        Not yet ported into the TUI: wallet derive · sign-digest · sign-message
        · sign-tx · sign-typed-data · account add/list/rm · chain estimate-gas ·
        chain broadcast · chain token-balance · network show/set-rpc/set-policy
        · daemon stop · debug *
      </Text>
    </Layout>
  );
}

