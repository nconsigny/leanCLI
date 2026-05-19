import React, { useEffect, useRef, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import Select, { SelectItem } from "../widgets/Select.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

/**
 * Opt-in local-LLM chat flow — redesigned as a proper multi-turn chat.
 *
 * SECURITY GRADIENT (Vitalik "secure LLMs" framing):
 *   • Default Send / Swap = verified path: typed form fields → Lean
 *     Intent ADT → deterministic encoder → simulate → ConfirmGate.
 *     No NLP. No model.
 *   • THIS screen = experimental path: free-text prompt → regex (Lean)
 *     → llama-server (untrusted) → IntentParser hard-rejects (Lean)
 *     → deterministic encoder → simulate → ConfirmGate.
 *
 * UX shape: ChatGPT-like. Top is a scrollable conversation; bottom is a
 * persistent text input. Each user prompt fires a chat.draft call; the
 * response is rendered as an assistant turn. When the assistant turn
 * carries an encoded tx, pressing `p` (proceed) hands off to
 * SendRawFlow's confirm + sign gate. Esc leaves the chat.
 *
 * Each prompt is independent — there's no conversation context sent to
 * the model yet. The chat is multi-turn from the user's perspective;
 * the model sees each turn fresh. Carrying history into the LLM call
 * is a follow-up; the wire shape is ready (chat.draft can grow a
 * history field) but not yet wired.
 */

type Props = {
  onDone: (s: boolean) => void;
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
  modelAsk?: { error: string; question: string };
};

type Turn =
  | { kind: "user"; text: string }
  | { kind: "assistant"; status: "pending" | "done"; result?: DraftResponse; error?: string }
  | { kind: "system"; text: string; tone?: "info" | "warn" | "err" };

/** A configured per-chain endpoint, as returned by network.show. We
 *  display every chain the user already has an RPC for so they can
 *  pick one without ever needing to set an RPC URL in the flow. */
type ConfiguredChain = {
  name: string;
  chainId: number;
  url: string;
  isCurrent: boolean;
};

type Phase =
  | { kind: "boot" } // initial ensureUp + chains fetch
  | { kind: "needChain"; chains: ConfiguredChain[] }
  | { kind: "chat"; chainId: number; chainName: string; turns: Turn[]; input: string; busy: boolean }
  | { kind: "fatal"; message: string };

export default function LlmChatFlow({ onDone, onApprove }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "boot" });

  // Boot: ensureUp + fetch configured chains from the daemon.
  useEffect(() => {
    if (phase.kind !== "boot") return;
    (async () => {
      // 1. ensure llama-server.
      const r = await call<{ outcome: string }>("llm.ensureUp", {});
      if (!r.ok) {
        setPhase({ kind: "fatal", message: `llm.ensureUp failed: ${r.error.message}` });
        return;
      }
      const out = r.result.outcome ?? "(unknown)";
      if (out.startsWith("spawnFailed") || out === "spawnDisabled") {
        setPhase({
          kind: "fatal",
          message:
            `local model not available (${out}). Configure LLM_SERVER_BINARY + LLM_MODEL_PATH, or set LLM_BACKEND=anthropic with ANTHROPIC_API_KEY.`,
        });
        return;
      }
      // 2. fetch configured chains. The daemon's network.show enumerates
      //    every per-chain endpoint the user already configured — that's
      //    the menu we show in the toggle. No need to "set an RPC again".
      const n = await call<{
        perChain: { name: string; chainId: number; url: string; isCurrent: boolean }[];
      }>("network.show", {});
      if (!n.ok) {
        setPhase({ kind: "fatal", message: `network.show failed: ${n.error.message}` });
        return;
      }
      const chains = (n.result.perChain ?? []).filter((c) => c.chainId > 0);
      if (chains.length === 0) {
        setPhase({
          kind: "fatal",
          message: "No per-chain RPCs configured. Run `kohaku network set-rpc-chain <name> <url>` first.",
        });
        return;
      }
      setPhase({ kind: "needChain", chains });
    })();
  }, [phase.kind]);

  // Global keys: esc leaves the chat from any phase.
  useInput((_input, key) => {
    if (key.escape) onDone(false);
  });

  if (phase.kind === "boot") {
    return (
      <Container chainTag="…" >
        <Text>
          <Text color={theme.primary}><Spinner type="dots" /></Text>{" "}
          probing local model · spawning if absent
        </Text>
      </Container>
    );
  }

  if (phase.kind === "fatal") {
    return (
      <Container chainTag="error">
        <Text color={theme.err}>{phase.message}</Text>
        <Text color={theme.dim}>esc — back</Text>
      </Container>
    );
  }

  if (phase.kind === "needChain") {
    return (
      <ChainPicker
        chains={phase.chains}
        onPick={(c) =>
          setPhase({
            kind: "chat",
            chainId: c.chainId,
            chainName: c.name,
            turns: [],
            input: "",
            busy: false,
          })
        }
      />
    );
  }

  return (
    <ChatBody
      chainId={phase.chainId}
      chainName={phase.chainName}
      turns={phase.turns}
      input={phase.input}
      busy={phase.busy}
      onInputChange={(v) => setPhase({ ...phase, input: v })}
      onSubmit={async () => {
        const text = phase.input.trim();
        if (!text || phase.busy) return;
        const turnsAfterUser: Turn[] = [
          ...phase.turns,
          { kind: "user", text },
          { kind: "assistant", status: "pending" },
        ];
        setPhase({ ...phase, turns: turnsAfterUser, input: "", busy: true });
        const r = await call<DraftResponse>("chat.draft", { prompt: text, chainId: phase.chainId });
        const finished: Turn = r.ok
          ? { kind: "assistant", status: "done", result: r.result }
          : { kind: "assistant", status: "done", error: r.error.message };
        // Replace the pending assistant turn with the finished one.
        const updated = [...turnsAfterUser];
        updated[updated.length - 1] = finished;
        setPhase((p) => (p.kind === "chat" ? { ...p, turns: updated, busy: false } : p));
      }}
      onProceed={(turn) => {
        if (!turn.result?.encoded || !onApprove) return;
        const enc = turn.result.encoded;
        onApprove(
          {
            to: enc.to,
            value: "0x" + BigInt(enc.value).toString(16),
            data: enc.data,
            rationale: "from local-LLM chat (experimental)",
            canonical: turn.result.canonical,
          },
          phase.chainId,
        );
      }}
    />
  );
}

