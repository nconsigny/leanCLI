import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import { Layout, Banner } from "../widgets/Layout.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

type Status = {
  initialized: boolean;
  tpmHardwareReady: boolean;
};

type Phase =
  | { kind: "loading" }
  | {
      kind: "passphrase";
      tpmReady: boolean;
      pass1: string;
      pass2: string;
      step: "pass1" | "pass2";
      err: string | null;
    }
  | {
      kind: "tpm-pin";
      tpmReady: boolean;
      passphrase: string;
      pin1: string;
      pin2: string;
      step: "pin1" | "pin2";
      err: string | null;
    }
  | {
      kind: "submitting";
      passphrase: string;
      masterPin: string | null;
    }
  | { kind: "done" }
  | { kind: "error"; msg: string };

const MIN_PASSPHRASE = 8;
const MIN_PIN = 6;

/** First-run wallet-master setup. Mirrors `kohaku wallet master init`
 *  (LeanKohaku/Cli/Runtime.lean#walletMasterInit) — passphrase twice,
 *  optional TPM PIN twice, then `wallet.master.init` with whatever the
 *  user supplied. Skipping (esc) just exits to MainMenu unblocked; the
 *  per-slot passphrase fallback still works. */
export default function MasterInitGate({ onDone }: { onDone: () => void }) {
  const [phase, setPhase] = useState<Phase>({ kind: "loading" });

  useInput((_, key) => {
    if (key.escape && phase.kind !== "submitting") onDone();
  });

  useEffect(() => {
    if (phase.kind !== "loading") return;
    let cancelled = false;
    (async () => {
      const r = await call<Status>("wallet.master.status");
      if (cancelled) return;
      if (!r.ok) return setPhase({ kind: "error", msg: r.error.message });
      setPhase({
        kind: "passphrase",
        tpmReady: r.result!.tpmHardwareReady,
        pass1: "",
        pass2: "",
        step: "pass1",
        err: null,
      });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  useEffect(() => {
    if (phase.kind !== "submitting") return;
    let cancelled = false;
    (async () => {
      const params: Record<string, unknown> = {
        passphrase: phase.passphrase,
      };
      if (phase.masterPin) params.masterPin = phase.masterPin;
      const r = await call("wallet.master.init", params);
      if (cancelled) return;
      if (!r.ok) return setPhase({ kind: "error", msg: r.error.message });
      setPhase({ kind: "done" });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  if (phase.kind === "loading") {
    return (
      <Layout title="Wallet master — setup" hint="esc — skip">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>probing wallet.master.status…</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "error") {
    return (
      <Layout title="Wallet master — error" hint="esc — back">
        <Banner kind="err" text={phase.msg} />
      </Layout>
    );
  }

  if (phase.kind === "passphrase") {
    const isFirst = phase.step === "pass1";
    return (
      <Layout
        title="Wallet master — new passphrase"
        subtitle="one passphrase wraps every EOA seed + the privacy-pool secret"
        hint="enter — next · esc — skip"
      >
        <Box>
          <Text color={theme.dim}>
            {isFirst ? "New passphrase: " : "Confirm passphrase: "}
          </Text>
          <TextInput
            value={isFirst ? phase.pass1 : phase.pass2}
            mask="•"
            onChange={(v) =>
              setPhase(
                isFirst
                  ? { ...phase, pass1: v, err: null }
                  : { ...phase, pass2: v, err: null },
              )
            }
            onSubmit={(v) => {
              if (isFirst) {
                if (v.length < MIN_PASSPHRASE) {
                  setPhase({
                    ...phase,
                    err: `passphrase must be at least ${MIN_PASSPHRASE} characters`,
                  });
                  return;
                }
                setPhase({ ...phase, pass1: v, step: "pass2", err: null });
              } else {
                if (v !== phase.pass1) {
                  setPhase({
                    ...phase,
                    pass2: "",
                    step: "pass1",
                    pass1: "",
                    err: "passphrases did not match",
                  });
                  return;
                }
                if (phase.tpmReady) {
                  setPhase({
                    kind: "tpm-pin",
                    tpmReady: true,
                    passphrase: phase.pass1,
                    pin1: "",
                    pin2: "",
                    step: "pin1",
                    err: null,
                  });
                } else {
                  setPhase({
                    kind: "submitting",
                    passphrase: phase.pass1,
                    masterPin: null,
                  });
                }
              }
            }}
          />
        </Box>
        {phase.err && (
          <Box marginTop={1}>
            <Text color={theme.err}>{phase.err}</Text>
          </Box>
        )}
        {!phase.tpmReady && (
          <Box marginTop={1}>
            <Text color={theme.dim}>
              (No TPM detected — wallet uses encryption-at-rest with this
              passphrase.)
            </Text>
          </Box>
        )}
      </Layout>
    );
  }

  if (phase.kind === "tpm-pin") {
    const isFirst = phase.step === "pin1";
    return (
      <Layout
        title="Wallet master — TPM PIN (optional)"
        subtitle="TPM2 hardware detected — seal the KEK under a PIN for hardware-rate-limited unlocks"
        hint={isFirst ? "enter (empty to skip TPM) · esc — back" : "enter — confirm · esc — back"}
      >
        <Box>
          <Text color={theme.dim}>
            {isFirst ? "TPM PIN (empty = skip): " : "Confirm PIN: "}
          </Text>
          <TextInput
            value={isFirst ? phase.pin1 : phase.pin2}
            mask="•"
            onChange={(v) =>
              setPhase(
                isFirst
                  ? { ...phase, pin1: v, err: null }
                  : { ...phase, pin2: v, err: null },
              )
            }
            onSubmit={(v) => {
              if (isFirst) {
                if (v === "") {
                  // Skip TPM, submit with passphrase only.
                  setPhase({
                    kind: "submitting",
                    passphrase: phase.passphrase,
                    masterPin: null,
                  });
                  return;
                }
                if (v.length < MIN_PIN) {
                  setPhase({
                    ...phase,
                    err: `PIN must be at least ${MIN_PIN} characters`,
                  });
                  return;
                }
                setPhase({ ...phase, pin1: v, step: "pin2", err: null });
              } else {
                if (v !== phase.pin1) {
                  setPhase({
                    ...phase,
                    pin1: "",
                    pin2: "",
                    step: "pin1",
                    err: "PINs did not match",
                  });
                  return;
                }
                setPhase({
                  kind: "submitting",
                  passphrase: phase.passphrase,
                  masterPin: phase.pin1,
                });
              }
            }}
          />
        </Box>
        {phase.err && (
          <Box marginTop={1}>
            <Text color={theme.err}>{phase.err}</Text>
          </Box>
        )}
      </Layout>
    );
  }

  if (phase.kind === "submitting") {
    return (
      <Layout title="Initializing wallet master…">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>calling wallet.master.init</Text>
        </Text>
      </Layout>
    );
  }

  // done
  return (
    <Layout title="Wallet master initialized" hint="enter / esc — continue">
      <Banner kind="ok" text="Master KEK created. You're unlocked for this session." />
      <ContinueOnInput onDone={onDone} />
    </Layout>
  );
}

function ContinueOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
