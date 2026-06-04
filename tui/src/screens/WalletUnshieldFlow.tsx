import React, { useEffect, useState } from "react";
import { Box, Text } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import Select from "../widgets/Select.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";
import { Wallet } from "../types.js";
import UnlockEoaStep from "./UnlockEoaStep.js";

type Protocol = "pp" | "railgun";
type RecipientSource = "derive" | "book" | "paste";

type BookEntry = {
  label: string;
  address: string;
  source: string;
  ensName?: string | null;
  tag?: string | null;
};

type AccountListEntry = { index: number; path: string; address: string; label?: string | null };

type Phase =
  | { kind: "pickProtocol" }
  | { kind: "pickSource"; protocol: Protocol }
  /* paste path */
  | { kind: "paste"; protocol: Protocol }
  /* book path */
  | { kind: "book-loading"; protocol: Protocol }
  | { kind: "book-empty"; protocol: Protocol }
  | { kind: "book-pick"; protocol: Protocol; entries: BookEntry[] }
  /* derive-on-this-wallet path */
  | { kind: "derive-prep"; protocol: Protocol }
  | { kind: "derive-running"; nextIdx: number; protocol: Protocol; label?: string }
  | { kind: "derive-form"; nextIdx: number; protocol: Protocol }
  | { kind: "derive-error"; message: string; protocol: Protocol }
  /* amount entry (post-recipient) */
  | {
      kind: "amount";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
    }
  /* Railgun: EOA unlock between amount and broadcast */
  | {
      kind: "unlock";
      protocol: "railgun";
      recipient: string;
      source: RecipientSource;
      amountEth: string;
    }
  /* dispatch */
  | {
      kind: "running";
      protocol: Protocol;
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase?: string;
    };

type Props = {
  wallet: Wallet;
  onDone: (success: boolean) => void;
};

const HARDENED_MATCH = /^m\/44'\/60'\/(\d+)'\/\d+\/\d+$/;
function parseHardenedAccount(path: string): number | null {
  const m = path.match(HARDENED_MATCH);
  if (!m || !m[1]) return null;
  return parseInt(m[1], 10);
}
function nextHardenedAccount(paths: string[]): number {
  let max = -1;
  for (const p of paths) {
    const n = parseHardenedAccount(p);
    if (n !== null && n > max) max = n;
  }
  const next = max + 1;
  // Skip m/44'/60'/0'/0/0 — that's the implicit primary.
  return next === 0 ? 1 : next;
}

/** Unshield from the wallet action menu. Mirrors ShieldFlow's protocol-
 *  picker shape but for the reverse direction.
 *
 *  Flow:
 *    1. pick protocol  — Privacy Pools v1  /  Railgun
 *    2. pick recipient source:
 *       a) derive a fresh sub-account on THIS wallet (no 0-link)
 *       b) pick from address book (book.list)
 *       c) type / paste an address
 *    3. enter amount (and PP passphrase, if protocol=pp)
 *    4. for Railgun: unlock the EOA so the daemon can sign the 4337
 *       UserOp's 7702 authorization + fee note for the delegator;
 *       PP doesn't need the EOA at all (relayer broadcasts).
 *    5. dispatch — shielded.unshieldDrain (PP) or shielded.railgun.unshield. */