/* ---------- Sub-components ---------- */

/** Outer chrome for the chat screen. Two distinct boxes:
 *  - Top: header rectangle showing what this screen is + active chain.
 *  - Below: whatever the phase wants to render (chain picker, chat body,
 *    error). The body lives in its own flexed column so input bar can be
 *    pinned at the bottom of the chat phase. */
function Container({ children, chainTag }: { children: React.ReactNode; chainTag: string }) {
  return (
    <Box flexDirection="column" paddingX={1}>
      {/* Header rectangle — the koi-red double border identifies this as
        a top-level hub screen, same convention as the main menu. */}
      <Box
        borderStyle="double"
        borderColor={theme.koiRed}
        paddingX={2}
        paddingY={0}
        flexDirection="column"
      >
        <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
          {" le chat · local LLM "}
          {chainTag !== "…" ? `· ${chainTag}` : ""}
        </Text>
        <Text color={theme.dim}>
          untrusted model · regex+ENS+wallet seed · Lean validator · canonical text in confirm
        </Text>
      </Box>
      <Box marginTop={1} flexDirection="column">{children}</Box>
    </Box>
  );
}

/** Lists the daemon's already-configured chains and lets the user pick
 *  one with arrow keys. No free-text chainId input — the daemon's own
 *  per-chain endpoint map is the source of truth, so the user never
 *  has to re-set an RPC URL to start a chat on a different chain. */
