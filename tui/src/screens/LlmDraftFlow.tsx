import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import Select from "../widgets/Select.js";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

type Props = {
  onDone: (s: boolean) => void;
  /** Caller hooks the "Approve & sign" affordance to push SendRawFlow.
   *  Optional — when absent, the review screen is read-only (legacy
   *  Phase 0 behavior). */
  onApprove?: (tx: { to: string; value: string; data: string; rationale?: string }, chainId: number) => void;
};

type Phase =
  | { kind: "form" }
  | { kind: "drafting"; prompt: string; chainId: number }
  | { kind: "candidates"; chainId: number; result: any }
  | {
      kind: "review";
      chainId: number;
      candidate: any;
      decoded: any;
      sim: any;
    }
  | { kind: "err"; message: string };

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;

/** Phase 0 of the LLM-driven calldata flow.
 *
 *  v0 backend: rule-based pattern matcher in `bridge/llm/`. The wire
 *  shape is the same as the future model-backed version; the TUI just
 *  paints whatever candidates the daemon returns. Every candidate goes
 *  through decode + simulate + manual confirm before reaching a wallet —
 *  the LLM never touches signing.
 *
 *  This is reachable from "More commands → Ask the agent". */
export default function LlmDraftFlow({ onDone, onApprove }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "form" });

  if (phase.kind === "form") {
    const fields: Field[] = [
      {
        name: "chainId",
        label: "Chain ID",
        placeholder: "1 (mainnet) · 11155111 (sepolia)",
        validate: (v) => (/^\d+$/.test(v) ? null : "expected a positive integer"),
      },
      {
        name: "prompt",
        label: "What do you want to do?",
        placeholder: 'e.g. "send 100 USDC to 0xc8A4…"',
        validate: (v) => (v.trim().length > 0 ? null : "required"),
      },
    ];
    return (
      <Layout
        title="Ask the agent"
        subtitle="Natural-language → calldata draft. v0: rule-based; never signs by itself."
        hint="enter — submit · esc — back"
      >
        <Form
          fields={fields}
          onCancel={() => onDone(false)}
          onSubmit={(v) =>
            setPhase({
              kind: "drafting",
              prompt: v.prompt ?? "",
              chainId: Number(v.chainId ?? "1"),
            })
          }
        />
      </Layout>
    );
  }

  if (phase.kind === "drafting") {
    return <DraftRunner phase={phase} setPhase={setPhase} />;
  }

  if (phase.kind === "candidates") {
    return (
      <CandidatePicker
        chainId={phase.chainId}
        result={phase.result}
        onPick={(candidate, decoded, sim) =>
          setPhase({ kind: "review", chainId: phase.chainId, candidate, decoded, sim })
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  if (phase.kind === "review") {
    return (
      <CandidateReview
        chainId={phase.chainId}
        candidate={phase.candidate}
        decoded={phase.decoded}
        sim={phase.sim}
        onApprove={
          onApprove
            ? () =>
                onApprove(
                  {
                    to: phase.candidate.to,
                    value: phase.candidate.value,
                    data: phase.candidate.data,
                    rationale: phase.candidate.rationale,
                  },
                  phase.chainId,
                )
            : undefined
        }
        onCancel={() => onDone(false)}
      />
    );
  }

  if (phase.kind === "err") {
    return (
      <Layout title="Draft failed" hint="enter / esc — back">
        <Banner kind="err" text={phase.message} />
        <BackOnInput onDone={() => onDone(false)} />
      </Layout>
    );
  }
  return null;
}

function DraftRunner({
  phase,
  setPhase,
}: {
  phase: Extract<Phase, { kind: "drafting" }>;
  setPhase: (p: Phase) => void;
}) {
  useEffect(() => {
    let cancelled = false;
    call<any>("tx.draftFromIntent", {
      prompt: phase.prompt,
      chainId: phase.chainId,
    }).then((r) => {
      if (cancelled) return;
      if (!r.ok) return setPhase({ kind: "err", message: r.error.message });
      const inner = r.result?.result ?? r.result;
      if (inner?.ok === false) {
        return setPhase({
          kind: "err",
          message: inner.error?.message ?? "draft failed",
        });
      }
      setPhase({ kind: "candidates", chainId: phase.chainId, result: inner });
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return (
    <Layout title="Drafting…">
      <Text>
        <Text color={theme.primary}>
          <Spinner type="dots" />
        </Text>{" "}
        <Text color={theme.dim}>asking the agent for candidates</Text>
      </Text>
    </Layout>
  );
}

function CandidatePicker({
  chainId,
  result,
  onPick,
  onCancel,
}: {
  chainId: number;
  result: any;
  onPick: (candidate: any, decoded: any, sim: any) => void;
  onCancel: () => void;
}) {
  const candidates = (result?.candidates ?? []) as any[];
  const usable = candidates.filter((c) => c.confidence !== "rejected");
  const [pickedIdx, setPickedIdx] = useState<number | null>(null);
  const [decoded, setDecoded] = useState<any>(null);
  const [sim, setSim] = useState<any>(null);

  useInput((_, key) => {
    if (key.escape) onCancel();
  });

  useEffect(() => {
    if (pickedIdx === null) return;
    const c = usable[pickedIdx];
    if (!c || !ADDR_RE.test(c.to)) return;
    let cancelled = false;
    Promise.all([
      call<any>("tx.decodeIntent", {
        chainId,
        to: c.to,
        value: c.value,
        data: c.data,
      }),
      call<any>("tx.simulate", {
        chainId,
        to: c.to,
        value: c.value,
        data: c.data,
        block: "latest",
        trace: true,
      }),
    ]).then(([d, s]) => {
      if (cancelled) return;
      const dec = d.ok ? d.result?.result ?? d.result : { matched: false };
      const si = s.ok ? s.result : { ok: false, simRpcError: s.error.message };
      setDecoded(dec);
      setSim(si);
      onPick(c, dec, si);
    });
    return () => {
      cancelled = true;
    };
  }, [pickedIdx]);

  if (usable.length === 0) {
    return (
      <Layout title="No usable candidates" hint="enter / esc — back">
        <Banner
          kind="warn"
          text={result?.reason ?? "the agent didn't produce any drafts"}
        />
        {(candidates as any[]).map((c, i) => (
          <Text key={i} color={theme.dim}>
            • {c.rationale}
          </Text>
        ))}
        <BackOnInput onDone={onCancel} />
      </Layout>
    );
  }

  const items = usable.map((c, i) => ({
    label: `${i + 1}. [${c.confidence}] → ${c.to.slice(0, 10)}… · data ${c.data === "0x" ? "0x (native)" : c.data.slice(0, 10) + "…"}`,
    value: i,
  }));

  return (
    <Layout
      title={`Agent produced ${usable.length} candidate${usable.length === 1 ? "" : "s"}`}
      subtitle="Pick one to decode + simulate. Each candidate still goes through the confirm gate."
      hint="↑/↓ move · enter pick · esc cancel"
    >
      <Select items={items} onSelect={(it) => setPickedIdx(it.value)} />
      {pickedIdx !== null && (decoded === null || sim === null) && (
        <Text color={theme.dim}>
          <Spinner type="dots" /> decoding + simulating…
        </Text>
      )}
      <Box marginTop={1} flexDirection="column">
        {usable.map((c, i) => (
          <Text key={i} color={theme.dim}>
            {i + 1}. {c.rationale}
          </Text>
        ))}
      </Box>
    </Layout>
  );
}

function CandidateReview({
  chainId: _chainId,
  candidate,
  decoded,
  sim,
  onApprove,
  onCancel,
}: {
  chainId: number;
  candidate: any;
  decoded: any;
  sim: any;
  onApprove?: () => void;
  onCancel: () => void;
}) {
  useInput((input, key) => {
    if (key.escape) onCancel();
    // Enter approves & signs when a handler is wired; otherwise it just
    // dismisses (legacy read-only behavior).
    if (key.return) {
      if (onApprove) onApprove();
      else onCancel();
    }
    // 'q' always exits.
    if (input === "q") onCancel();
  });
  const okSim = sim?.ok === true;
  return (
    <Layout
      title="Review draft"
      subtitle={onApprove
        ? "If this looks right, press Enter to sign — wallet picker is next."
        : "Phase 0 stops here — to actually sign, copy the calldata into Send-flow."}
      hint={onApprove ? "enter — approve & sign · esc — back" : "enter / esc — back"}
    >
      <Box flexDirection="column" marginBottom={1}>
        <Text color={theme.primary} bold>
          {candidate.rationale}
        </Text>
        {candidate.warning && (
          <Text color={theme.warn}>⚠ {candidate.warning}</Text>
        )}
        <Text color={theme.dim}>
          to: {candidate.to} · value: {candidate.value} · data: {candidate.data}
        </Text>
      </Box>
      <Box flexDirection="column" marginBottom={1}>
        <Text>
          <Text color={theme.dim}>decoded: </Text>
          {decoded?.matched ? (
            <Text color={theme.ok}>
              {decoded.intent ?? decoded.function ?? "(no intent)"}
            </Text>
          ) : (
            <Text color={theme.dim}>(no descriptor matched)</Text>
          )}
        </Text>
        {decoded?.fields?.map((f: any, i: number) => (
          <Text key={i}>
            <Text color={theme.dim}>{f.label.padEnd(14)}</Text> {f.formatted}
          </Text>
        ))}
      </Box>
      <Box flexDirection="column">
        <Text>
          <Text color={theme.dim}>simulation: </Text>
          {sim?.simRpcError ? (
            <Text color={theme.warn}>(daemon error)</Text>
          ) : okSim ? (
            <Text color={theme.ok}>✓ would succeed</Text>
          ) : (
            <Text color={theme.err}>✗ would revert</Text>
          )}
        </Text>
        {sim?.gasEstimate && (
          <Text>
            <Text color={theme.dim}>gas: </Text>
            <Text>
              {(() => {
                try {
                  return BigInt(sim.gasEstimate).toString();
                } catch {
                  return sim.gasEstimate;
                }
              })()}{" "}
              units
            </Text>
          </Text>
        )}
        {sim?.revertReason && (
          <Text color={theme.err}>revert: {String(sim.revertReason).slice(0, 200)}</Text>
        )}
      </Box>
    </Layout>
  );
}

function BackOnInput({ onDone }: { onDone: () => void }) {
  useInput((_, key) => {
    if (key.return || key.escape) onDone();
  });
  return null;
}
