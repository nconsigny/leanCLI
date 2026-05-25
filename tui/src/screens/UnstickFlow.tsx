import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout, Banner } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { Wallet } from "../types.js";
import { hexToBigInt } from "../format.js";

type SubAccount = {
  index: number;
  path: string;
  address: string;
  label?: string;
};

type NoncePair = {
  /** Confirmed (next-to-use given mined history). */
  latest: number;
  /** Pending (next-to-use including mempool). pending - latest = stuck count. */
  pending: number;
};

type Phase =
  | { kind: "load-accounts" }
  | { kind: "err"; message: string }
  | { kind: "pick-account"; accounts: SubAccount[] }
  | { kind: "load-nonces"; account: SubAccount }
  | { kind: "pick-nonce"; account: SubAccount; nonces: NoncePair }
  | { kind: "manual-nonce"; account: SubAccount; nonces: NoncePair }
  | { kind: "confirm"; account: SubAccount; nonce: number; nonces: NoncePair }
  | { kind: "run"; account: SubAccount; params: Record<string, unknown> };

type Props = {
  wallet: Wallet;
  chain: string;
  onDone: () => void;
};

export default function UnstickFlow({ wallet, chain, onDone }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "load-accounts" });

  useInput((_, key) => {
    if (key.escape && phase.kind !== "run") onDone();
  });

  useEffect(() => {
    if (phase.kind !== "load-accounts") return;
    let cancelled = false;
    (async () => {
      const r = await call<{ accounts: SubAccount[] }>("eoa.account.list", { name: wallet.name });
      if (cancelled) return;
      if (!r.ok) return setPhase({ kind: "err", message: r.error.message });
      const accounts = r.result?.accounts ?? [];
      if (accounts.length === 0) {
        return setPhase({ kind: "err", message: "no sub-accounts in this wallet" });
      }
      if (accounts.length === 1) {
        return setPhase({ kind: "load-nonces", account: accounts[0]! });
      }
      setPhase({ kind: "pick-account", accounts });
    })();
    return () => { cancelled = true; };
  }, [phase.kind, wallet.name]);

  useEffect(() => {
    if (phase.kind !== "load-nonces") return;
    let cancelled = false;
    (async () => {
      const [lr, pr] = await Promise.all([
        call<{ nonce: string }>("chain.nonce", { address: phase.account.address, block: "latest", chain }),
        call<{ nonce: string }>("chain.nonce", { address: phase.account.address, block: "pending", chain }),
      ]);
      if (cancelled) return;
      if (!lr.ok) return setPhase({ kind: "err", message: `latest nonce read failed: ${lr.error.message}` });
      if (!pr.ok) return setPhase({ kind: "err", message: `pending nonce read failed: ${pr.error.message}` });
      const latest = Number(hexToBigInt(lr.result?.nonce));
      const pending = Number(hexToBigInt(pr.result?.nonce));
      setPhase({ kind: "pick-nonce", account: phase.account, nonces: { latest, pending } });
    })();
    return () => { cancelled = true; };
  }, [phase.kind, chain]);

  if (phase.kind === "load-accounts" || phase.kind === "load-nonces") {
    return (
      <Layout title={`Unstick pending nonce · ${wallet.name}`} subtitle={`${chain}`}>
        <Text>
          <Text color={theme.primary}><Spinner type="dots" /></Text>
          <Text color={theme.dim}>{" "}{phase.kind === "load-accounts" ? "loading sub-accounts…" : "reading latest + pending nonces…"}</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "err") {
    return (
      <Layout title={`Unstick pending nonce · ${wallet.name}`} subtitle={chain} hint="esc back">
        <Banner kind="err" text={phase.message} />
      </Layout>
    );
  }

  if (phase.kind === "pick-account") {
    const items = phase.accounts.map((a) => ({
      label: `#${a.index}${a.label ? ` ${a.label}` : ""}  ${a.path}  ${a.address}`,
      value: a,
    }));
    return (
      <Layout
        title={`Unstick pending nonce · ${wallet.name}`}
        subtitle={`Pick the sub-account whose pending nonce you want to drop · ${chain}`}
        hint="↑/↓ move · enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={onDone}
          onSelect={(it) => setPhase({ kind: "load-nonces", account: it.value })}
        />
      </Layout>
    );
  }

  if (phase.kind === "pick-nonce") {
    const { latest, pending } = phase.nonces;
    const stuckCount = Math.max(0, pending - latest);
    const stuckNonces: number[] = [];
    for (let n = latest; n < pending; n++) stuckNonces.push(n);
    type Pick = { kind: "stuck"; nonce: number } | { kind: "manual" };
    const items: Array<{ label: string; value: Pick }> = [
      ...stuckNonces.map((n): { label: string; value: Pick } => ({
        label: `nonce ${n}${n === latest ? "  (oldest — drop this first)" : ""}`,
        value: { kind: "stuck", nonce: n },
      })),
      { label: "manual nonce…", value: { kind: "manual" } },
    ];
    return (
      <Layout
        title={`Unstick pending nonce · ${wallet.name}`}
        subtitle={`#${phase.account.index} ${phase.account.address} · ${chain} · latest=${latest} pending=${pending} (${stuckCount} stuck)`}
        hint="↑/↓ move · enter select · esc back"
      >
        {stuckCount === 0 && (
          <Banner kind="info" text="No pending-only nonces. The mempool view matches the latest mined nonce — nothing to drop here." />
        )}
        <Select
          items={items}
          arrowNav
          onBack={onDone}
          onSelect={(it) => {
            if (it.value.kind === "manual") {
              setPhase({ kind: "manual-nonce", account: phase.account, nonces: phase.nonces });
            } else {
              setPhase({ kind: "confirm", account: phase.account, nonce: it.value.nonce, nonces: phase.nonces });
            }
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "manual-nonce") {
    const fields: Field[] = [
      {
        name: "nonce",
        label: `Nonce (decimal; latest=${phase.nonces.latest} pending=${phase.nonces.pending})`,
        validate: (v) => /^\d+$/.test(v.trim()) ? null : "decimal integer expected",
      },
    ];
    return (
      <Layout
        title={`Unstick pending nonce · ${wallet.name}`}
        subtitle={`#${phase.account.index} ${phase.account.address} · ${chain}`}
      >
        <Form
          fields={fields}
          onCancel={() => setPhase({ kind: "pick-nonce", account: phase.account, nonces: phase.nonces })}
          onSubmit={(v) => {
            const n = parseInt((v.nonce ?? "").trim(), 10);
            setPhase({ kind: "confirm", account: phase.account, nonce: n, nonces: phase.nonces });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "confirm") {
    const { latest, pending } = phase.nonces;
    const inPendingRange = phase.nonce >= latest && phase.nonce < pending;
    const fields: Field[] = [
      {
        name: "priorityFeeGwei",
        label: "Priority tip in gwei (3 is usually enough on Sepolia/mainnet)",
        initial: "3",
        validate: (v) => /^\d+$/.test(v.trim()) && parseInt(v, 10) >= 1 ? null : "integer ≥ 1 expected",
      },
    ];
    return (
      <Layout
        title={`Confirm drop · nonce ${phase.nonce}`}
        subtitle={`#${phase.account.index} ${phase.account.address} · ${chain}`}
        hint="enter — broadcast · esc back"
      >
        {!inPendingRange && (
          <Banner kind="warn" text={`Nonce ${phase.nonce} is outside the pending range [${latest}, ${pending}). Daemon will still attempt the drop, but the node may reject it as already-mined or too-far-ahead.`} />
        )}
        <Text color={theme.dim}>Effect: send 0 ETH self-transfer with nonce {phase.nonce} at the chosen tip. Frees mempool slot so downstream nonces can be re-evaluated.</Text>
        <Form
          fields={fields}
          onCancel={() => setPhase({ kind: "pick-nonce", account: phase.account, nonces: phase.nonces })}
          onSubmit={(v) => {
            const tip = parseInt((v.priorityFeeGwei ?? "3").trim(), 10);
            const params: Record<string, unknown> = {
              name: wallet.name,
              nonce: phase.nonce,
              account: phase.account.index,
              priorityFeeGwei: tip,
              chain,
            };
            setPhase({ kind: "run", account: phase.account, params });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "run") {
    return (
      <RpcRunner
        title="Dropping pending nonce…"
        subtitle={`#${phase.account.index} ${phase.account.address} · nonce ${(phase.params as any).nonce} · ${chain}`}
        method="eoa.dropNonce"
        params={phase.params}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ drop tx broadcast</Text>
            <Text color={theme.dim}>txHash: {r?.txHash ?? "(unknown)"}</Text>
            {r?.status && (
              <Text color={r.status === "success" ? theme.ok : theme.warn}>status: {r.status}</Text>
            )}
            <Text color={theme.dim}>If the original stuck tx is still in the mempool you may see "replacement transaction underpriced" — bump the tip and try again.</Text>
          </Box>
        )}
        onDone={onDone}
      />
    );
  }

  return null;
}