function ChainPicker({
  chains,
  onPick,
}: {
  chains: ConfiguredChain[];
  onPick: (c: ConfiguredChain) => void;
}) {
  const items: SelectItem<ConfiguredChain>[] = chains.map((c) => ({
    label: `${c.name.padEnd(10)}  chainId=${c.chainId}${c.isCurrent ? "  [daemon's default]" : ""}`,
    value: c,
    key: c.name,
  }));
  return (
    <Container chainTag="…">
      <Box flexDirection="column">
        <Text>Pick a chain. These are the per-chain RPCs your daemon already has configured:</Text>
        <Box marginTop={1}>
          <Select
            items={items}
            onSelect={(it) => onPick(it.value)}
          />
        </Box>
        <Text color={theme.dim}>↑/↓ move · enter pick · esc leave</Text>
      </Box>
    </Container>
  );
}

function ChatBody({
  chainId,
  chainName,
  turns,
  input,
  busy,
  onInputChange,
  onSubmit,
  onProceed,
}: {
  chainId: number;
  chainName: string;
  turns: Turn[];
  input: string;
  busy: boolean;
  onInputChange: (v: string) => void;
  onSubmit: () => void;
  onProceed: (turn: Extract<Turn, { kind: "assistant" }>) => void;
}) {
  // Find the most recent encoded assistant turn for the proceed hotkey.
  const latestSignable = [...turns].reverse().find(
    (t): t is Extract<Turn, { kind: "assistant" }> =>
      t.kind === "assistant" && t.status === "done" && !!t.result?.encoded,
  );

  useInput((ch, key) => {
    // 'p' = proceed to sign the latest signable assistant turn.
    if (!busy && ch?.toLowerCase() === "p" && latestSignable) {
      onProceed(latestSignable);
    }
  });

  return (
    <Container chainTag={`${chainName} (${chainId})`}>
      {/* Conversation block — every turn renders as a row inside the
        framed rectangle. Single border so it visually nests under the
        koi-red header. */}
      <Box
        flexDirection="column"
        borderStyle="single"
        borderColor={theme.dim}
        paddingX={1}
        paddingY={0}
      >
        {turns.length === 0 ? (
          <Box flexDirection="column">
            <Text color={theme.dim}>
              Examples to try:
            </Text>
            <Text color={theme.dim}>
              {"  "}<Text color={theme.primary}>send 0.001 ETH to niard.eth</Text>
            </Text>
            <Text color={theme.dim}>
              {"  "}<Text color={theme.primary}>approve 100 USDC for vitalik.eth</Text>
            </Text>
            <Text color={theme.dim}>
              {"  "}<Text color={theme.primary}>revoke USDC for 0xC0deDeAD...</Text>
            </Text>
          </Box>
        ) : (
          turns.map((t, i) => (
            <TurnRow key={i} turn={t} isLatestSignable={t === latestSignable} />
          ))
        )}
      </Box>

      {/* Input bar — double-border rectangle pinned below the conversation,
        evoking Claude Code's prompt bar. The `> ` glyph + cursor inside
        the box makes it obvious where to type. */}
      <Box
        marginTop={1}
        flexDirection="column"
        borderStyle="double"
        borderColor={busy ? theme.dim : theme.primary}
        paddingX={1}
      >
        <Box>
          <Text color={busy ? theme.dim : theme.primary} bold>
            {">  "}
          </Text>
          {busy ? (
            <Text color={theme.dim}>
              <Spinner type="dots" /> thinking…
            </Text>
          ) : (
            <TextInput value={input} onChange={onInputChange} onSubmit={onSubmit} />
          )}
        </Box>
      </Box>
      <Box marginTop={0}>
        <Text color={theme.dim}>
          enter — send{latestSignable ? " · p — sign latest draft" : ""} · esc — leave chat
        </Text>
      </Box>
    </Container>
  );
}

