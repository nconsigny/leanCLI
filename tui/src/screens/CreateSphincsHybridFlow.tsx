import React, { useEffect, useState } from "react";
import { Box, Text } from "ink";
import Spinner from "ink-spinner";
import { Layout } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { EoaListEntry } from "../types.js";

type Props = { onDone: (success: boolean) => void };

type ParamSet = "SLH-DSA-SHA2-128-24" | "JARDIN-Keccak-128-24" | "C9";
type EcdsaKind = "existing" | "derived";
type Chain = { name: "sepolia"; chainId: 11155111 }
           | { name: "mainnet"; chainId: 1 };

type Stage =
  | { kind: "probing" }
  | { kind: "pick-paramset" }
  | { kind: "pick-chain"; paramSet: ParamSet }
  | { kind: "pick-wallet"; paramSet: ParamSet; chain: Chain }
  | { kind: "pick-ecdsa"; paramSet: ParamSet; chain: Chain; wallet: EoaListEntry }
  | { kind: "form"; paramSet: ParamSet; chain: Chain; wallet: EoaListEntry; ecdsaKind: EcdsaKind }
  | { kind: "rpc"; params: Record<string, string | number> };

const SLOT_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const PATH_RE = /^m(\/[0-9]+'?)+$/;

/** Three-stage hybrid SPHINCS- account creation. ECDSA half is sourced
 *  from one of the wallet's existing EOAs OR a freshly-derived sub-path
 *  under that wallet's BIP-39 seed. SPHINCS half is generated locally
 *  by the shim from a fresh random seed and sealed under the per-slot
 *  passphrase (with an opportunistic master-KEK wrap when loaded —
 *  empty per-slot passphrase + loaded master is the recommended path).
 *
 *  Backed by the daemon's `sphincs.account.create` RPC; this component
 *  is a thin wrapper around RpcRunner per the CLAUDE.md thin-CLI
 *  guidance. */
export default function CreateSphincsHybridFlow({ onDone }: Props) {
  const [stage, setStage] = useState<Stage>({ kind: "probing" });
  const [eoas, setEoas] = useState<EoaListEntry[]>([]);
  const [masterLoaded, setMasterLoaded] = useState(false);
  const [probeError, setProbeError] = useState<string | null>(null);

  // Probe both eoa.list and master status in parallel. The flow needs
  // an EOA wallet to attach to — we surface a hint and bail to MainMenu
  // if there are zero EOAs.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [eoaR, msR] = await Promise.all([
        call<EoaListEntry[]>("eoa.list", {}),
        call<{ masterUnlocked: boolean }>("wallet.master.status", {}),
      ]);
      if (cancelled) return;
      if (!eoaR.ok) {
        setProbeError(`could not list EOAs: ${eoaR.error?.message ?? "unknown"}`);
        return;
      }
      setEoas(Array.isArray(eoaR.result) ? eoaR.result : []);
      setMasterLoaded(msR.ok ? msR.result?.masterUnlocked === true : false);
      setStage({ kind: "pick-paramset" });
    })();
    return () => { cancelled = true; };
  }, []);

  if (stage.kind === "probing") {
    return (
      <Layout title="Create SPHINCS- hybrid account" subtitle="probing wallet state…">
        <Text>
          <Text color={theme.primary}><Spinner type="dots" /></Text>{" "}
          <Text color={theme.dim}>eoa.list + wallet.master.status</Text>
        </Text>
      </Layout>
    );
  }

  if (probeError) {
    return (
      <Layout title="Create SPHINCS- hybrid account" subtitle="probe failed">
        <Text color={theme.err}>✗ {probeError}</Text>
        <Text color={theme.dim}>Press q to return.</Text>
      </Layout>
    );
  }

  if (stage.kind === "pick-paramset") {
    if (eoas.length === 0) {
      return (
        <Layout title="Create SPHINCS- hybrid account" subtitle="no EOA wallet found">
          <Text color={theme.warn}>
            ⚠ A hybrid account attaches its ECDSA half to one of your EOA
            wallets — please create an EOA first via "Create wallet → EOA".
          </Text>
          <Text color={theme.dim}>Press q to return.</Text>
        </Layout>
      );
    }
    const items: { label: string; value: ParamSet }[] = [
      { label: "SLH-DSA-SHA2-128-24 — NIST FIPS 205 candidate, SHA-2",          value: "SLH-DSA-SHA2-128-24" },
      { label: "JARDIN-Keccak-128-24 — keccak256 thash, JARDIN ADRS",           value: "JARDIN-Keccak-128-24" },
      { label: "C9 — WOTS+C / FORS+C, 3816-byte sig (Sepolia-deployed verifier)", value: "C9" },
    ];
    return (
      <Layout
        title="Create SPHINCS- hybrid account · 1/5"
        subtitle="Choose the post-quantum parameter set."
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => onDone(false)}
          onSelect={(it) => setStage({ kind: "pick-chain", paramSet: it.value })}
        />
      </Layout>
    );
  }

  if (stage.kind === "pick-chain") {
    // Sepolia is the only chain where SPHINCS- factory + verifier are
    // wired today; mainnet has no deployed factory yet so we keep it
    // available but warn at the label level. The chain choice is baked
    // into the slot record at create time and drives every downstream
    // RPC's (chain, paramSet) lookup against `cfg.sphincsVerifiers` /
    // `cfg.sphincsFactories` / `cfg.sphincsBundlers`.
    const items: { label: string; value: Chain }[] = [
      { label: "Sepolia (recommended — full deploy/send infra)",          value: { name: "sepolia", chainId: 11155111 } },
      { label: "Mainnet ⚠ no factory deployed yet — slot will be offline", value: { name: "mainnet", chainId: 1 } },
    ];
    return (
      <Layout
        title="Create SPHINCS- hybrid account · 2/5"
        subtitle={`Pick the chain for this hybrid. (paramSet: ${stage.paramSet})`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setStage({ kind: "pick-paramset" })}
          onSelect={(it) => setStage({ kind: "pick-wallet", paramSet: stage.paramSet, chain: it.value })}
        />
      </Layout>
    );
  }

  if (stage.kind === "pick-wallet") {
    const items = eoas.map((e) => ({
      label: `${e.name} — ${e.address.slice(0, 10)}…${e.address.slice(-6)}`,
      value: e,
    }));
    return (
      <Layout
        title="Create SPHINCS- hybrid account · 3/5"
        subtitle={`Pick the EOA wallet that supplies the ECDSA half. (paramSet: ${stage.paramSet} · chain: ${stage.chain.name})`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setStage({ kind: "pick-chain", paramSet: stage.paramSet })}
          onSelect={(it) => setStage({ kind: "pick-ecdsa", paramSet: stage.paramSet, chain: stage.chain, wallet: it.value })}
        />
      </Layout>
    );
  }

  if (stage.kind === "pick-ecdsa") {
    const items: { label: string; value: EcdsaKind }[] = [
      { label: "Use existing account on this wallet (index 0 default)",       value: "existing" },
      { label: "Derive a NEW BIP-44 sub-path under this wallet for the hybrid", value: "derived" },
    ];
    return (
      <Layout
        title="Create SPHINCS- hybrid account · 4/5"
        subtitle={`Where does the ECDSA owner come from? (wallet: ${stage.wallet.name})`}
        hint="↑/↓ move · → / enter select · esc back"
      >
        <Select
          items={items}
          arrowNav
          onBack={() => setStage({ kind: "pick-wallet", paramSet: stage.paramSet, chain: stage.chain })}
          onSelect={(it) =>
            setStage({
              kind: "form",
              paramSet: stage.paramSet,
              chain: stage.chain,
              wallet: stage.wallet,
              ecdsaKind: it.value,
            })}
        />
      </Layout>
    );
  }

  if (stage.kind === "form") {
    const slotPassLabel = masterLoaded
      ? "Per-slot passphrase (optional — Enter to use master)"
      : "Per-slot passphrase";
    const nameField: Field = {
      name: "name",
      label: "Slot name",
      placeholder: "e.g. mySphincs",
      validate: (v) => SLOT_NAME_RE.test(v) ? null : "1–64 chars: letters, digits, '-' or '_'; must start with alnum",
    };
    const fields: Field[] = [nameField];
    if (stage.ecdsaKind === "existing") {
      fields.push({
        name: "accountIndex",
        label: "ECDSA account index (default 0)",
        initial: "0",
        validate: (v) =>
          v.length === 0 || /^[0-9]+$/.test(v) ? null : "non-negative integer or blank for 0",
      });
    } else {
      fields.push(
        {
          name: "path",
          label: "BIP-44 derivation path for the ECDSA half",
          placeholder: "m/44'/60'/1'/0/0",
          validate: (v) => PATH_RE.test(v) ? null : "expected BIP-32 path",
        },
        {
          name: "walletPassphrase",
          label: `Wallet passphrase to unlock '${stage.wallet.name}'`,
          secret: true,
          validate: (v) => v.length > 0 ? null : "required to derive the new ECDSA path",
        },
      );
    }
    fields.push({
      name: "slotPassphrase",
      label: slotPassLabel,
      secret: true,
      placeholder: masterLoaded ? "leave blank to unlock via master" : undefined,
      validate: (v) =>
        v.length === 0
          ? (masterLoaded ? null : "passphrase required (no master KEK loaded)")
          : (v.length < 8 ? "passphrase must be at least 8 characters" : null),
    });
    return (
      <Layout
        title="Create SPHINCS- hybrid account · 5/5"
        subtitle={
          masterLoaded
            ? `chain: ${stage.chain.name} · Master KEK is unlocked — leave the per-slot passphrase blank to enroll under master.`
            : `chain: ${stage.chain.name} · The SPHINCS- sk will be sealed under your per-slot passphrase.`
        }
      >
        <Form
          fields={fields}
          onCancel={() =>
            setStage({ kind: "pick-ecdsa", paramSet: stage.paramSet, chain: stage.chain, wallet: stage.wallet })}
          onSubmit={(v) => {
            const base: Record<string, string | number> = {
              name: v.name ?? "",
              paramSet: stage.paramSet,
              walletName: stage.wallet.name,
              ecdsaKind: stage.ecdsaKind,
              chainId: stage.chain.chainId,
            };
            const slotPass = v.slotPassphrase ?? "";
            if (slotPass.length > 0) base.passphrase = slotPass;
            // empty slotPass + master loaded → daemon mints ephemeral
            if (stage.ecdsaKind === "existing") {
              const idx = (v.accountIndex ?? "0").trim();
              base.accountIndex = idx.length === 0 ? 0 : parseInt(idx, 10);
            } else {
              base.path = v.path ?? "";
              base.walletPassphrase = v.walletPassphrase ?? "";
            }
            setStage({ kind: "rpc", params: base });
          }}
        />
      </Layout>
    );
  }

  // stage.kind === "rpc"
  return (
    <RpcRunner
      title="Creating SPHINCS- hybrid account…"
      subtitle={`paramSet: ${stage.params.paramSet} · wallet: ${stage.params.walletName}`}
      method="sphincs.account.create"
      params={stage.params}
      renderResult={(r: any) => (
        <Box flexDirection="column">
          <Text color={theme.ok}>✓ hybrid account created</Text>
          <Text color={theme.dim}>name: {r?.name}</Text>
          <Text color={theme.dim}>paramSet: {r?.paramSet}</Text>
          <Text color={theme.dim}>chainId: {r?.chainId}</Text>
          <Text color={theme.dim}>owner: {r?.ownerAddress}</Text>
          <Text color={theme.dim}>pkSeed: {r?.pkSeed}</Text>
          <Text color={theme.dim}>pkRoot: {r?.pkRoot}</Text>
          <Text color={theme.dim}>
            masterEnrolled: {String(r?.masterEnrolled ?? false)}
          </Text>
          <Text color={theme.dim}>
            smartAccountAddress: {r?.smartAccountAddress ?? "(pending — run Compute Address from the hub)"}
          </Text>
          {r?.smartAccountAddress
            ? null
            : (
              <Text color={theme.warn}>
                ⚠ No factory configured for this (chain, paramSet) in daemon.json
                yet. Use "Deploy the SPHINCS- factory" from the account hub on
                Sepolia, then "Compute counterfactual address" to populate this.
              </Text>
            )}
        </Box>
      )}
      onDone={onDone}
    />
  );
}