export default function WalletUnshieldFlow({ wallet, onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "pickProtocol" });

  /* book-loading → book.list once */
  useEffect(() => {
    if (phase.kind !== "book-loading") return;
    let cancelled = false;
    (async () => {
      const r = await call<{ entries: BookEntry[] }>("book.list");
      if (cancelled) return;
      if (!r.ok) {
        setPhase({ kind: "book-empty", protocol: phase.protocol });
        return;
      }
      const entries = r.result?.entries ?? [];
      if (entries.length === 0) {
        setPhase({ kind: "book-empty", protocol: phase.protocol });
      } else {
        setPhase({ kind: "book-pick", protocol: phase.protocol, entries });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  /* derive-prep → fetch existing accounts so we know the next index */
  useEffect(() => {
    if (phase.kind !== "derive-prep") return;
    let cancelled = false;
    (async () => {
      const r = await call<{ accounts: AccountListEntry[] }>(
        "eoa.account.list",
        { name: wallet.name },
      );
      if (cancelled) return;
      const existing = r.ok ? r.result?.accounts ?? [] : [];
      const nextIdx = nextHardenedAccount(existing.map((a) => a.path ?? ""));
      // The form just collects an optional label; the path is derived
      // from `nextIdx`. Carry the protocol forward from derive-prep so
      // the eventual unshield dispatch hits the right RPC.
      setPhase((prev) =>
        prev.kind === "derive-prep"
          ? { kind: "derive-form", nextIdx, protocol: prev.protocol }
          : prev,
      );
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind, wallet.name]);

  if (wallet.kind !== "eoa") {
    return (
      <Layout title="Unshield" hint="enter / esc — back">
        <Banner kind="err" text="Unshield only supports EOA wallets today (the delegating signer for Railgun's 4337 UserOp is an EOA private key)." />
      </Layout>
    );
  }

  /* ─── pickProtocol ─── */
  if (phase.kind === "pickProtocol") {
    return (
      <Layout
        title={`Unshield from ${wallet.name}`}
        subtitle="pick the source pool"
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={[
            { label: "Privacy Pools v1 — Sepolia · relayer-broadcast", value: "pp" as Protocol },
            { label: "Railgun — Sepolia · 4337 + 7702 broadcast", value: "railgun" as Protocol },
          ]}
          arrowNav
          onBack={() => onDone(false)}
          onSelect={(it) => setPhase({ kind: "pickSource", protocol: it.value })}
        />
      </Layout>
    );
  }

  /* ─── pickSource ─── */
  if (phase.kind === "pickSource") {
    const protocol = phase.protocol;
    return (
      <Layout
        title={`Unshield → recipient`}
        subtitle={`protocol: ${protocol === "pp" ? "Privacy Pools" : "Railgun"}`}
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={[
            {
              label: "Derive a fresh sub-account on this wallet (recommended — no on-chain link)",
              value: "derive" as RecipientSource,
            },
            {
              label: "Pick from address book",
              value: "book" as RecipientSource,
            },
            {
              label: "Type / paste an address",
              value: "paste" as RecipientSource,
            },
          ]}
          arrowNav
          onBack={() => setPhase({ kind: "pickProtocol" })}
          onSelect={(it) => {
            if (it.value === "derive") setPhase({ kind: "derive-prep", protocol });
            else if (it.value === "book") setPhase({ kind: "book-loading", protocol });
            else setPhase({ kind: "paste", protocol });
          }}
        />
        <Box marginTop={1}>
          <Text color={theme.dim}>
            {protocol === "pp"
              ? "Privacy Pools relayer broadcasts; no EOA unlock needed here."
              : "Railgun broadcast is signed by this wallet's EOA via EIP-7702 — you'll be asked to unlock it before sending."}
          </Text>
        </Box>
      </Layout>
    );
  }

  /* ─── paste ─── */
  if (phase.kind === "paste") {
    const protocol = phase.protocol;
    return (
      <Layout title="Unshield → paste recipient">
        <Form
          fields={[
            {
              name: "recipient",
              label: "Recipient address (0x…)",
              validate: (v) =>
                v.startsWith("0x") && v.length === 42 ? null : "expected 0x… 20-byte address",
            },
          ]}
          onCancel={() => setPhase({ kind: "pickSource", protocol })}
          onSubmit={(v) =>
            setPhase({
              kind: "amount",
              protocol,
              recipient: v.recipient ?? "",
              source: "paste",
            })
          }
        />
      </Layout>
    );
  }

  /* ─── book ─── */
  if (phase.kind === "book-loading") {
    return (
      <Layout title="Unshield → loading address book">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>fetching saved entries…</Text>
        </Text>
      </Layout>
    );
  }
  if (phase.kind === "book-empty") {
    return (
      <Layout
        title="Unshield → address book"
        subtitle="no saved entries"
        hint="esc — back"
      >
        <Banner
          kind="warn"
          text="address book is empty — add entries via `leancli book add <label> <addr>` first."
        />
        <Box marginTop={1}>
          <Select
            items={[{ label: "← Back", value: "back" }]}
            onSelect={() => setPhase({ kind: "pickSource", protocol: phase.protocol })}
          />
        </Box>
      </Layout>
    );
  }
  if (phase.kind === "book-pick") {
    const protocol = phase.protocol;
    return (
      <Layout
        title="Unshield → pick from address book"
        hint="↑/↓ pick · enter confirm · esc back"
      >
        <Select
          items={phase.entries.map((e) => {
            const tag = e.tag ? `  [${e.tag}]` : "";
            const ens = e.ensName ? `  (${e.ensName})` : "";
            return {
              label: `${e.label.padEnd(18)} ${e.address}${ens}${tag}`,
              value: e.address,
            };
          })}
          arrowNav
          onBack={() => setPhase({ kind: "pickSource", protocol })}
          onSelect={(it) =>
            setPhase({
              kind: "amount",
              protocol,
              recipient: it.value,
              source: "book",
            })
          }
        />
      </Layout>
    );
  }

  /* ─── derive (prep → form → run) ─── */
  if (phase.kind === "derive-prep") {
    return (
      <Layout title={`Unshield → derive on ${wallet.name}`}>
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>scanning sub-accounts for next free index…</Text>
        </Text>
      </Layout>
    );
  }
  if (phase.kind === "derive-form") {
    const path = `m/44'/60'/${phase.nextIdx}'/0/0`;
    const protocol = phase.protocol;
    const fields: Field[] = [
      {
        name: "label",
        label: "Label (optional)",
        placeholder: "unshield-1, fresh-a, …",
      },
    ];
    return (
      <Layout
        title={`Unshield → derive on ${wallet.name}`}
        subtitle={`derivation: ${path}  (BIP-32 hardened)`}
        hint="enter — derive · esc — back"
      >
        <Form
          fields={fields}
          onCancel={() => setPhase({ kind: "pickSource", protocol })}
          onSubmit={(v) => {
            const label = (v.label ?? "").trim();
            setPhase({
              kind: "derive-running",
              nextIdx: phase.nextIdx,
              protocol,
              label: label.length > 0 ? label : undefined,
            });
          }}
        />
      </Layout>
    );
  }
  if (phase.kind === "derive-running") {
    return (
      <DeriveAndAdvance
        walletName={wallet.name}
        nextIdx={phase.nextIdx}
        label={phase.label}
        onSuccess={(addr) =>
          setPhase({
            kind: "amount",
            protocol: phase.protocol,
            recipient: addr,
            source: "derive",
          })
        }
        onError={(message) =>
          setPhase({ kind: "derive-error", message, protocol: phase.protocol })
        }
      />
    );
  }
  if (phase.kind === "derive-error") {
    return (
      <Layout title="Unshield → derive failed" hint="esc — back">
        <Banner kind="err" text={phase.message} />
        <Box marginTop={1}>
          <Select
            items={[{ label: "← Back", value: "back" }]}
            onSelect={() => setPhase({ kind: "pickSource", protocol: phase.protocol })}
          />
        </Box>
      </Layout>
    );
  }

  /* ─── amount ─── */
  if (phase.kind === "amount") {
    const isRailgun = phase.protocol === "railgun";
    const fields: Field[] = [
      {
        name: "amountEth",
        label: "Amount (ETH)",
        placeholder: "0.005",
        validate: (v) =>
          /^[0-9]+(\.[0-9]+)?$/.test(v) ? null : "expected a decimal ETH amount",
      },
      ...(isRailgun
        ? []
        : [
            {
              name: "passphrase",
              label: "Privacy Pool passphrase",
              secret: true,
              validate: (v: string) => (v.length === 0 ? "required" : null),
            } satisfies Field,
          ]),
    ];
    return (
      <Layout
        title={`Unshield → ${isRailgun ? "Railgun" : "Privacy Pools"}`}
        subtitle={`recipient: ${phase.recipient}  (source: ${phase.source})`}
      >
        <Form
          fields={fields}
          onCancel={() => setPhase({ kind: "pickSource", protocol: phase.protocol })}
          onSubmit={(v) => {
            const amountEth = v.amountEth ?? "0";
            if (isRailgun) {
              setPhase({
                kind: "unlock",
                protocol: "railgun",
                recipient: phase.recipient,
                source: phase.source,
                amountEth,
              });
            } else {
              setPhase({
                kind: "running",
                protocol: "pp",
                recipient: phase.recipient,
                source: phase.source,
                amountEth,
                passphrase: v.passphrase ?? "",
              });
            }
          }}
        />
      </Layout>
    );
  }

  /* ─── Railgun-only unlock step ─── */
  if (phase.kind === "unlock") {
    return (
      <UnlockEoaStep
        wallet={wallet}
        onUnlocked={() =>
          setPhase({
            kind: "running",
            protocol: "railgun",
            recipient: phase.recipient,
            source: phase.source,
            amountEth: phase.amountEth,
          })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  /* ─── running ─── */
  if (phase.kind === "running") {
    const isRailgun = phase.protocol === "railgun";
    const method = isRailgun ? "shielded.railgun.unshield" : "shielded.unshieldDrain";
    const params: Record<string, string> = {
      recipient: phase.recipient,
      amountEth: phase.amountEth,
    };
    if (isRailgun) {
      // Railgun's daemon-side handler reads the named wallet's slot
      // for the delegating EOA + the BIP-39 seed (Railgun keystore is
      // rooted at the EOA's seed since the seed-keystore change).
      params.name = wallet.name;
    } else if (phase.passphrase) {
      params.passphrase = phase.passphrase;
    }
    const subtitle = isRailgun
      ? "Railgun · Sepolia · 4337+7702"
      : "Privacy Pools v1 · Sepolia · relayer-broadcast";
    return (
      <RpcRunner
        title={`Unshielding ${phase.amountEth} ETH → ${phase.recipient}`}
        subtitle={subtitle}
        method={method}
        params={params}
        timeoutMs={20 * 60 * 1000}
        renderResult={(r: any) => <Text>{JSON.stringify(r, null, 2)}</Text>}
        onDone={onDone}
      />
    );
  }

  return null;
}

/** Fire `eoa.account.add` and surface the new address inline. */
function DeriveAndAdvance({
  walletName,
  nextIdx,
  label,
  onSuccess,
  onError,
}: {
  walletName: string;
  nextIdx: number;
  label?: string;
  onSuccess: (address: string) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const path = `m/44'/60'/${nextIdx}'/0/0`;
      const params: Record<string, unknown> = { name: walletName, path };
      if (label) params.label = label;
      const r = await call<{ address?: string }>("eoa.account.add", params);
      if (cancelled) return;
      if (!r.ok) {
        onError(`daemon error ${r.error.code}: ${r.error.message}`);
        return;
      }
      const addr = r.result?.address;
      if (!addr) {
        onError("daemon returned no address");
        return;
      }
      onSuccess(addr);
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout
      title={`Deriving fresh sub-account on ${walletName}…`}
      subtitle={`derivation: m/44'/60'/${nextIdx}'/0/0`}
    >
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>asking the daemon to derive the new branch…</Text>
      </Text>
    </Layout>
  );
}
