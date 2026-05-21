import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { EoaListEntry } from "../types.js";

type Account = {
  name: string;
  paramSet: string;
  chainId: number;
  ownerAddress: string;
  ecdsaAttachment:
    | { kind: "existing"; walletName: string; accountIndex: number }
    | { kind: "derived"; walletName: string; path: string };
  pkSeed: string;
  pkRoot: string;
  masterEnrolled: boolean;
  smartAccountAddress: string | null;
  customPassphrase: boolean;
  createdAt: number;
};

type State =
  | { kind: "loading" }
  | { kind: "list"; rows: Account[] }
  | { kind: "detail"; row: Account }
  | { kind: "compute-addr"; row: Account }
  | { kind: "deploy-pick-eoa"; row: Account; eoas: EoaListEntry[] }
  | { kind: "deploy-run"; row: Account; params: Record<string, unknown> }
  | { kind: "send-form"; row: Account }
  // Intermediate ENS-resolve step between send-form and send-run. We
  // hit `chain.resolveName` once and then advance to send-run with the
  // raw form values overridden by the resolved 0x address. Same
  // pattern (form → resolve → run) for rotateOwner.
  | { kind: "resolve-target"; row: Account; raw: string; nextKind: "send-run" | "rotate-owner-run"; pendingParams: Record<string, unknown>; field: "to" | "newOwner" }
  | { kind: "send-run"; row: Account; params: Record<string, unknown> }
  | { kind: "poll-run"; row: Account; userOpHash: string }
  | { kind: "rotate-owner-form"; row: Account }
  | { kind: "rotate-owner-run"; row: Account; params: Record<string, unknown> }
  | { kind: "factory-deploy-pick-eoa"; row: Account; eoas: EoaListEntry[] }
  | { kind: "factory-deploy-run"; row: Account; params: Record<string, unknown> }
  | { kind: "err"; message: string };

type Props = { onBack: () => void };

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;
const HEX_RE  = /^(0x)?[0-9a-fA-F]*$/;

/** List + detail screen for SPHINCS- hybrid ERC-4337 accounts.
 *  Detail view exposes Compute-address / Deploy / Send actions, each
 *  routed through an RpcRunner so error surfaces match the rest of the
 *  TUI. Read-only fields and write actions share one record state. */
