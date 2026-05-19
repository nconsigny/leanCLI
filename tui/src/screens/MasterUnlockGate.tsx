import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import Select from "../widgets/Select.js";
import { Layout, Banner } from "../widgets/Layout.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

/** Status returned by `wallet.master.status`. Keep this in sync with the
 *  daemon handler in `Server.lean::"wallet.master.status"`. */
type Status = {
  initialized: boolean;
  withTpm: boolean;
  tpmAvailable: boolean;
  masterUnlocked: boolean;
  enrolledEoas: string[];
  unenrolledEoas: string[];
  customEoas: string[];
};

type UnlockResult = {
  masterUnlocked: boolean;
  enrolled: string[];
  skipped: { name: string; reason: string }[];
};

type Phase =
  | { kind: "loading" }
  | { kind: "error"; msg: string }
  | { kind: "not-initialized" }
  | { kind: "choose-mode"; status: Status }
  | {
      kind: "enter-credential";
      mode: "passphrase" | "pin";
      status: Status;
      draft: string;
      err: string | null;
    }
  | {
      kind: "unlocking";
      mode: "passphrase" | "pin";
      status: Status;
      credential: string;
    }
  | { kind: "done"; result: UnlockResult };

/** Single-prompt master-unlock surface. On mount, asks the daemon for the
 *  manifest status and routes the user to:
 *   - "not initialized" hint when there's no `master.json` yet,
 *   - a passphrase prompt when `withTpm` is absent,
 *   - a TPM-vs-passphrase chooser when both are available.
 *
 *  Result UX surfaces both the enrolled-and-unlocked slot list and the
 *  per-slot skip reasons (`not-enrolled`, `custom-passphrase`, etc.) so the
 *  user can decide whether to re-enrol legacy slots via per-slot `eoa unlock`. */
export default function MasterUnlockGate({ onDone }: { onDone: () => void }) {
  const [phase, setPhase] = useState<Phase>({ kind: "loading" });

  useInput((_, key) => {
    if (key.escape) onDone();
  });

  // Stage 1: probe the daemon for state and route into the right entry phase.
  useEffect(() => {
    if (phase.kind !== "loading") return;
    let cancelled = false;
    (async () => {
      const r = await call<Status>("wallet.master.status");
      if (cancelled) return;
      if (!r.ok) return setPhase({ kind: "error", msg: r.error.message });
      const s = r.result!;
      if (!s.initialized) return setPhase({ kind: "not-initialized" });
      // Surface the TPM path when both are wired up; the user can still
      // switch to passphrase. When only one path exists, skip the chooser.
      if (s.withTpm && s.tpmAvailable) {
        setPhase({ kind: "choose-mode", status: s });
      } else {
        setPhase({
          kind: "enter-credential",
          mode: "passphrase",
          status: s,
          draft: "",
          err: null,
        });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  // Stage 3: fire wallet.unlock with the chosen credential.
  useEffect(() => {
    if (phase.kind !== "unlocking") return;
    let cancelled = false;
    (async () => {
      const params =
        phase.mode === "pin"
          ? { masterPin: phase.credential }
          : { passphrase: phase.credential };
      const r = await call<UnlockResult>("wallet.unlock", params);
      if (cancelled) return;
      if (!r.ok) {
        return setPhase({
          kind: "enter-credential",
          mode: phase.mode,
          status: phase.status,
          draft: "",
          err: r.error.message,
        });
      }
      setPhase({ kind: "done", result: r.result! });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  if (phase.kind === "loading") {
    return (
      <Layout title="Wallet master" hint="esc cancel">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>checking wallet.master.status…</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "error") {
    return (
      <Layout title="Wallet master — error" hint="esc back">
        <Banner kind="err" text={phase.msg} />
      </Layout>
    );
  }

  if (phase.kind === "not-initialized") {
    return (
      <Layout title="Wallet master not initialized" hint="esc back">
        <Text>
          Run{" "}
          <Text color={theme.primary}>kohaku wallet master init</Text> to set up
          one passphrase that unlocks every enrolled EOA + the PP secret.
        </Text>
        <Box marginTop={1}>
          <Text color={theme.dim}>
            Add{" "}
            <Text color={theme.primary}>--with-tpm</Text>
            {" "}to additionally bind to a TPM-sealed master key so future
            unlocks can come through the TPM PIN.
          </Text>
        </Box>
      </Layout>
    );
  }

  if (phase.kind === "choose-mode") {
    return (
      <Layout
        title="Wallet master — pick unlock method"
        subtitle={`enrolled: ${phase.status.enrolledEoas.length} · unenrolled: ${phase.status.unenrolledEoas.length} · custom: ${phase.status.customEoas.length}`}
        hint="↑/↓ move · enter pick · esc back"
      >
        <Select
          items={[
            { label: "TPM PIN (recommended on this box)", value: "pin" },
            { label: "Master passphrase",                  value: "pass" },
          ]}
          onSelect={(it) => {
            const mode = it.value === "pin" ? "pin" : "passphrase";
            setPhase({
              kind: "enter-credential",
              mode,
              status: phase.status,
              draft: "",
              err: null,
            });
          }}
        />
      </Layout>
    );
  }

  if (phase.kind === "enter-credential") {
    const isPin = phase.mode === "pin";
    return (
      <Layout
        title={isPin ? "Master TPM PIN" : "Master passphrase"}
        hint="enter — unlock · esc — back"
      >
        <Box>
          <Text color={theme.dim}>{isPin ? "PIN: " : "Passphrase: "}</Text>
          <TextInput
            value={phase.draft}
            mask="•"
            onChange={(v) => setPhase({ ...phase, draft: v, err: null })}
            onSubmit={(v) =>
              setPhase({
                kind: "unlocking",
                mode: phase.mode,
                status: phase.status,
                credential: v,
              })
            }
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

  if (phase.kind === "unlocking") {
    return (
      <Layout title="Unlocking…">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>
            calling wallet.unlock ({phase.mode === "pin" ? "TPM" : "passphrase"})
          </Text>
        </Text>
      </Layout>
    );
  }

  // phase.kind === "done"
  const enrolled = phase.result.enrolled;
  const skipped = phase.result.skipped;
  return (
    <Layout title="Wallet unlocked" hint="enter / esc — back">
      <Banner
        kind="ok"
        text={`Unlocked ${enrolled.length} slot(s) in one shot.`}
      />
      {enrolled.length > 0 && (
        <Box flexDirection="column" marginTop={1}>
          {enrolled.map((n, i) => (
            <Text key={i} color={theme.dim}>{`  ✓ ${n}`}</Text>
          ))}
        </Box>
      )}
      {skipped.length > 0 && (
        <Box flexDirection="column" marginTop={1}>
          <Text color={theme.warn}>Skipped:</Text>
          {skipped.map((s, i) => (
            <Text key={i} color={theme.dim}>{`  - ${s.name}: ${s.reason}`}</Text>
          ))}
        </Box>
      )}
      <BackOnInput onDone={onDone} />
    </Layout>
  );
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
