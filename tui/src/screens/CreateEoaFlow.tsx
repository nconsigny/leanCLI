import React, { useEffect, useState } from "react";
import { Box, Text } from "ink";
import Spinner from "ink-spinner";
import { Layout } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import RpcRunner from "../widgets/RpcRunner.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

type Props = { onDone: (success: boolean) => void };

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const PATH_RE = /^m(\/[0-9]+'?)+$/;

/** Inline wallet creation. Mirrors `kohaku wallet create eoa <name> [path]`.
 *
 *  When the wallet master KEK is currently held in memory, the daemon
 *  accepts a missing per-slot passphrase, generates an ephemeral one for
 *  the on-disk wrap, and immediately enrolls the slot under master. So
 *  on this code path we drop the Passphrase + Confirm form fields and
 *  submit only `{name, derivationPath?}` — the user has already proven
 *  themselves to the master, asking again is wallet-as-it-shouldn't-be.
 *
 *  When master is NOT loaded (locked or never initialized), we fall back
 *  to the original behavior: prompt for a per-slot passphrase, encrypt
 *  the seed under that. The slot is then enrolled lazily on next unlock
 *  when master eventually comes online. */
export default function CreateEoaFlow({ onDone }: Props) {
  const [params, setParams] = useState<Record<string, string> | null>(null);
  // null while we're still probing wallet.master.status — render a tiny
  // spinner instead of flashing a form that might disappear a frame later.
  const [masterLoaded, setMasterLoaded] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{ masterUnlocked: boolean }>(
        "wallet.master.status",
      );
      if (cancelled) return;
      setMasterLoaded(r.ok ? r.result!.masterUnlocked === true : false);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (masterLoaded === null) {
    return (
      <Layout
        title="Create EOA wallet"
        subtitle="checking master status…"
      >
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>probing wallet.master.status</Text>
        </Text>
      </Layout>
    );
  }

  if (!params) {
    const nameField: Field = {
      name: "name",
      label: "Wallet name",
      placeholder: "e.g. mainEoa",
      validate: (v) =>
        NAME_RE.test(v)
          ? null
          : "1–64 chars: letters, digits, '-' or '_'; must start with alnum",
    };
    const pathField: Field = {
      name: "derivationPath",
      label: "Derivation path (optional)",
      placeholder: "m/44'/60'/0'/0/0",
      validate: (v) =>
        v.length === 0 || PATH_RE.test(v) ? null : "expected BIP-32 path or empty",
    };
    // Passphrase is optional when master is loaded (Enter to skip — the
    // daemon will mint an ephemeral one and immediately enroll the slot
    // under master), required otherwise. The user can still pick their
    // own passphrase when master is loaded; doing so opts the slot out of
    // master auto-enroll (customPassphrase=true) and they manage that
    // slot's unlock independently of the master KEK.
    const passLabel = masterLoaded
      ? "Per-slot passphrase (optional — Enter to use master)"
      : "Passphrase";
    const passField: Field = {
      name: "passphrase",
      label: passLabel,
      secret: true,
      placeholder: masterLoaded ? "leave blank to unlock via master" : undefined,
      validate: (v) => {
        if (v.length === 0) {
          return masterLoaded
            ? null
            : "passphrase required (no master KEK loaded)";
        }
        return v.length < 8 ? "passphrase must be at least 8 characters" : null;
      },
    };
    const confirmField: Field = {
      name: "confirm",
      label: "Confirm passphrase",
      secret: true,
      placeholder: masterLoaded ? "(leave blank if you skipped)" : undefined,
      // Confirm is only required when the user actually typed a passphrase
      // — Form widgets don't know cross-field state, so this validator is
      // tolerant and the cross-check happens in onSubmit below.
      validate: () => null,
    };
    const subtitle = masterLoaded
      ? "Master KEK is unlocked — leave the passphrase blank to enroll this slot under master."
      : "Generates a new BIP-39 mnemonic (24 words), encrypts it with your passphrase.";

    return (
      <Layout title="Create EOA wallet" subtitle={subtitle}>
        <Form
          fields={[nameField, pathField, passField, confirmField]}
          onCancel={() => onDone(false)}
          onSubmit={(v) => {
            const pass = v.passphrase ?? "";
            const conf = v.confirm ?? "";
            if (pass !== conf) {
              // Mismatch → bail to the form (cheap re-render path); a
              // richer impl would surface this inline next to Confirm.
              setParams(null);
              return;
            }
            const base: Record<string, string> = { name: v.name ?? "" };
            if (v.derivationPath) base.derivationPath = v.derivationPath;
            if (pass.length > 0) base.passphrase = pass;
            // When master is loaded and pass is blank, we deliberately do
            // NOT set base.passphrase — the daemon's saveMnemonicSlot path
            // generates an ephemeral one and enrolls under master.
            setParams(base);
          }}
        />
      </Layout>
    );
  }

  return (
    <RpcRunner
      title="Creating EOA wallet…"
      subtitle={`name: ${params.name}`}
      method="eoa.create"
      params={params}
      renderResult={(r: any) => (
        <Box flexDirection="column">
          <Text color={theme.ok}>✓ created</Text>
          <Text color={theme.dim}>address: {r?.address ?? "(unknown)"}</Text>
          <Text color={theme.dim}>derivation: {r?.derivationPath ?? "(default)"}</Text>
          <Text color={theme.warn}>
            ⚠ Reveal &amp; back up the mnemonic with: kohaku wallet show {params.name}
          </Text>
        </Box>
      )}
      onDone={onDone}
    />
  );
}
