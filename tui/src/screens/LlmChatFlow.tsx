import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout, Banner } from "../widgets/Layout.js";
import Form, { Field } from "../widgets/Form.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

/**
 * Opt-in local-LLM chat flow.
 *
 * SECURITY GRADIENT (Vitalik "secure LLMs" framing):
 *   • Default Send / Swap = verified path: typed form fields → Lean
 *     Intent ADT → deterministic encoder → simulate → ConfirmGate.
 *     No NLP. No model. Suitable for high-value operations.
 *   • THIS screen = experimental path: free-text prompt → regex (Lean)
 *     → llama-server (untrusted) → IntentParser hard-rejects (Lean)
 *     → deterministic encoder → simulate → ConfirmGate.
 *     The model is treated as malicious throughout; the user sees the
 *     canonical Intent text alongside the simulation in confirm.
 *
 * The "experimental" banner is intentional: users should understand
 * they are taking a different trust path than Send/Swap. Same wallet,
 * same key, weaker trust on what's being signed.
 */
type Props = {
  onDone: (s: boolean) => void;
  /** Caller hooks the "Sign & broadcast" affordance to SendRawFlow. */
  onApprove?: (
    tx: { to: string; value: string; data: string; rationale?: string; canonical?: string },
    chainId: number,
  ) => void;
};

type DraftResponse = {
  regex?: {
    action: string;
    fields: { k: string; v: string }[];
    unresolved: string[];
    confidence: string;
  };
  llmRaw?: string;
  llmError?: string;
  intentActionTag?: string;
  canonical?: string;
  validateError?: string;
  encoded?: { to: string; value: number; data: string; chainId: number };
  encodeError?: string;
  /** Set when the model legitimately returned the {error, ask} shape
   *  (i.e., couldn't fill the intent without inventing). This is NOT a
   *  Lean rejection — the model behaved correctly and is asking for
   *  more info. UX-wise we surface it as a clarification, not a fail. */
  modelAsk?: { error: string; question: string };
};

type Phase =
  | { kind: "form" }
  | { kind: "ensuring"; prompt: string; chainId: number }
  | { kind: "drafting"; prompt: string; chainId: number }
  | { kind: "review"; chainId: number; result: DraftResponse }
  | { kind: "err"; message: string };

export default function LlmChatFlow({ onDone, onApprove }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "form" });

  useEffect(() => {
    if (phase.kind === "ensuring") {
      let cancelled = false;
      (async () => {
        const r = await call<{ outcome: string }>("llm.ensureUp", {});
        if (cancelled) return;
        if (!r.ok) {
          setPhase({ kind: "err", message: `llm.ensureUp failed: ${r.error.message}` });
          return;
        }
        const out = r.result.outcome ?? "(unknown)";
        if (out.startsWith("spawnFailed") || out === "spawnDisabled") {
          setPhase({
            kind: "err",
            message:
              `local model not available (${out}). Configure LLM_SERVER_BINARY + LLM_MODEL_PATH, or set LLM_BACKEND=anthropic with ANTHROPIC_API_KEY.`,
          });
          return;
        }
        setPhase({ kind: "drafting", prompt: phase.prompt, chainId: phase.chainId });
      })();
      return () => {
        cancelled = true;
      };
    }
    if (phase.kind === "drafting") {
      let cancelled = false;
      (async () => {
        const r = await call<DraftResponse>("chat.draft", {
          prompt: phase.prompt,
          chainId: phase.chainId,
        });
        if (cancelled) return;
        if (!r.ok) {
          setPhase({ kind: "err", message: `chat.draft failed: ${r.error.message}` });
          return;
        }
        setPhase({ kind: "review", chainId: phase.chainId, result: r.result });
      })();
      return () => {
        cancelled = true;
      };
    }
  }, [phase]);

  useInput((_, key) => {
    if (key.escape) onDone(false);
  });

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
        placeholder: 'e.g. "send 0.01 ETH to 0x..."',
        validate: (v) => (v.trim().length > 0 ? null : "required"),
      },
    ];
    return (
      <Layout
        title="Local-LLM chat (experimental)"
        subtitle="untrusted model · regex seeds the LLM · Lean hard-rejects · simulate + confirm before signing"
        hint="enter — submit · esc — cancel"
      >
        <Banner
          kind="warn"
          text="EXPERIMENTAL. This path runs your prompt through a local language model. For high-value transactions prefer the standard Send / Swap screens — those are constructed entirely from your typed fields and do not invoke any model."
        />
        <Form
          fields={fields}
          onSubmit={(v) =>
            setPhase({
              kind: "ensuring",
              prompt: v.prompt ?? "",
              chainId: Number(v.chainId ?? "0"),
            })
          }
          onCancel={() => onDone(false)}
        />
      </Layout>
    );
  }

  if (phase.kind === "ensuring") {
    return (
      <Layout title="Local-LLM chat" subtitle="checking llama-server" hint="esc — cancel">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          probing local model · spawning if absent
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "drafting") {
    return (
      <Layout title="Local-LLM chat" subtitle="model + regex + Lean validator" hint="esc — cancel">
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          regex → llama-server → IntentParser → encode
        </Text>
      </Layout>
    );
  }

  if (phase.kind === "err") {
    return (
      <Layout title="Local-LLM chat" subtitle="error" hint="esc — back">
        <Text color={theme.err}>{phase.message}</Text>
      </Layout>
    );
  }

  // review
  const { result } = phase;
  const canSign = !!(result.encoded && onApprove);
  return (
    <Layout
      title="Local-LLM chat — review"
      subtitle={`chain ${phase.chainId} · ${result.intentActionTag ?? "n/a"}`}
      hint={canSign ? "enter — sign · esc — back" : "esc — back"}
    >
      <RegexBlock regex={result.regex} />
      <LlmRawBlock raw={result.llmRaw} err={result.llmError} />
      {result.modelAsk && <ModelAskBlock ask={result.modelAsk} />}
      <ValidateBlock err={result.validateError} encodeErr={result.encodeError} />
      {result.canonical && <CanonicalBlock canonical={result.canonical} />}
      {canSign && (
        <SignAffordance
          onApprove={() => {
            onApprove!(
              {
                to: result.encoded!.to,
                value: "0x" + BigInt(result.encoded!.value).toString(16),
                data: result.encoded!.data,
                rationale: "from local-LLM chat (experimental)",
                canonical: result.canonical,
              },
              phase.chainId,
            );
          }}
        />
      )}
    </Layout>
  );
}

