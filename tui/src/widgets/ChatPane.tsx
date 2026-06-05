import React, { useEffect } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import AnimatedKoi from "./AnimatedKoi.js";
import {
  type Phase,
  type Turn,
  type DraftResponse,
  type DispatchState,
  type PreparedTx,
  type AuditResult,
  type WalletBalance,
  buildChatHistory,
  friendlyAction,
  newSessionKey,
} from "../screens/LlmChatFlow.js";

/**
 * Compact, embeddable "le chat" pane for the dashboard.
 *
 * Same trust contract as the full-screen LlmChatFlow: free text →
 * `chat.draft` (wallet daemon proxies to agentd) → any encoded tx hands
 * off via `onApprove` to SendRawFlow's decode → simulate → ConfirmGate.
 * The pane NEVER signs and never opens the agent socket itself.
 *
 * Shares the lifted Phase/Turn state with LlmChatFlow (owned by App.tsx),
 * so the conversation survives send-raw round-trips AND moving between
 * the dashboard pane and the full chat screen (ctrl+o).
 *
 * Differences from the full screen, all driven by pane constraints:
 *  - no chain picker: the daemon's current chain is auto-picked at boot;
 *  - transcript is windowed to the pane's line budget (alt-screen buffer
 *    means overflow is silently lost — every row here is one line);
 *  - no Tab focus-ring (Tab cycles dashboard panes): Enter on an EMPTY
 *    input acts on the latest draft (sign first, else execute);
 *  - Esc is owned by the dashboard, never handled here.
 */

type Props = {
  phase: Phase;
  setPhase: React.Dispatch<React.SetStateAction<Phase>>;
  /** Wallet rows (from the dashboard's wallet box) used to pre-select
   *  the signing wallet when a draft carries a sender hint. */
  wallets: WalletBalance[];
  isFocused: boolean;
  /** Content line budget (pane height minus border/title rows). */
  contentHeight: number;
  modelName?: string;
  onApprove?: (
    tx: { to: string; value: string; data: string; rationale?: string; canonical?: string },
    chainId: number,
    wallet?: { kind: "eoa" | "tpm"; name: string; address: string },
  ) => void;
  onCreateWallet?: (kind: "eoa", label: string | undefined) => void;
  onOpenFull?: () => void;
  onOpenHistory?: () => void;
};

