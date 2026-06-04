import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import MasterUnlockGate from "./MasterUnlockGate.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

/** Shape returned by `wallet.master.status` — keep in sync with the
 *  daemon handler in Server.lean::"wallet.master.status". We only read
 *  the fields the decision logic needs. */
type MasterStatus = {
  initialized: boolean;
  masterUnlocked: boolean;
  enrolledEoas: string[];
  unenrolledEoas: string[];
  customEoas: string[];
};

/** Per-slot unlock status. Probed from `eoa.list` because
 *  `wallet.master.status` only reports the bucket each slot lives in,
 *  not whether it's currently held in memory. */
type EoaListRow = {
  name: string;
  /** Older daemons may not emit this — the legacy field is `locked`. */
  unlocked?: boolean;
  locked?: boolean;
};

/** Minimal slot shape consumed by `UnlockEoaStep`. EOA-only by contract —
 *  callers must pre-filter TPM/R1 wallets to the PIN paths in their
 *  respective flows. Kept structural (not `Wallet`) so flows that have
 *  only an `EoaListEntry` / `EoaSlot` can pass through without a cast. */
export type UnlockEoaTarget = {
  name: string;
  address: string;
};

type Props = {
  /** EOA wallet to unlock. Caller asserts kind === "eoa"; TPM/R1 wallets
   *  go through the PIN path in their respective flows. */
  wallet: UnlockEoaTarget;
  /** Proceed callback once the slot is held in memory. */
  onUnlocked: () => void;
  /** User hit Esc — caller should drop the flow. */
  onCancel: () => void;
  /** Optional subtitle for the unlock prompts (e.g. "to sign swap on sepolia"). */
  subtitle?: string;
};

type Phase =
  | { kind: "probe" }
  | { kind: "auto-unlock"; status: MasterStatus }
  | { kind: "passphrase"; status: MasterStatus; hint?: string }
  | { kind: "master-locked-and-enrolled"; status: MasterStatus }
  | { kind: "master-gate" }
  // "needs-enrolment" surfaces when the slot is in the unenrolled bucket
  // (per-slot wrap but no master wrap) AND the user has not opted into a
  // custom passphrase. Default policy is master-only unlock, so we don't
  // prompt for the per-slot passphrase here — the user is directed to run
  // `leancli wallet enroll <name>` once, after which lazy-rewrap under the
  // current master KEK lets future unlocks go through the master fast path.
  | { kind: "needs-enrolment"; status: MasterStatus }
  | { kind: "error"; message: string };

/** Decide which unlock path to use for an EOA slot. The four cases:
 *   1. Slot is already unlocked  → fire `onUnlocked` immediately.
 *   2. Slot is enrolled under master AND master is loaded
 *      → call `eoa.unlock` with empty passphrase (daemon's master fast path).
 *   3. Slot is enrolled under master AND master is LOCKED
 *      → notice with a path to MasterUnlockGate; on success retry.
 *   4. Slot has a custom passphrase (or auto-unlock failed)
 *      → prompt for the per-slot passphrase (the historic behaviour).
 *
 *  TPM/R1 wallets are NOT routed through here — their PIN paths live in
 *  the existing flows. */