function TurnRow({
  turn,
  isLatestSignable,
}: {
  turn: Turn;
  isLatestSignable: boolean;
}) {
  if (turn.kind === "user") {
    return (
      <Box marginBottom={1} flexDirection="column">
        <Box>
          <Text color={theme.primary} bold>{"› you  "}</Text>
        </Box>
        <Box paddingLeft={2}>
          <Text>{turn.text}</Text>
        </Box>
      </Box>
    );
  }
  if (turn.kind === "system") {
    const color =
      turn.tone === "err" ? theme.err : turn.tone === "warn" ? theme.warn : theme.dim;
    return (
      <Box marginBottom={1}>
        <Text color={color}>· {turn.text}</Text>
      </Box>
    );
  }
  // assistant
  if (turn.status === "pending") {
    return (
      <Box marginBottom={1} flexDirection="column">
        <Box>
          <Text color={theme.dim} bold>{"› le chat"}</Text>
        </Box>
        <Box paddingLeft={2}>
          <Text color={theme.dim}>
            <Spinner type="dots" /> regex → llama-server → IntentParser → encode
          </Text>
        </Box>
      </Box>
    );
  }
  if (turn.error) {
    return (
      <Box marginBottom={1} flexDirection="column">
        <Box>
          <Text color={theme.err} bold>{"› le chat"}</Text>
        </Box>
        <Box paddingLeft={2}>
          <Text color={theme.err}>transport error: {turn.error}</Text>
        </Box>
      </Box>
    );
  }
  const r = turn.result!;
  return (
    <Box marginBottom={1} flexDirection="column">
      <Box>
        <Text color={theme.ok} bold>{"› le chat  "}</Text>
        <Text>
          {r.intentActionTag ?? r.regex?.action ?? "(no action)"}
        </Text>
        <Text color={theme.dim}>{" · regex="}{r.regex?.confidence ?? "?"}</Text>
      </Box>

      {/* Compact body. Each block omitted when absent. */}
      {r.regex && <RegexLine regex={r.regex} />}
      {r.modelAsk && <AskLine ask={r.modelAsk} />}
      {(r.validateError || r.encodeError || r.llmError) && (
        <RejectLine
          validateErr={r.validateError}
          encodeErr={r.encodeError}
          llmErr={r.llmError}
        />
      )}
      {r.canonical && <CanonicalLines canonical={r.canonical} />}
      {r.encoded && isLatestSignable && (
        <Box marginTop={1} paddingLeft={5}>
          <Text color={theme.primary} bold>↳ press p to confirm + sign </Text>
          <Text color={theme.dim}>(simulate + ConfirmGate)</Text>
        </Box>
      )}
    </Box>
  );
}

function RegexLine({
  regex,
}: {
  regex: NonNullable<DraftResponse["regex"]>;
}) {
  return (
    <Box paddingLeft={5} flexDirection="column">
      <Text color={theme.dim}>
        regex: {regex.fields.map((kv) => `${kv.k}=${kv.v}`).join("  ")}
      </Text>
      {regex.unresolved.map((u, i) => (
        <Text key={i} color={theme.dim}>! {u}</Text>
      ))}
    </Box>
  );
}

function AskLine({ ask }: { ask: { error: string; question: string } }) {
  return (
    <Box paddingLeft={5} flexDirection="column">
      <Text color={theme.warn}>
        model asks (this is fine — not a rejection):
      </Text>
      <Text color={theme.warn}>  reason: {ask.error}</Text>
      <Text color={theme.warn}>  asks:   {ask.question}</Text>
    </Box>
  );
}

function RejectLine({
  validateErr,
  encodeErr,
  llmErr,
}: {
  validateErr?: string;
  encodeErr?: string;
  llmErr?: string;
}) {
  return (
    <Box paddingLeft={5} flexDirection="column">
      {llmErr && <Text color={theme.err}>llm: {llmErr}</Text>}
      {validateErr && <Text color={theme.err}>rejected: {validateErr}</Text>}
      {encodeErr && <Text color={theme.err}>encode: {encodeErr}</Text>}
    </Box>
  );
}

function CanonicalLines({ canonical }: { canonical: string }) {
  return (
    <Box paddingLeft={5} flexDirection="column" marginTop={1}>
      <Text color={theme.ok} bold>canonical (Lean):</Text>
      {canonical.split("\n").map((line, i) => (
        <Text key={i}>  {line}</Text>
      ))}
    </Box>
  );
}