export default function ChatPane({
  phase,
  setPhase,
  wallets,
  isFocused,
  contentHeight,
  modelName,
  onApprove,
  onCreateWallet,
  onOpenFull,
  onOpenHistory,
}: Props) {
  // Boot: resolve the daemon's configured chains and auto-pick the
  // current one. (The dashboard already ran llm.ensureUp once; we don't
  // re-trigger the spawn-side-effecting probe per pane mount.) A stale
  // `needChain` phase (full chat left mid-pick) auto-picks too.
  useEffect(() => {
    if (phase.kind === "chat" || phase.kind === "fatal") return;
    let cancelled = false;
    const pick = (chains: { name: string; chainId: number; isCurrent: boolean }[]) => {
      const chosen = chains.find((c) => c.isCurrent) ?? chains[0];
      if (!chosen) {
        setPhase({
          kind: "fatal",
          message:
            "No per-chain RPCs configured — set one with `leancli network set-rpc-chain <chain> <url>`.",
        });
        return;
      }
      setPhase({
        kind: "chat",
        chainId: chosen.chainId,
        chainName: chosen.name,
        modelName,
        turns: [],
        input: "",
        busy: false,
        sessionKey: newSessionKey(),
      });
    };
    if (phase.kind === "needChain") {
      pick(phase.chains);
      return;
    }
    (async () => {
      const n = await call<{
        perChain: { name: string; chainId: number; url: string; isCurrent: boolean }[];
      }>("network.show", {});
      if (cancelled) return;
      if (!n.ok) {
        setPhase({ kind: "fatal", message: `network.show failed: ${n.error.message}` });
        return;
      }
      pick((n.result.perChain ?? []).filter((c) => c.chainId > 0));
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind]);

  // Auto-continuation after a successful send-raw broadcast (same
  // producer/consumer contract as LlmChatFlow — App.tsx arms
  // `pendingContinuation`, we fire ONE follow-up chat.draft).
  useEffect(() => {
    if (phase.kind !== "chat") return;
    if (!phase.pendingContinuation) return;
    if (phase.busy) return;
    const cont = phase.pendingContinuation;
    const receiptParts: string[] = [`tx ${cont.txHash}`];
    if (cont.blockNumber !== undefined) receiptParts.push(`block ${cont.blockNumber}`);
    if (cont.status !== undefined) receiptParts.push(`status ${cont.status}`);
    const prompt =
      `[continuation hook] The previous transaction was broadcast (${receiptParts.join(" · ")}). ` +
      `If the user's original request requires additional transactions ` +
      `(for example, a supply after an approve, or a swap after an approve), ` +
      `propose the next step now via propose_send. ` +
      `If the original request is fully satisfied, reply with a single short confirmation — no propose_send needed.`;
    const history = buildChatHistory(phase.turns);
    const turnsAfter: Turn[] = [
      ...phase.turns,
      { kind: "system", tone: "info", text: "↻ continuing — looking for the next step…" },
      { kind: "assistant", status: "pending" },
    ];
    setPhase({ ...phase, turns: turnsAfter, busy: true, pendingContinuation: undefined });
    let cancelled = false;
    (async () => {
      const r = await call<DraftResponse>(
        "chat.draft",
        { prompt, chainId: phase.chainId, sessionKey: phase.sessionKey, history },
        { timeoutMs: 300_000 },
      );
      if (cancelled) return;
      const finished: Turn = r.ok
        ? { kind: "assistant", status: "done", result: r.result }
        : { kind: "assistant", status: "done", error: r.error.message };
      setPhase((p) => {
        if (p.kind !== "chat") return p;
        const updated = [...p.turns];
        updated[updated.length - 1] = finished;
        return { ...p, turns: updated, busy: false };
      });
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind === "chat" ? phase.pendingContinuation?.txHash : null]);

  // ctrl+o expands to the full chat screen (state is lifted; the
  // conversation moves with you). Gated on pane focus.
  useInput(
    (ch, key) => {
      if (key.ctrl && ch === "o") onOpenFull?.();
    },
    { isActive: isFocused },
  );

  if (phase.kind === "boot" || phase.kind === "needChain") {
    return (
      <Text color={theme.dim}>
        <Spinner type="dots" /> starting le chat…
      </Text>
    );
  }
  if (phase.kind === "fatal") {
    return (
      <Box flexDirection="column">
        <Text wrap="truncate-end" color={theme.err}>
          {phase.message.split("\n")[0]}
        </Text>
        <Text color={theme.dim}>ctrl+o — full chat view</Text>
      </Box>
    );
  }

  const turns = phase.turns;
  const latestSignable = [...turns].reverse().find(
    (t): t is Extract<Turn, { kind: "assistant" }> =>
      t.kind === "assistant" && t.status === "done" && !!t.result?.encoded,
  );
  const latestExecutable = [...turns].reverse().find(
    (t): t is Extract<Turn, { kind: "assistant" }> => {
      if (t.kind !== "assistant" || t.status !== "done") return false;
      const r = t.result;
      if (!r || !(r.prepare || r.audit || r.create)) return false;
      return !t.dispatch || t.dispatch.kind === "idle";
    },
  );

  const updateTurnDispatch = (
    target: Extract<Turn, { kind: "assistant" }>,
    next: DispatchState,
  ) =>
    setPhase((p) => {
      if (p.kind !== "chat") return p;
      const idx = p.turns.indexOf(target);
      if (idx < 0) return p;
      const copy = [...p.turns];
      copy[idx] = { ...target, dispatch: next };
      return { ...p, turns: copy };
    });

  /** Same directive dispatcher as the full chat: audit is read-only,
   *  prepare routes its first tx through onApprove → ConfirmGate, create
   *  hands off to the trusted wallet-creation flow. */
  const executeDirective = async (turn: Extract<Turn, { kind: "assistant" }>) => {
    const r = turn.result;
    if (!r) return;
    if (turn.dispatch && turn.dispatch.kind !== "idle") return;
    updateTurnDispatch(turn, { kind: "running" });
    if (r.audit) {
      const resp = await call<AuditResult>(r.audit.rpc, r.audit.params, { timeoutMs: 60_000 });
      updateTurnDispatch(
        turn,
        resp.ok
          ? { kind: "auditDone", data: resp.result }
          : { kind: "error", message: resp.error.message },
      );
      return;
    }
    if (r.prepare) {
      const resp = await call<{ txs?: PreparedTx[]; transactions?: PreparedTx[] }>(
        r.prepare.rpc,
        r.prepare.params,
        { timeoutMs: 300_000 },
      );
      if (!resp.ok) {
        updateTurnDispatch(turn, { kind: "error", message: resp.error.message });
        return;
      }
      const txs = (resp.result.txs ?? resp.result.transactions ?? []) as PreparedTx[];
      updateTurnDispatch(turn, { kind: "prepareDone", txs });
      const first = txs[0];
      if (first && onApprove) {
        onApprove(
          {
            to: first.to,
            value: first.value,
            data: first.data,
            rationale: `from local-LLM chat · ${r.intentActionTag ?? "shielded"} tx 1 of ${txs.length}`,
            canonical: r.canonical,
          },
          phase.chainId,
        );
      }
      return;
    }
    if (r.create) {
      if (!onCreateWallet) {
        updateTurnDispatch(turn, {
          kind: "error",
          message: "wallet creation flow not wired; use the main menu",
        });
        return;
      }
      const kind = r.create.params.kind;
      onCreateWallet(kind, r.create.params.label);
      updateTurnDispatch(turn, { kind: "createHandedOff", walletKind: kind, label: r.create.params.label });
    }
  };

  const proceedWith = (turn: Extract<Turn, { kind: "assistant" }>) => {
    if (!turn.result?.encoded || !onApprove) return;
    const enc = turn.result.encoded;
    const senderHint =
      enc.sender ?? turn.result.regex?.fields?.find((kv) => kv.k === "from")?.v;
    const preselected = (() => {
      if (!senderHint) return undefined;
      const want = senderHint.toLowerCase();
      const w = wallets.find((wb) => wb.address.toLowerCase() === want);
      return w ? { kind: w.kind, name: w.name, address: w.address } : undefined;
    })();
    onApprove(
      {
        to: enc.to,
        value: "0x" + BigInt(enc.value).toString(16),
        data: enc.data,
        rationale: "from local-LLM chat (experimental)",
        canonical: turn.result.canonical,
      },
      phase.chainId,
      preselected,
    );
  };

  const submit = async () => {
    if (phase.busy) return;
    const text = phase.input.trim();
    if (text.length === 0) {
      // Empty Enter acts on the most recent draft: sign first (it opens
      // the full ConfirmGate screen — nothing is signed there without
      // explicit confirmation), else execute the pending directive.
      if (latestSignable) return proceedWith(latestSignable);
      if (latestExecutable) return void executeDirective(latestExecutable);
      return;
    }
    const firstToken = text.split(/\s+/, 1)[0];
    if (firstToken === "/history") {
      setPhase({ ...phase, input: "" });
      onOpenHistory?.();
      return;
    }
    if (firstToken === "/clear") {
      const oldKey = phase.sessionKey;
      setPhase({
        ...phase,
        input: "",
        sessionKey: newSessionKey(),
        turns: [{ kind: "system", text: "(context cleared — new mission)", tone: "info" }],
      });
      const r = await call<unknown>(
        "chat.rolloverSession",
        { chainId: phase.chainId, sessionKey: oldKey },
        { timeoutMs: 10_000 },
      );
      if (!r.ok) {
        setPhase((p) =>
          p.kind === "chat"
            ? {
                ...p,
                turns: [
                  ...p.turns,
                  {
                    kind: "system",
                    tone: "warn",
                    text: `rollover RPC failed (${r.error.message}); new turns still use a fresh sessionKey`,
                  },
                ],
              }
            : p,
        );
      }
      return;
    }
    const history = buildChatHistory(phase.turns);
    const turnsAfterUser: Turn[] = [
      ...phase.turns,
      { kind: "user", text },
      { kind: "assistant", status: "pending" },
    ];
    setPhase({ ...phase, turns: turnsAfterUser, input: "", busy: true });
    const r = await call<DraftResponse>(
      "chat.draft",
      { prompt: text, chainId: phase.chainId, sessionKey: phase.sessionKey, history },
      { timeoutMs: 300_000 },
    );
    const finished: Turn = r.ok
      ? { kind: "assistant", status: "done", result: r.result }
      : { kind: "assistant", status: "done", error: r.error.message };
    const updated = [...turnsAfterUser];
    updated[updated.length - 1] = finished;
    setPhase((p) => (p.kind === "chat" ? { ...p, turns: updated, busy: false } : p));
  };

  // ----- transcript windowing -----
  // Status row (1) + input row (1) + affordance row (0/1) come out of the
  // budget; the rest is transcript. Each transcript entry is exactly one
  // single-line <Text wrap="truncate-end">, so slicing the flat line list
  // gives an exact fit inside the alt-screen viewport.
  const affordance = latestSignable
    ? `⏎ empty input → review & sign: ${friendlyAction(latestSignable.result?.intentActionTag)}`
    : latestExecutable
      ? `⏎ empty input → execute: ${directiveRpc(latestExecutable)}`
      : null;
  const fixedRows = 2 + (affordance ? 1 : 0);
  const transcriptBudget = Math.max(3, contentHeight - fixedRows);
  const allLines = turns.flatMap((t, i) => turnToLines(t, i, t === latestSignable));
  const dropped = Math.max(0, allLines.length - transcriptBudget + (allLines.length > transcriptBudget ? 1 : 0));
  const visible = dropped > 0 ? allLines.slice(allLines.length - (transcriptBudget - 1)) : allLines;

  return (
    <Box flexDirection="column">
      <Text wrap="truncate-end" color={theme.dim}>
        {phase.modelName ?? modelName ?? "local model"} · {phase.chainName} ({phase.chainId})
        {phase.busy ? " · " : ""}
        {phase.busy && (
          <Text color={theme.primary}>
            <Spinner type="dots" /> thinking…
          </Text>
        )}
      </Text>
      {turns.length === 0 ? (
        // Welcome state: show the Kohaku koi beside the examples — same
        // identity the full le-chat screen carries, so collapsing the
        // full chat (ctrl+o) back into this pane is visually continuous.
        // The koi is 24×12; only render it when the pane has the room,
        // and it costs nothing once the conversation starts (this whole
        // block is replaced by the transcript below).
        contentHeight >= 14 ? (
          <Box flexDirection="row">
            <Box width={24} minWidth={24} height={12} flexShrink={0} marginRight={2}>
              <AnimatedKoi size="tiny" />
            </Box>
            <Box flexDirection="column" flexGrow={1} minWidth={0}>
              <Text wrap="truncate-end" color={theme.koiCream} bold>
                le chat · local LLM
              </Text>
              <Text wrap="truncate-end" color={theme.dim}>
                untrusted model · Lean validator · canonical text in confirm
              </Text>
              <Box marginTop={1} flexDirection="column">
                <Text color={theme.dim}>Examples:</Text>
                <Text wrap="truncate-end" color={theme.dim}>
                  {"  "}<Text color={theme.primary}>send 0.001 ETH to niard.eth</Text>
                </Text>
                <Text wrap="truncate-end" color={theme.dim}>
                  {"  "}<Text color={theme.primary}>swap 0.1 ETH to USDC</Text>
                </Text>
                <Text wrap="truncate-end" color={theme.dim}>
                  {"  "}<Text color={theme.primary}>approve 100 USDC for vitalik.eth</Text>
                </Text>
              </Box>
            </Box>
          </Box>
        ) : (
          <Box flexDirection="column">
            <Text color={theme.dim}>Examples:</Text>
            <Text wrap="truncate-end" color={theme.dim}>
              {"  "}<Text color={theme.primary}>send 0.001 ETH to niard.eth</Text>
            </Text>
            <Text wrap="truncate-end" color={theme.dim}>
              {"  "}<Text color={theme.primary}>swap 0.1 ETH to USDC</Text>
            </Text>
          </Box>
        )
      ) : (
        <Box flexDirection="column">
          {dropped > 0 && (
            <Text wrap="truncate-end" color={theme.dim}>
              … {dropped} earlier line{dropped === 1 ? "" : "s"} — ctrl+o opens the full chat
            </Text>
          )}
          {visible}
        </Box>
      )}
      {affordance && (
        <Text wrap="truncate-end" color={theme.ok} bold>
          {affordance}
        </Text>
      )}
      <Box>
        <Text color={isFocused && !phase.busy ? theme.primary : theme.dim} bold>
          {"> "}
        </Text>
        {phase.busy ? (
          <Text color={theme.dim}>…</Text>
        ) : isFocused ? (
          <TextInput
            value={phase.input}
            onChange={(v) => setPhase((p) => (p.kind === "chat" ? { ...p, input: v } : p))}
            onSubmit={() => void submit()}
            focus={isFocused}
          />
        ) : (
          <Text wrap="truncate-end" color={theme.dim}>
            {phase.input.length > 0 ? phase.input : "(tab here to chat)"}
          </Text>
        )}
      </Box>
    </Box>
  );
}

function directiveRpc(turn: Extract<Turn, { kind: "assistant" }>): string {
  const r = turn.result;
  if (!r) return "—";
  return r.audit?.rpc ?? r.prepare?.rpc ?? r.create?.rpc ?? "—";
}

/** Render one turn as an array of single-line <Text> elements. Compact
 *  by design — the full-fidelity rendering (trace blocks, ownership
 *  badges, full canonical text) lives in the full chat (ctrl+o). */
function turnToLines(
  t: Turn,
  i: number,
  isLatestSignable: boolean,
): React.ReactElement[] {
  const k = (suffix: string) => `t${i}-${suffix}`;
  if (t.kind === "user") {
    return [
      <Text key={k("u")} wrap="truncate-end">
        <Text color={theme.primary} bold>{"› you  "}</Text>
        <Text>{t.text}</Text>
      </Text>,
    ];
  }
  if (t.kind === "system") {
    const color =
      t.tone === "err" ? theme.err
      : t.tone === "warn" ? theme.warn
      : t.tone === "ok" ? theme.ok
      : theme.dim;
    return [
      <Text key={k("s")} wrap="truncate-end" color={color}>
        · {t.text}
      </Text>,
    ];
  }
  // assistant
  if (t.status === "pending") {
    return [
      <Text key={k("p")} wrap="truncate-end" color={theme.dim}>
        {"› le chat  "}
        <Spinner type="dots" /> drafting…
      </Text>,
    ];
  }
  if (t.error) {
    return [
      <Text key={k("e")} wrap="truncate-end" color={theme.err}>
        {"› le chat  ✗ "}
        {t.error}
      </Text>,
    ];
  }
  const r = t.result;
  if (!r) return [];
  const lines: React.ReactElement[] = [
    <Text key={k("h")} wrap="truncate-end">
      <Text color={theme.ok} bold>{"› le chat  "}</Text>
      <Text>{r.intentActionTag ? friendlyAction(r.intentActionTag) : (r.regex?.action ?? "answer")}</Text>
    </Text>,
  ];
  if (r.modelAsk) {
    lines.push(
      <Text key={k("ask")} wrap="truncate-end" color={theme.warn}>
        {"  ? "}
        {r.modelAsk.question}
      </Text>,
    );
  }
  const firstErr = r.llmError ?? r.validateError ?? r.encodeError;
  if (firstErr) {
    lines.push(
      <Text key={k("err")} wrap="truncate-end" color={theme.err}>
        {"  ✗ "}
        {firstErr}
      </Text>,
    );
  }
  if (r.canonical) {
    const head = r.canonical.split("\n")[0] ?? "";
    lines.push(
      <Text key={k("can")} wrap="truncate-end" color={theme.ok}>
        {"  ⊢ "}
        {head}
      </Text>,
    );
  }
  if (r.encoded && isLatestSignable) {
    lines.push(
      <Text key={k("sig")} wrap="truncate-end" color={theme.dim}>
        {"  ↳ draft ready — confirm screen shows decoded action + simulation before any signature"}
      </Text>,
    );
  }
  const d = t.dispatch;
  if (d && d.kind !== "idle") {
    const text =
      d.kind === "running" ? "⠿ dispatching…"
      : d.kind === "auditDone" ? `✓ audit: ${d.data.approvals.length} approval(s)`
      : d.kind === "prepareDone" ? `✓ prepared ${d.txs.length} tx(s) — first queued via ConfirmGate`
      : d.kind === "createHandedOff" ? `↳ handed off to ${d.walletKind} creation flow`
      : `✗ ${d.message}`;
    const color =
      d.kind === "error" ? theme.err : d.kind === "running" ? theme.primary : theme.ok;
    lines.push(
      <Text key={k("d")} wrap="truncate-end" color={color}>
        {"  "}
        {text}
      </Text>,
    );
  }
  if (r.agentTrace && r.agentTrace.length > 0) {
    const calls = r.agentTrace.filter((x) => x.kind === "tool_call").length;
    lines.push(
      <Text key={k("tr")} wrap="truncate-end" color={theme.dim}>
        {"  ▸ "}
        {calls} tool call{calls === 1 ? "" : "s"} · ctrl+o for the full trace
      </Text>,
    );
  }
  return lines;
}