export default function UnlockEoaStep({
  wallet,
  onUnlocked,
  onCancel,
  subtitle,
}: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "probe" });
  // Sub-account display name ("leanWallet/0") vs daemon slot name
  // ("leanWallet"). Every daemon-side lookup — eoa.list rows, master
  // status buckets, and especially eoa.unlock's filesystem path
  // (`eoa/<name>.json`) — keys by slot name. Strip everything after
  // the first '/' so sub-accounts inherit their parent slot's
  // enrolment status and unlock the same way.
  const slotKey = wallet.name.split("/")[0] ?? wallet.name;

  // Stage 1: probe per-slot unlock status + master state in parallel.
  // If the slot is already unlocked, short-circuit to onUnlocked() — no
  // prompt, no spinner flash. Otherwise classify into one of the phases
  // above based on the master status + enrollment buckets.
  useEffect(() => {
    if (phase.kind !== "probe") return;
    let cancelled = false;
    (async () => {
      // wallet.master.status carries enrolledEoas/customEoas/unenrolledEoas
      // and masterUnlocked — both required by the decision tree.
      // eoa.list gives us this slot's per-slot `locked` (older daemons)
      // or `unlocked` (newer) flag so we can short-circuit when the user
      // already unlocked the slot earlier in this session.
      const [ms, el] = await Promise.all([
        call<MasterStatus>("wallet.master.status"),
        call<EoaListRow[]>("eoa.list"),
      ]);
      if (cancelled) return;

      // Per-slot unlock probe. Treat missing data as "not unlocked"; a
      // false negative just means we'll spend one extra RPC to confirm
      // and unlock — strictly safer than skipping the unlock step.
      const row = el.ok
        ? (el.result ?? []).find((r) => r?.name === slotKey)
        : undefined;
      const slotUnlocked =
        row?.unlocked === true ||
        (row?.locked === false && row?.unlocked === undefined);
      if (slotUnlocked) {
        onUnlocked();
        return;
      }

      if (!ms.ok) {
        // wallet.master.status failed — surface the error rather than
        // silently routing into the wrong path. The fallback to per-slot
        // passphrase is reachable from here via the retry/error UI.
        setPhase({ kind: "error", message: `wallet.master.status: ${ms.error.message}` });
        return;
      }
      const status = ms.result!;
      const enrolled = status.enrolledEoas.includes(slotKey);
      const custom = status.customEoas.includes(slotKey);

      if (custom) {
        // User explicitly set a per-slot passphrase; that's the only way
        // to unlock this slot. Prompt for it.
        setPhase({ kind: "passphrase", status });
        return;
      }
      if (enrolled && status.masterUnlocked) {
        setPhase({ kind: "auto-unlock", status });
        return;
      }
      if (enrolled && !status.masterUnlocked) {
        setPhase({ kind: "master-locked-and-enrolled", status });
        return;
      }
      // Not enrolled and not custom (unenrolled bucket): no master wrap
      // available — the slot still has its per-slot wrap from creation.
      // Default policy (per the no-per-slot-passphrase directive): do
      // NOT prompt for a per-slot passphrase in-flow. Surface a clear
      // 'run enrol' message instead. The user runs the CLI once, the
      // daemon's lazy-rewrap path attaches a master wrap on that unlock,
      // and the next chat/send flow unlocks silently via the master fast
      // path. This also covers the master-locked+unenrolled case — the
      // remediation is the same (unlock master, then enrol).
      setPhase({ kind: "needs-enrolment", status });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  // Stage 2: auto-unlock via the daemon's master fast path (empty
  // passphrase + master KEK already loaded → daemon unwraps via
  // masterWrap). On failure we drop to the regular passphrase prompt
  // rather than blocking the user.
  useEffect(() => {
    if (phase.kind !== "auto-unlock") return;
    let cancelled = false;
    (async () => {
      // Tiny audit-trail breadcrumb so the wrong-path hypothesis can be
      // refuted from journalctl when a user reports an unexpected prompt.
      // eslint-disable-next-line no-console
      console.error(`[tui] auto-unlock via master KEK for slot=${slotKey} (display=${wallet.name})`);
      const r = await call<any>("eoa.unlock", { name: slotKey, passphrase: "" });
      if (cancelled) return;
      if (r.ok) {
        onUnlocked();
        return;
      }
      // Fall back to per-slot passphrase with a hint explaining why.
      setPhase({
        kind: "passphrase",
        status: phase.status,
        hint: `master KEK couldn't unlock this slot — falling back to per-slot passphrase (${r.error.message})`,
      });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  useInput((_, key) => {
    if (phase.kind === "master-locked-and-enrolled") {
      if (key.escape) onCancel();
      // 'M' (or 'm') jumps the user into the inline MasterUnlockGate.
      // No global navigation hop required — we render the gate inside
      // this widget and re-probe on success.
    }
    if (phase.kind === "needs-enrolment") {
      if (key.escape) onCancel();
    }
  });

  if (phase.kind === "probe" || phase.kind === "auto-unlock") {
    const note =
      phase.kind === "auto-unlock"
        ? `unlocking ${wallet.name} via master KEK…`
        : `checking unlock state for ${wallet.name}…`;
    return (
      <Layout title={`Unlock ${wallet.name}`} subtitle={subtitle}>
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>{note}</Text>
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "error") {
    return (
      <Layout title={`Cannot unlock ${wallet.name}`} hint="esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnEsc onCancel={onCancel} />
      </Layout>
    );
  }

  if (phase.kind === "master-gate") {
    return (
      <MasterUnlockGate
        onDone={() => {
          // Re-probe after the user returns — they may have unlocked
          // master, or they may have hit Esc and we should bail.
          setPhase({ kind: "probe" });
        }}
      />
    );
  }

  if (phase.kind === "master-locked-and-enrolled") {
    return (
      <Layout
        title={`Unlock ${wallet.name}`}
        subtitle={subtitle}
        hint="M — unlock master · esc — cancel"
      >
        <Box flexDirection="column" marginBottom={1}>
          <Text color={theme.warn}>
            This slot is enrolled under the master KEK, which is currently locked.
          </Text>
          <Text color={theme.dim}>
            Press <Text color={theme.primary}>M</Text> to unlock master now, or{" "}
            <Text color={theme.primary}>Esc</Text> to cancel.
          </Text>
        </Box>
        <UnlockMasterShortcut onPick={() => setPhase({ kind: "master-gate" })} />
      </Layout>
    );
  }

  if (phase.kind === "needs-enrolment") {
    return (
      <Layout
        title={`Unlock ${wallet.name}`}
        subtitle={subtitle ?? `address: ${wallet.address}`}
        hint="esc — cancel"
      >
        <Box flexDirection="column" marginBottom={1}>
          <Text color={theme.warn}>
            This account needs a one-time enrolment under the master KEK
            before it can be unlocked from chat / send flows.
          </Text>
          <Box marginTop={1}>
            <Text color={theme.dim}>Run this once from the shell:</Text>
          </Box>
          <Box marginTop={1} marginLeft={2}>
            <Text color={theme.primary}>
              leancli wallet enroll {wallet.name}
            </Text>
          </Box>
          <Box marginTop={1} marginLeft={2}>
            <Text color={theme.dim}>
              (or{" "}
              <Text color={theme.primary}>leancli wallet enroll --all</Text>
              {" "}to migrate every unenrolled slot at once)
            </Text>
          </Box>
          <Box marginTop={1}>
            <Text color={theme.dim}>
              Once enrolled, this flow auto-unlocks the slot via the master
              KEK — no per-slot passphrase prompt.
            </Text>
          </Box>
        </Box>
      </Layout>
    );
  }

  // phase.kind === "passphrase"
  const fields: Field[] = [
    {
      name: "passphrase",
      label: `Passphrase for ${wallet.name}`,
      secret: true,
      validate: (v) => (v.length === 0 ? "required" : null),
    },
  ];
  return (
    <Layout
      title={`Unlock ${wallet.name}`}
      subtitle={subtitle ?? `address: ${wallet.address}`}
    >
      {phase.hint && (
        <Box marginBottom={1}>
          <Text color={theme.dim}>{phase.hint}</Text>
        </Box>
      )}
      <Form
        fields={fields}
        onCancel={onCancel}
        onSubmit={async (v) => {
          const pass = v.passphrase ?? "";
          const r = await call<any>("eoa.unlock", {
            name: slotKey,
            passphrase: pass,
          });
          if (r.ok) {
            onUnlocked();
            return;
          }
          setPhase({
            kind: "error",
            message: `unlock: ${r.error.message} (code ${r.error.code})`,
          });
        }}
      />
    </Layout>
  );
}

/** Capture M / m so the master-locked screen has a single hot-key for the
 *  fix-it path. Kept inline so the parent can drive its own state machine
 *  without exporting yet another prop. */
function UnlockMasterShortcut({ onPick }: { onPick: () => void }) {
  useInput((input) => {
    if (input === "m" || input === "M") onPick();
  });
  return null;
}

function BackOnEsc({ onCancel }: { onCancel: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onCancel();
  });
  return null;
}
