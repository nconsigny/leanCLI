import React, { useEffect, useState } from "react";
import { Box, Text } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import Select from "../widgets/Select.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { theme } from "../theme.js";
import { AddressFreshness, ChainBalance, EoaListEntry } from "../types.js";
import { hexToBigInt } from "../format.js";
import UnlockEoaStep from "./UnlockEoaStep.js";

type AccountListEntry = {
  index: number;
  path: string;
  address: string;
  label?: string | null;
};

type RecipientSource = "paste" | "derive" | "existing";

type Phase =
  | { kind: "pick-source" }
  /* paste-address path: just a recipient text input */
  | { kind: "paste-recipient" }
  /* derive-a-new-sub-account path */
  | { kind: "derive-loading-wallets" }
  | { kind: "derive-no-wallets" }
  | { kind: "derive-pick-wallet"; wallets: EoaListEntry[] }
  | { kind: "derive-form"; wallet: EoaListEntry; nextIdx: number }
  | {
      kind: "derive-unlock";
      wallet: EoaListEntry;
      nextIdx: number;
      params: Record<string, unknown>;
    }
  | {
      kind: "derive-running";
      wallet: EoaListEntry;
      nextIdx: number;
      params: Record<string, unknown>;
    }
  | { kind: "derive-error"; message: string }
  /* existing-sub-account path */
  | { kind: "existing-loading-wallets" }
  | { kind: "existing-no-wallets" }
  | { kind: "existing-pick-wallet"; wallets: EoaListEntry[] }
  | { kind: "existing-loading-accounts"; wallet: EoaListEntry }
  | {
      kind: "existing-pick-account";
      wallet: EoaListEntry;
      accounts: AccountListEntry[];
      /** Per-address final 0-link verdict. `null` = still probing,
       *  `true` = nonce=0 AND ERC-20-clean AND (balance=0 OR ppFunded). */
      zeroLink: Record<string, boolean | null>;
    }
  /* recipient resolved → collect amount + privacy-pool passphrase */
  | { kind: "amount-passphrase"; recipient: string; source: RecipientSource }
  /* dispatch shielded.unshieldDrain */
  | {
      kind: "running";
      recipient: string;
      source: RecipientSource;
      amountEth: string;
      passphrase: string;
    };

type Props = { onDone: (success: boolean) => void };

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
  // First-ever sub-account: skip m/44'/60'/0'/0/0 (the implicit primary).
  return next === 0 ? 1 : next;
}

/** Multi-step unshield: pick recipient source (paste / derive new sub-
 *  account / pick existing sub-account) → resolve recipient address →
 *  amount + Privacy-Pool passphrase → dispatch shielded.unshieldDrain.
 *
 *  Why three sources: the canonical "rotate" workflow says the unshield
 *  destination should be FRESH (no on-chain link). Pasting an arbitrary
 *  recipient is preserved for power users; "derive new" and "pick
 *  existing" let the user choose a destination they already own without
 *  leaving the unshield flow. */