export default function SphincsAccountsHub({ onBack }: Props) {
  const [state, setState] = useState<State>({ kind: "loading" });
  // Lazily-populated per-slot deploy status, keyed by slot name. Probed
  // on entering the detail view (one eth_getCode per visit) so we can
  // grey out the "Deploy smart account" action when the contract is
  // already on chain. `undefined` = not probed yet; `null` = probe in
  // flight; concrete value = ready.
  const [deployStatus, setDeployStatus] = useState<Record<string, boolean | null | undefined>>({});

  const reload = async () => {
    setState({ kind: "loading" });
    const r = await call<{ accounts: Account[] }>("sphincs.account.list", {});
    if (!r.ok) {
      setState({ kind: "err", message: r.error?.message ?? "unknown error" });
      return;
    }
    setState({ kind: "list", rows: r.result?.accounts ?? [] });
  };

  useEffect(() => { void reload(); }, []);

  // On entering the detail view for a slot, fire a single deployStatus
  // probe. Cached in `deployStatus[name]` so re-entering the same slot
  // doesn't re-hit the RPC unless the user explicitly triggers a
  // refresh (via re-entering from the list, which calls reload above).
  useEffect(() => {
    if (state.kind !== "detail") return;
    const name = state.row.name;
    if (deployStatus[name] !== undefined) return;
    setDeployStatus((prev) => ({ ...prev, [name]: null }));
    void (async () => {
      const r = await call<{ deployed?: boolean }>("sphincs.account.deployStatus", { name });
      setDeployStatus((prev) => ({
        ...prev,
        [name]: r.ok ? (r.result?.deployed === true) : false,
      }));
    })();
  }, [state.kind === "detail" ? state.row.name : null]);

  useInput((input, key) => {
    if (key.escape || input === "q") {
      // Any sub-state → detail; detail or list → back/exit.
      if (state.kind === "detail" || state.kind === "list") onBack();
      else if ("row" in state) setState({ kind: "detail", row: state.row });
    }
  });

  if (state.kind === "loading") {
    return (
      <Layout title="SPHINCS- hybrid accounts" subtitle="loading…">
        <Text>
          <Text color={theme.primary}><Spinner type="dots" /></Text>{" "}
          <Text color={theme.dim}>sphincs.account.list</Text>
        </Text>
      </Layout>
    );
  }
  if (state.kind === "err") {
    return (
      <Layout title="SPHINCS- hybrid accounts" subtitle="error">
        <Text color={theme.err}>✗ {state.message}</Text>
        <Text color={theme.dim}>Press q to return.</Text>
      </Layout>
    );
  }

  if (state.kind === "compute-addr") {
    return (
      <RpcRunner
        title="Computing counterfactual smart-account address…"
        subtitle={`slot: ${state.row.name}`}
        method="sphincs.account.computeAddress"
        params={{ name: state.row.name }}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ address computed</Text>
            <Text color={theme.dim}>smartAccountAddress: <Text color={theme.primary}>{r?.smartAccountAddress}</Text></Text>
            <Text color={theme.dim}>factory: {r?.factory}</Text>
          </Box>
        )}
        onDone={() => void reload()}
      />
    );
  }

  if (state.kind === "deploy-pick-eoa") {
    if (state.eoas.length === 0) {
      return (
        <Layout title="Deploy SPHINCS- account" subtitle="no EOAs">
          <Text color={theme.warn}>No EOA wallet to fund the deploy. Create one first.</Text>
          <Text color={theme.dim}>esc / q back</Text>
        </Layout>
      );
    }
    const items = state.eoas.map((e) => ({
      label: `${e.name} — ${e.address.slice(0, 10)}…${e.address.slice(-6)}`,
      value: e,
    }));
    return (
      <Layout
        title="Deploy SPHINCS- account"
        subtitle={`Pick the EOA that funds the factory.createAccount tx (slot: ${state.row.name})`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setState({ kind: "detail", row: state.row })}
          onSelect={(it) => setState({
            kind: "deploy-run",
            row: state.row,
            params: { name: state.row.name, deployerWallet: it.value.name },
          })}
        />
      </Layout>
    );
  }

  if (state.kind === "deploy-run") {
    return (
      <RpcRunner
        title="Deploying hybrid smart account…"
        subtitle={`slot: ${state.row.name} · funded by: ${(state.params as any).deployerWallet}`}
        method="sphincs.account.deploy"
        params={state.params}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ deploy tx broadcast</Text>
            <Text color={theme.dim}>smartAccountAddress: <Text color={theme.primary}>{r?.smartAccountAddress ?? "(check after tx mines)"}</Text></Text>
            <Text color={theme.dim}>txHash: {r?.tx?.txHash ?? "(unknown)"}</Text>
            <Text color={theme.dim}>factory: {r?.factory}</Text>
          </Box>
        )}
        onDone={() => void reload()}
      />
    );
  }

  if (state.kind === "send-form") {
    // The `to` field uses `kind: "recipient"` so the user can cycle
    // through their own wallets with ↑/↓ and the RecipientInput widget
    // tags self-matches. `excludeAddress` is the smart-account address
    // (the sender of every UserOp from this slot); falls back to the
    // ECDSA owner when the counterfactual hasn't been computed yet.
    // Validation is intentionally loose — any non-empty string is
    // accepted at form-submit time; ENS names like "vitalik.eth" get
    // resolved via `chain.resolveName` in the interstitial
    // `resolve-target` stage before the send RPC fires.
    const senderAddr = state.row.smartAccountAddress ?? state.row.ownerAddress;
    const fields: Field[] = [
      { name: "to", label: "Target (address, ENS name, or pick your own)",
        kind: "recipient", excludeAddress: senderAddr,
        validate: (v) => v.trim().length > 0 ? null : "required" },
      { name: "valueEth", label: "Value in ETH (decimal, e.g. 0.001)",
        initial: "0",
        // Loose validation — the daemon's LeanKohaku.Util.Units.parseUnits
        // is the source of truth for "is this a valid decimal-ETH amount".
        // We just reject the obvious garbage.
        validate: (v) => /^[0-9]+(\.[0-9]+)?$/.test(v.trim()) ? null : "decimal number expected (e.g. 0 or 0.001)" },
      { name: "data", label: "Calldata hex (optional, blank = pure ETH transfer)",
        validate: (v) => v.length === 0 || HEX_RE.test(v) ? null : "expected hex" },
      { name: "passphrase", label: "Per-slot passphrase (Enter if master KEK is loaded)",
        secret: true, validate: () => null },
    ];
    return (
      <Layout
        title={`Send UserOp · ${state.row.name}`}
        subtitle="Dual-signs (ECDSA owner + SPHINCS-) and submits via the configured bundler."
      >
        <Form
          fields={fields}
          onCancel={() => setState({ kind: "detail", row: state.row })}
          onSubmit={(v) => {
            // Pass `valueEth` straight through — the daemon's send RPC
            // calls `LeanKohaku.Util.Units.parseUnits ethStr 18` to get
            // the wei amount. TUI is a thin RPC forwarder; the
            // decimal-to-wei conversion deliberately stays Lean-side.
            const base: Record<string, unknown> = {
              name: state.row.name,
              valueEth: (v.valueEth ?? "0").trim(),
            };
            if (v.data && v.data.length > 0) base.data = v.data;
            if (v.passphrase && v.passphrase.length > 0) base.passphrase = v.passphrase;
            const raw = (v.to ?? "").trim();
            if (ADDR_RE.test(raw)) {
              // Already a 0x address — skip resolution.
              setState({ kind: "send-run", row: state.row, params: { ...base, to: raw } });
            } else {
              setState({
                kind: "resolve-target",
                row: state.row,
                raw,
                field: "to",
                nextKind: "send-run",
                pendingParams: base,
              });
            }
          }}
        />
      </Layout>
    );
  }

  if (state.kind === "resolve-target") {
    // Synchronous useEffect-style resolver inside a stage by chaining
    // an immediately-fired call from a tiny inline component. Reusing
    // the same chain.resolveName RPC SendFlow's ResolveStep calls.
    return (
      <ResolveStep
        raw={state.raw}
        onResolved={(addr) => {
          const merged = { ...state.pendingParams, [state.field]: addr };
          if (state.nextKind === "send-run") setState({ kind: "send-run", row: state.row, params: merged });
          else setState({ kind: "rotate-owner-run", row: state.row, params: merged });
        }}
        onError={(msg) => setState({ kind: "err", message: msg })}
      />
    );
  }

  if (state.kind === "send-run") {
    // Stash the submitted hash on the RpcRunner result so the user can
    // immediately follow up with the poll action via "successActions".
    let submittedHash: string | null = null;
    return (
      <RpcRunner
        title="Submitting UserOperation…"
        subtitle={`slot: ${state.row.name} · to: ${(state.params as any).to}`}
        method="sphincs.account.send"
        params={state.params}
        timeoutMs={15 * 60 * 1000}
        renderResult={(r: any) => {
          submittedHash = r?.userOpHash ?? null;
          return (
            <Box flexDirection="column">
              <Text color={theme.ok}>✓ userOp submitted</Text>
              <Text color={theme.dim}>userOpHash: <Text color={theme.primary}>{r?.userOpHash}</Text></Text>
              <Text color={theme.dim}>sender: {r?.sender}</Text>
              <Text color={theme.dim}>bundler: {r?.bundler}</Text>
              <Text color={theme.dim}>Enter to poll inclusion · Esc to dismiss</Text>
            </Box>
          );
        }}
        successActions={[
          {
            label: "Poll bundler for inclusion (eth_getUserOperationByHash)",
            onSelect: () => {
              if (submittedHash) setState({ kind: "poll-run", row: state.row, userOpHash: submittedHash });
              else setState({ kind: "detail", row: state.row });
            },
          },
          { label: "Back to account", onSelect: () => setState({ kind: "detail", row: state.row }) },
        ]}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  if (state.kind === "poll-run") {
    return (
      <RpcRunner
        title="Polling bundler for inclusion…"
        subtitle={`userOpHash: ${state.userOpHash}`}
        method="sphincs.account.getUserOp"
        params={{ userOpHash: state.userOpHash }}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.dim}>userOpHash: <Text color={theme.primary}>{r?.userOpHash}</Text></Text>
            {r?.info ? (
              <>
                <Text color={theme.ok}>✓ bundler returned a payload</Text>
                <Text color={theme.dim}>raw: {JSON.stringify(r.info).slice(0, 200)}…</Text>
              </>
            ) : (
              <Text color={theme.warn}>⏳ still pending — poll again in a few seconds</Text>
            )}
          </Box>
        )}
        successActions={[
          { label: "Poll again", onSelect: () => setState({ kind: "poll-run", row: state.row, userOpHash: state.userOpHash }) },
          { label: "Back to account", onSelect: () => setState({ kind: "detail", row: state.row }) },
        ]}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  if (state.kind === "factory-deploy-pick-eoa") {
    if (state.eoas.length === 0) {
      return (
        <Layout title="Deploy SPHINCS- factory" subtitle="no EOAs">
          <Text color={theme.warn}>No EOA wallet to fund the factory deploy. Create one first.</Text>
          <Text color={theme.dim}>esc / q back</Text>
        </Layout>
      );
    }
    const items = state.eoas.map((e) => ({
      label: `${e.name} — ${e.address.slice(0, 10)}…${e.address.slice(-6)}`,
      value: e,
    }));
    return (
      <Layout
        title="Deploy SPHINCS- factory (Sepolia)"
        subtitle={`paramSet: ${state.row.paramSet}. Pick the EOA that funds the deploy.`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setState({ kind: "detail", row: state.row })}
          onSelect={(it) => setState({
            kind: "factory-deploy-run",
            row: state.row,
            params: {
              paramSet: state.row.paramSet,
              deployerWallet: it.value.name,
              chain: "sepolia",
            },
          })}
        />
      </Layout>
    );
  }

  if (state.kind === "factory-deploy-run") {
    return (
      <RpcRunner
        title="Deploying SPHINCS- factory…"
        subtitle={`paramSet: ${(state.params as any).paramSet} · funded by: ${(state.params as any).deployerWallet}`}
        method="sphincs.factory.deploy"
        params={state.params}
        timeoutMs={5 * 60 * 1000}
        renderResult={(r: any) => (
          <Box flexDirection="column">
            <Text color={theme.ok}>✓ factory deploy completed (exitCode {r?.exitCode ?? "?"})</Text>
            <Text color={theme.dim}>factory: <Text color={theme.primary}>{r?.factory ?? "(not parsed from output)"}</Text></Text>
            <Text color={theme.dim}>verifier: {r?.verifier}</Text>
            <Text color={theme.warn}>
              ⚠ Add this address to daemon.json under sphincs_factories.sepolia.{(state.params as any).paramSet} so future RPCs see it.
            </Text>
          </Box>
        )}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  if (state.kind === "rotate-owner-form") {
    // Same ENS-friendly pattern as the send form: pick from own
    // wallets via RecipientInput, fall through to resolve-target when
    // the input isn't already a 0x address.
    const senderAddr = state.row.smartAccountAddress ?? state.row.ownerAddress;
    const fields: Field[] = [
      { name: "newOwner", label: "New ECDSA owner (address, ENS, or your own)",
        kind: "recipient", excludeAddress: senderAddr,
        validate: (v) => v.trim().length > 0 ? null : "required" },
      { name: "passphrase", label: "Per-slot passphrase (Enter if master KEK is loaded)",
        secret: true, validate: () => null },
    ];
    return (
      <Layout
        title={`Rotate owner · ${state.row.name}`}
        subtitle="On-chain ECDSA owner swap. Local store is NOT updated; reconfigure the slot manually after confirming the userOp succeeds."
      >
        <Form
          fields={fields}
          onCancel={() => setState({ kind: "detail", row: state.row })}
          onSubmit={(v) => {
            const base: Record<string, unknown> = {
              name: state.row.name,
            };
            if (v.passphrase && v.passphrase.length > 0) base.passphrase = v.passphrase;
            const raw = (v.newOwner ?? "").trim();
            if (ADDR_RE.test(raw)) {
              setState({ kind: "rotate-owner-run", row: state.row, params: { ...base, newOwner: raw } });
            } else {
              setState({
                kind: "resolve-target",
                row: state.row,
                raw,
                field: "newOwner",
                nextKind: "rotate-owner-run",
                pendingParams: base,
              });
            }
          }}
        />
      </Layout>
    );
  }

  if (state.kind === "rotate-owner-run") {
    let submittedHash: string | null = null;
    return (
      <RpcRunner
        title="Rotating on-chain ECDSA owner…"
        subtitle={`slot: ${state.row.name} · new: ${(state.params as any).newOwner}`}
        method="sphincs.account.rotateOwner"
        params={state.params}
        timeoutMs={15 * 60 * 1000}
        renderResult={(r: any) => {
          submittedHash = r?.userOpHash ?? null;
          return (
            <Box flexDirection="column">
              <Text color={theme.ok}>✓ rotateOwner userOp submitted</Text>
              <Text color={theme.dim}>userOpHash: <Text color={theme.primary}>{r?.userOpHash}</Text></Text>
              <Text color={theme.dim}>newOwner: {r?.newOwner}</Text>
              <Text color={theme.warn}>⚠ Local store still references the old wallet. Reconfigure the slot's ecdsaAttachment after confirming on-chain success via getUserOp.</Text>
            </Box>
          );
        }}
        successActions={[
          {
            label: "Poll bundler for inclusion",
            onSelect: () => {
              if (submittedHash) setState({ kind: "poll-run", row: state.row, userOpHash: submittedHash });
              else setState({ kind: "detail", row: state.row });
            },
          },
          { label: "Back to account", onSelect: () => setState({ kind: "detail", row: state.row }) },
        ]}
        onDone={() => setState({ kind: "detail", row: state.row })}
      />
    );
  }

  if (state.kind === "detail") {
    const r = state.row;
    const attach =
      r.ecdsaAttachment.kind === "existing"
        ? `existing ${r.ecdsaAttachment.walletName} (#${r.ecdsaAttachment.accountIndex})`
        : `derived ${r.ecdsaAttachment.walletName} (${r.ecdsaAttachment.path})`;
    type Action = "compute" | "deploy" | "send" | "rotate-owner" | "factory-deploy" | "back";
    const status = deployStatus[r.name];
    const isDeployed = status === true;
    const probePending = status === null;
    // Build the action list dynamically: when the smart-account is
    // already on-chain we hide "Deploy smart account" outright (it
    // would always revert at first-send-also-deploy initCode anyway).
    // While the probe is in flight we show the action but tag it
    // "(checking…)" so the user knows the gate is being computed.
    const actions: { label: string; value: Action }[] = [];
    actions.push({ label: "Compute counterfactual address (eth_call factory.getAddress)", value: "compute" });
    if (!isDeployed) {
      actions.push({
        label: probePending
          ? "Deploy smart account via factory.createAccount (checking…)"
          : "Deploy smart account via factory.createAccount",
        value: "deploy",
      });
    }
    actions.push({ label: "Send UserOperation via configured bundler", value: "send" });
    actions.push({ label: "Rotate on-chain ECDSA owner (rotateOwner UserOp)", value: "rotate-owner" });
    actions.push({ label: "Deploy the SPHINCS- factory (one-time, Sepolia)", value: "factory-deploy" });
    actions.push({ label: "← Back", value: "back" });
    return (
      <Layout
        title={`SPHINCS- account · ${r.name}`}
        subtitle={`paramSet: ${r.paramSet} · chainId: ${r.chainId}`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Box flexDirection="column">
          <Text color={theme.dim}>owner (ECDSA): <Text color={theme.primary}>{r.ownerAddress}</Text></Text>
          <Text color={theme.dim}>ECDSA source: {attach}</Text>
          <Text color={theme.dim}>pkSeed: <Text>{r.pkSeed}</Text></Text>
          <Text color={theme.dim}>pkRoot: <Text>{r.pkRoot}</Text></Text>
          <Text color={theme.dim}>master-enrolled: {r.masterEnrolled ? "yes" : "no"}</Text>
          <Text color={theme.dim}>custom passphrase: {r.customPassphrase ? "yes" : "no"}</Text>
          <Text color={theme.dim}>
            smart-account addr: {r.smartAccountAddress ?? "(pending compute)"}
          </Text>
          <Text color={theme.dim}>
            on-chain status:{" "}
            {status === undefined || status === null
              ? <Text color={theme.dim}>checking…</Text>
              : status
                ? <Text color={theme.ok}>deployed</Text>
                : <Text color={theme.warn}>not deployed</Text>}
          </Text>
          <Text color={theme.dim}>created: {new Date(r.createdAt * 1000).toISOString()}</Text>
          <Box marginTop={1}>
            <Select
              items={actions}
              arrowNav
              onBack={onBack}
              onSelect={async (it) => {
                if (it.value === "back") onBack();
                else if (it.value === "compute") setState({ kind: "compute-addr", row: r });
                else if (it.value === "deploy") {
                  const er = await call<EoaListEntry[]>("eoa.list", {});
                  setState({
                    kind: "deploy-pick-eoa",
                    row: r,
                    eoas: er.ok && Array.isArray(er.result) ? er.result : [],
                  });
                } else if (it.value === "send") setState({ kind: "send-form", row: r });
                else if (it.value === "rotate-owner") setState({ kind: "rotate-owner-form", row: r });
                else {
                  const er = await call<EoaListEntry[]>("eoa.list", {});
                  setState({
                    kind: "factory-deploy-pick-eoa",
                    row: r,
                    eoas: er.ok && Array.isArray(er.result) ? er.result : [],
                  });
                }
              }}
            />
          </Box>
        </Box>
      </Layout>
    );
  }

  // state.kind === "list"
  if (state.rows.length === 0) {
    return (
      <Layout title="SPHINCS- hybrid accounts" subtitle="(empty)">
        <Text color={theme.dim}>
          No hybrid accounts yet. Create one via "Create wallet →
          SPHINCS- hybrid".
        </Text>
        <Text color={theme.dim}>Press q to return.</Text>
      </Layout>
    );
  }
  // A smart-account's identity is its CREATE2 contract address (the
  // `sender` field every UserOp targets). Fall back to the ECDSA owner
  // only when the counterfactual hasn't been computed yet — that row
  // visibly prompts the user to run "Compute counterfactual address".
  const items = state.rows.map((r) => {
    const id = r.smartAccountAddress;
    const idStr = id
      ? `${id.slice(0, 10)}…${id.slice(-6)}`
      : `(pending — owner ${r.ownerAddress.slice(0, 10)}…${r.ownerAddress.slice(-6)})`;
    return {
      label: `${r.name} — ${r.paramSet} — ${idStr}`,
      value: r,
    };
  });
  return (
    <Layout
      title="SPHINCS- hybrid accounts"
      subtitle={`${state.rows.length} slot${state.rows.length === 1 ? "" : "s"}`}
      hint="↑/↓ move · → / enter detail · esc back"
    >
      <Select
        items={items}
        arrowNav
        onBack={onBack}
        onSelect={(it) => setState({ kind: "detail", row: it.value })}
      />
    </Layout>
  );
}

/** Resolves an ENS-like input via the daemon's `chain.resolveName` RPC
 *  and forwards the resulting 0x address to the caller. Mirrors the
 *  inline ResolveStep helper in `SendFlow.tsx` so the SPHINCS path
 *  surfaces ENS errors with the same shape. */
function ResolveStep({
  raw,
  onResolved,
  onError,
}: {
  raw: string;
  onResolved: (addr: string) => void;
  onError: (msg: string) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    call<{ address?: string }>("chain.resolveName", { name: raw }).then((r) => {
      if (cancelled) return;
      if (!r.ok) return onError(`ENS resolve failed: ${r.error?.message ?? "unknown"}`);
      const addr = r.result?.address;
      const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;
      if (!addr || !ADDR_RE.test(addr)) {
        return onError(`'${raw}' did not resolve to a 0x address`);
      }
      onResolved(addr);
    });
    return () => { cancelled = true; };
  }, []);
  return (
    <Layout title={`Resolving ${raw}…`}>
      <Text>
        <Text color={theme.primary}><Spinner type="dots" /></Text>{" "}
        <Text color={theme.dim}>chain.resolveName</Text>
      </Text>
    </Layout>
  );
}