function RegexBlock({ regex }: { regex?: DraftResponse["regex"] }) {
  if (!regex) return null;
  return (
    <Box flexDirection="column" marginBottom={1} borderStyle="single" borderColor={theme.dim} paddingX={1}>
      <Text bold color={theme.dim}>
        regex (Lean, seed for the model)
      </Text>
      <Text>
        <Text color={theme.dim}>action: </Text>
        {regex.action}{" "}
        <Text color={theme.dim}>· confidence: </Text>
        {regex.confidence}
      </Text>
      {regex.fields.map((kv, i) => (
        <Text key={i}>
          <Text color={theme.dim}>{kv.k.padEnd(12)}</Text> {kv.v}
        </Text>
      ))}
      {regex.unresolved.length > 0 &&
        regex.unresolved.map((u, i) => (
          <Text key={`u${i}`} color={theme.warn}>
            ! {u}
          </Text>
        ))}
    </Box>
  );
}

function LlmRawBlock({ raw, err }: { raw?: string; err?: string }) {
  if (err) {
    return (
      <Box flexDirection="column" marginBottom={1} borderStyle="single" borderColor={theme.err} paddingX={1}>
        <Text bold color={theme.err}>
          llm sidecar error
        </Text>
        <Text>{err}</Text>
      </Box>
    );
  }
  if (!raw) return null;
  return (
    <Box flexDirection="column" marginBottom={1} borderStyle="single" borderColor={theme.dim} paddingX={1}>
      <Text bold color={theme.dim}>
        llm raw output (untrusted — validated below)
      </Text>
      <Text>{raw.slice(0, 400)}</Text>
    </Box>
  );
}

function ModelAskBlock({ ask }: { ask: { error: string; question: string } }) {
  return (
    <Box flexDirection="column" marginBottom={1} borderStyle="single" borderColor={theme.warn} paddingX={1}>
      <Text bold color={theme.warn}>
        model asks for clarification (this is fine — not a rejection)
      </Text>
      <Text>
        <Text color={theme.dim}>reason: </Text>
        {ask.error}
      </Text>
      <Text>
        <Text color={theme.dim}>asks:   </Text>
        {ask.question}
      </Text>
      <Text color={theme.dim}>
        Press esc, then re-enter the prompt with the missing info (e.g. paste a 0x address).
      </Text>
    </Box>
  );
}

function ValidateBlock({ err, encodeErr }: { err?: string; encodeErr?: string }) {
  if (!err && !encodeErr) return null;
  return (
    <Box flexDirection="column" marginBottom={1} borderStyle="single" borderColor={theme.err} paddingX={1}>
      <Text bold color={theme.err}>
        rejected by Lean
      </Text>
      {err && <Text>validate: {err}</Text>}
      {encodeErr && <Text>encode: {encodeErr}</Text>}
    </Box>
  );
}

function CanonicalBlock({ canonical }: { canonical: string }) {
  return (
    <Box flexDirection="column" marginBottom={1} borderStyle="single" borderColor={theme.ok} paddingX={1}>
      <Text bold color={theme.ok}>
        canonical intent (Lean-rendered, version-stable)
      </Text>
      {canonical.split("\n").map((line, i) => (
        <Text key={i}>{line}</Text>
      ))}
    </Box>
  );
}

function SignAffordance({ onApprove }: { onApprove: () => void }) {
  useInput((_, key) => {
    if (key.return) onApprove();
  });
  return (
    <Box marginTop={1}>
      <Text>
        <Text color={theme.primary}>enter</Text> — proceed to confirm + sign
      </Text>
    </Box>
  );
}