export default function UnshieldFlow({ onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "pick-source" });

  /* derive-loading-wallets → load EOAs once */
  useEffect(() => {
    if (phase.kind !== "derive-loading-wallets") return;
    let cancelled = false;
    (async () => {
      const r = await call<EoaListEntry[]>("eoa.list");
      if (cancelled) return;
      if (!r.ok) {
        setPhase({ kind: "derive-no-wallets" });
        return;
      }
      const ws = (r.result ?? []).filter((w) => w?.name && w?.address);
      if (ws.length === 0) setPhase({ kind: "derive-no-wallets" });
      else setPhase({ kind: "derive-pick-wallet", wallets: ws });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  /* existing-loading-wallets → mirror of the derive loader */
  useEffect(() => {
    if (phase.kind !== "existing-loading-wallets") return;
    let cancelled = false;
    (async () => {
      const r = await call<EoaListEntry[]>("eoa.list");
      if (cancelled) return;
      if (!r.ok) {
        setPhase({ kind: "existing-no-wallets" });
        return;
      }
      const ws = (r.result ?? []).filter((w) => w?.name && w?.address);
      if (ws.length === 0) setPhase({ kind: "existing-no-wallets" });
      else setPhase({ kind: "existing-pick-wallet", wallets: ws });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  /* existing-loading-accounts → fetch the slot's accounts AND a quick
   *  freshness probe per account, so 0-link picks paint green. */
  useEffect(() => {
    if (phase.kind !== "existing-loading-accounts") return;
    const slot = phase.wallet;
    let cancelled = false;
    (async () => {
      const r = await call<{ accounts: AccountListEntry[] }>(
        "eoa.account.list",
        { name: slot.name },
      );
      if (cancelled) return;
      // The primary at index 0 isn't always in the array — synthesize it
      // from the slot record so the user can pick it too.
      const fromRpc = r.ok ? r.result?.accounts ?? [] : [];
      const hasPrimary = fromRpc.some((a) => a.index === 0);
      const accounts: AccountListEntry[] = hasPrimary
        ? fromRpc
        : [
            {
              index: 0,
              path: "m/44'/60'/0'/0/0",
              address: slot.address,
              label: null,
            },
            ...fromRpc,
          ];
      // Seed zeroLink=null (still probing) for every row, then probe
      // both balance + freshness sequentially. The combined rule is:
      // nonce=0 AND ERC-20-clean AND (balance=0 OR ppFunded).
      const init: Record<string, boolean | null> = {};
      for (const a of accounts) init[a.address.toLowerCase()] = null;
      setPhase({
        kind: "existing-pick-account",
        wallet: slot,
        accounts,
        zeroLink: init,
      });
      for (const a of accounts) {
        if (cancelled) return;
        const balRes = await call<ChainBalance>("chain.balance", {
          address: a.address,
        });
        if (cancelled) return;
        const fr = await call<AddressFreshness>("chain.addressFreshness", {
          address: a.address,
        });
        if (cancelled) return;
        let zero = false;
        if (fr.ok && fr.result && fr.result.available === true) {
          const d = fr.result;
          const nonceZero = d.nonce === 0;
          const erc20Clean =
            (d.erc20OutCount ?? 0) === 0 && (d.erc20InCount ?? 0) === 0;
          const ppFunded = d.ppFunded === true;
          const balanceZero =
            balRes.ok && hexToBigInt(balRes.result?.balance) === 0n;
          zero = nonceZero && erc20Clean && (balanceZero || ppFunded);
        }
        setPhase((prev) =>
          prev.kind === "existing-pick-account"
            ? {
                ...prev,
                zeroLink: {
                  ...prev.zeroLink,
                  [a.address.toLowerCase()]: zero,
                },
              }
            : prev,
        );
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  /* ─── pick-source ─── */
  if (phase.kind === "pick-source") {
    return (
      <Layout
        title="Unshield via relayer"
        subtitle="pick where the unshielded ETH should land"
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={[
            {
              label:
                "Derive a NEW sub-account from one of my BIP-39 wallets  (recommended — fresh, 0-link)",
              value: "derive" as RecipientSource,
            },
            {
              label:
                "Pick an EXISTING sub-account from one of my BIP-39 wallets",
              value: "existing" as RecipientSource,
            },
            {
              label: "Paste an arbitrary recipient address",
              value: "paste" as RecipientSource,
            },
          ]}
          onSelect={(it) => {
            if (it.value === "derive")
              setPhase({ kind: "derive-loading-wallets" });
            else if (it.value === "existing")
              setPhase({ kind: "existing-loading-wallets" });
            else setPhase({ kind: "paste-recipient" });
          }}
        />
      </Layout>
    );
  }

  /* ─── paste-recipient ─── */
  if (phase.kind === "paste-recipient") {
    return (
      <Layout title="Unshield via relayer — paste recipient">
        <Form
          fields={[
            {
              name: "recipient",
              label: "Recipient address",
              validate: (v) =>
                v.startsWith("0x") && v.length === 42
                  ? null
                  : "expected 0x… 20-byte address",
            },
          ]}
          onCancel={() => setPhase({ kind: "pick-source" })}
          onSubmit={(v) =>
            setPhase({
              kind: "amount-passphrase",
              recipient: v.recipient ?? "",
              source: "paste",
            })
          }
        />
      </Layout>
    );
  }

  /* ─── derive — loading ─── */
  if (phase.kind === "derive-loading-wallets") {
    return (
      <Layout title="Unshield via relayer — derive new sub-account">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>loading BIP-39 wallets…</Text>
        </Text>
      </Layout>
    );
  }
  if (phase.kind === "derive-no-wallets") {
    return (
      <Layout
        title="Unshield via relayer — derive new sub-account"
        hint="esc — back"
      >
        <Banner
          kind="warn"
          text="no EOA wallet configured — create one first via the main menu, then return here."
        />
      </Layout>
    );
  }
  if (phase.kind === "derive-pick-wallet") {
    return (
      <Layout
        title="Unshield via relayer — derive new sub-account"
        subtitle="pick the BIP-39 EOA to derive a fresh hardened branch from"
        hint="↑/↓ pick · enter confirm · esc back"
      >
        <Select
          items={phase.wallets.map((w) => ({
            label: `${w.name.padEnd(18)} ${w.address}${
              w.unlocked === false ? " [locked]" : ""
            }`,
            value: w.name,
          }))}
          onSelect={async (it) => {
            const slot = phase.wallets.find((x) => x.name === it.value);
            if (!slot) return;
            const r = await call<{ accounts: AccountListEntry[] }>(
              "eoa.account.list",
              { name: slot.name },
            );
            const existing = r.ok ? r.result?.accounts ?? [] : [];
            const nextIdx = nextHardenedAccount(
              existing.map((a) => a.path ?? ""),
            );
            setPhase({ kind: "derive-form", wallet: slot, nextIdx });
          }}
        />
      </Layout>
    );
  }
  if (phase.kind === "derive-form") {
    const path = `m/44'/60'/${phase.nextIdx}'/0/0`;
    // EOA passphrase is no longer captured here — UnlockEoaStep below
    // picks the right path before we fire eoa.account.add (which
    // requires the slot to be unlocked but does NOT read a passphrase
    // param itself).
    const fields: Field[] = [
      {
        name: "label",
        label: "Label (optional)",
        placeholder: "unshield-1, fresh-a, …",
      },
    ];
    return (
      <Layout
        title={`Unshield — derive on ${phase.wallet.name}`}
        subtitle={`derivation: ${path}  (BIP-32 hardened — xpub does not leak siblings)`}
        hint="enter — derive · esc — back to source picker"
      >
        <Form
          fields={fields}
          onCancel={() => setPhase({ kind: "pick-source" })}
          onSubmit={(v) => {
            const params: Record<string, unknown> = {
              name: phase.wallet.name,
              path,
            };
            const label = (v.label ?? "").trim();
            if (label.length > 0) params.label = label;
            setPhase({
              kind: "derive-unlock",
              wallet: phase.wallet,
              nextIdx: phase.nextIdx,
              params,
            });
          }}
        />
      </Layout>
    );
  }
  if (phase.kind === "derive-unlock") {
    return (
      <UnlockEoaStep
        wallet={{ name: phase.wallet.name, address: phase.wallet.address }}
        onUnlocked={() =>
          setPhase({
            kind: "derive-running",
            wallet: phase.wallet,
            nextIdx: phase.nextIdx,
            params: phase.params,
          })
        }
        onCancel={() => setPhase({ kind: "pick-source" })}
      />
    );
  }
  if (phase.kind === "derive-running") {
    return (
      <DeriveAndAdvance
        wallet={phase.wallet}
        nextIdx={phase.nextIdx}
        params={phase.params}
        onSuccess={(addr) =>
          setPhase({
            kind: "amount-passphrase",
            recipient: addr,
            source: "derive",
          })
        }
        onError={(message) => setPhase({ kind: "derive-error", message })}
      />
    );
  }
  if (phase.kind === "derive-error") {
    return (
      <Layout
        title="Unshield via relayer — derive failed"
        hint="esc — back to source picker"
      >
        <Banner kind="err" text={phase.message} />
        <Box marginTop={1}>
          <Select
            items={[{ label: "← Back", value: "back" }]}
            onSelect={() => setPhase({ kind: "pick-source" })}
          />
        </Box>
      </Layout>
    );
  }

  /* ─── existing-sub-account ─── */
  if (phase.kind === "existing-loading-wallets") {
    return (
      <Layout title="Unshield via relayer — pick existing sub-account">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>loading BIP-39 wallets…</Text>
        </Text>
      </Layout>
    );
  }
  if (phase.kind === "existing-no-wallets") {
    return (
      <Layout
        title="Unshield via relayer — pick existing sub-account"
        hint="esc — back"
      >
        <Banner
          kind="warn"
          text="no EOA wallet configured — create one first via the main menu, then return here."
        />
      </Layout>
    );
  }
  if (phase.kind === "existing-pick-wallet") {
    return (
      <Layout
        title="Unshield via relayer — pick existing sub-account"
        subtitle="pick the BIP-39 EOA whose accounts to choose from"
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
            const slot = phase.wallets.find((x) => x.name === it.value);
            if (slot)
              setPhase({ kind: "existing-loading-accounts", wallet: slot });
          }}
        />
      </Layout>
    );
  }
  if (phase.kind === "existing-loading-accounts") {
    return (
      <Layout
        title={`Unshield via relayer — accounts on ${phase.wallet.name}`}
      >
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>scanning sub-accounts…</Text>
        </Text>
      </Layout>
    );
  }
  if (phase.kind === "existing-pick-account") {
    // 0-link accounts are listed first (green); others follow.
    const annotated = phase.accounts.map((a) => ({
      a,
      zero: phase.zeroLink[a.address.toLowerCase()] === true,
      loading: phase.zeroLink[a.address.toLowerCase()] === null,
    }));
    annotated.sort((x, y) => {
      const xs = x.zero ? 0 : x.loading ? 1 : 2;
      const ys = y.zero ? 0 : y.loading ? 1 : 2;
      if (xs !== ys) return xs - ys;
      return x.a.index - y.a.index;
    });
    return (
      <Layout
        title={`Unshield via relayer — accounts on ${phase.wallet.name}`}
        subtitle="0-link rows are green — pick one to receive the unshielded ETH"
        hint="↑/↓ pick · enter confirm · esc back"
      >
        <Select
          items={annotated.map(({ a, zero, loading }) => {
            const tag = a.index === 0 ? "primary" : `#${a.index}`;
            const lbl = a.label ? `  (${a.label})` : "";
            const linkTag = zero ? "  0-link" : loading ? "  …" : "";
            const prefix = zero ? "\x02" : "";
            return {
              label: `${prefix}${tag.padEnd(8)} ${a.address}${lbl}${linkTag}`,
              value: a.address,
            };
          })}
          onSelect={(it) =>
            setPhase({
              kind: "amount-passphrase",
              recipient: it.value,
              source: "existing",
            })
          }
        />
      </Layout>
    );
  }

  /* ─── amount-passphrase ─── */
  if (phase.kind === "amount-passphrase") {
    return (
      <Layout
        title="Unshield via relayer"
        subtitle={`recipient: ${phase.recipient}  (source: ${phase.source})`}
      >
        <Form
          fields={[
            {
              name: "amountEth",
              label: "Amount (ETH)",
              validate: (v) =>
                /^[0-9]+(\.[0-9]+)?$/.test(v) ? null : "decimal ETH amount",
            },
            {
              name: "passphrase",
              label: "Privacy Pool passphrase",
              secret: true,
              validate: (v) => (v.length === 0 ? "required" : null),
            },
          ]}
          onCancel={() => setPhase({ kind: "pick-source" })}
          onSubmit={(v) =>
            setPhase({
              kind: "running",
              recipient: phase.recipient,
              source: phase.source,
              amountEth: v.amountEth ?? "",
              passphrase: v.passphrase ?? "",
            })
          }
        />
      </Layout>
    );
  }

  /* ─── running ─── */
  return (
    <RpcRunner
      title="Unshield via relayer…"
      subtitle={`recipient: ${phase.recipient}`}
      method="shielded.unshieldDrain"
      params={{
        recipient: phase.recipient,
        amountEth: phase.amountEth,
        passphrase: phase.passphrase,
      }}
      // PP-state sync (balance/unshield) and import all trigger the same
      // chain walk the deposit flow does — first-run can take 10+ minutes
      // because the bridge scans every relevant on-chain event since the
      // pool's birth. Cached runs return in seconds. 20-minute window
      // covers both.
      timeoutMs={20 * 60 * 1000}
      renderResult={(r: any) => <Text>{JSON.stringify(r, null, 2)}</Text>}
      onDone={onDone}
    />
  );
}

/** Fire eoa.account.add and surface the new address. Used inline by
 *  the derive-running phase: success → advance to amount-passphrase
 *  with the new address as recipient; error → bubble up to the
 *  derive-error phase. Kept inline (not RpcRunner) so the success
 *  handler can read the daemon's response payload, which RpcRunner
 *  hides from its `successActions`. */
function DeriveAndAdvance({
  wallet,
  nextIdx,
  params,
  onSuccess,
  onError,
}: {
  wallet: EoaListEntry;
  nextIdx: number;
  params: Record<string, unknown>;
  onSuccess: (address: string) => void;
  onError: (message: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    (async () => {
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
  const path = `m/44'/60'/${nextIdx}'/0/0`;
  return (
    <Layout
      title={`Deriving fresh sub-account on ${wallet.name}…`}
      subtitle={`derivation: ${path}`}
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
