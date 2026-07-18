import React, { useEffect, useRef } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import { call, isCancelled } from "../daemon.js";
import { theme } from "../theme.js";
import { approvalAuditRows, type ApprovalAuditData } from "../format.js";
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
  planContinuation,
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
  /** Writable iff the chat pane has been ENTERED for typing (Enter on the
   *  highlighted chat pane). When false the input is dormant (an
   *  "(enter to type)" placeholder) so the footer hints and other panes'
   *  shortcuts keep the keyboard. */
  isFocused: boolean;
  /** Content line budget (pane height minus border/title rows). */
  contentHeight: number;
  /** Show the welcome-state Kohaku koi. The dashboard sets this only when
   *  chat occupies the MAIN pane — a demoted side-column chat suppresses
   *  it so the koi is the main pane's identity cue, not a side decoration.
   *  Defaults to true (full-screen le-chat keeps the koi). */
  showKoi?: boolean;
  modelName?: string;
  onApprove?: (
    tx: { to: string; value: string; data: string; rationale?: string; canonical?: string },
    chainId: number,
    wallet?: { kind: "eoa" | "sphincs"; name: string; address: string },
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
  showKoi = true,
  modelName,
  onApprove,
  onCreateWallet,
  onOpenFull,
  onOpenHistory,
}: Props) {
  // In-flight `chat.draft` cancellation. Each draft (and the continuation
  // round) installs a fresh AbortController here; Esc-to-stop aborts it,
  // which tears down the daemon socket so the TUI stops waiting. The
  // daemon-side generation keeps running in the background — we just
  // reclaim the chat (see daemon.ts onAbort).
  const draftAbort = useRef<AbortController | null>(null);

  // Stop the in-flight draft: abort the socket, drop `busy`, leave a marker,
  // and rotate the sessionKey so the next prompt opens a clean agentd
  // session instead of interleaving with the abandoned one (same rationale
  // as `/clear`'s rotation). No-op when nothing is in flight.
  const stopDraft = () => {
    draftAbort.current?.abort();
    draftAbort.current = null;
    setPhase((p) => {
      if (p.kind !== "chat" || !p.busy) return p;
      const turns = [...p.turns];
      // Replace the trailing pending assistant turn (if any) with the marker
      // so we don't leave a forever-spinning "drafting…" row behind.
      if (turns.length > 0 && turns[turns.length - 1]?.kind === "assistant"
          && (turns[turns.length - 1] as Extract<Turn, { kind: "assistant" }>).status === "pending") {
        turns.pop();
      }
      turns.push({ kind: "system", tone: "warn", text: "⏹ stopped — generation still finishing in the background" });
      return { ...p, turns, busy: false, sessionKey: newSessionKey(), pendingContinuation: undefined };
    });
  };

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
    // planContinuation re-issues the original prompt ONLY for a deterministic
    // multi-leg approval leg (swap/Aave); null for any other completed action
    // so we never fire a stale-context "propose the next step" round (see
    // planContinuation). On null, disarm the trigger — the broadcast
    // confirmation is already in the conversation.
    const plan = planContinuation(phase.turns, receiptParts.join(" · "));
    if (!plan) {
      setPhase({ ...phase, pendingContinuation: undefined });
      return;
    }
    const { prompt, statusText } = plan;
    const history = buildChatHistory(phase.turns);
    const turnsAfter: Turn[] = [
      ...phase.turns,
      { kind: "system", tone: "info", text: statusText },
      { kind: "assistant", status: "pending" },
    ];
    setPhase({ ...phase, turns: turnsAfter, busy: true, pendingContinuation: undefined });
    let cancelled = false;
    const ac = new AbortController();
    draftAbort.current = ac;
    (async () => {
      const r = await call<DraftResponse>(
        "chat.draft",
        { prompt, chainId: phase.chainId, sessionKey: phase.sessionKey, history },
        { timeoutMs: 300_000, signal: ac.signal },
      );
      if (draftAbort.current === ac) draftAbort.current = null;
      // Esc-to-stop already finalized the turns; don't clobber the marker.
      if (cancelled || (!r.ok && isCancelled(r.error))) return;
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
  // conversation moves with you). Esc while a draft is in flight stops it
  // (the dashboard yields Esc to us during chat-busy — see Dashboard.tsx).
  // Both gated on pane focus.
  useInput(
    (ch, key) => {
      if (key.ctrl && ch === "o") onOpenFull?.();
      if (key.escape && phase.kind === "chat" && phase.busy) stopDraft();
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
      t.kind === "assistant" && t.status === "done" && !!t.result?.encoded && !t.signed,
  );
  const latestExecutable = [...turns].reverse().find(
    (t): t is Extract<Turn, { kind: "assistant" }> => {
      if (t.kind !== "assistant" || t.status !== "done") return false;
      const r = t.result;
      if (!r || !(r.prepare || r.audit || r.create)) return false;
      return !t.dispatch || t.dispatch.kind === "idle";
    },
  );

  // Address the turn by INDEX, never by object identity: setting the
  // "running" state REPLACES the turn object in state, so a completion
  // update that searched by `indexOf(originalTurn)` could never find it
  // again and silently no-op'd — the dispatch spinner stayed "running"
  // forever no matter what the daemon answered. Turns are append-only
  // within a chat phase, so an index captured at dispatch time stays
  // valid; a `/clear` resets the phase and the guard below drops the
  // stale update harmlessly.
  const updateTurnDispatchAt = (idx: number, next: DispatchState) =>
    setPhase((p) => {
      if (p.kind !== "chat") return p;
      const target = p.turns[idx];
      if (!target || target.kind !== "assistant") return p;
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
    // Capture the index NOW (the `turn` object came from this render's
    // state, so identity still holds here — and never again after the
    // first dispatch update replaces it).
    const idx = phase.kind === "chat" ? phase.turns.indexOf(turn) : -1;
    if (idx < 0) return;
    const setDispatch = (next: DispatchState) => updateTurnDispatchAt(idx, next);
    setDispatch({ kind: "running" });
    try {
      if (r.audit) {
        // Full-history first scan takes ~30-90s per wallet (activity-anchored
        // chunked log sweep); later audits are incremental off the daemon's
        // per-owner cache and return in seconds. Same 300s cap as prepare.
        const resp = await call<AuditResult>(r.audit.rpc, r.audit.params, { timeoutMs: 300_000 });
        setDispatch(
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
          setDispatch({ kind: "error", message: resp.error.message });
          return;
        }
        const txs = (resp.result.txs ?? resp.result.transactions ?? []) as PreparedTx[];
        setDispatch({ kind: "prepareDone", txs });
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
          setDispatch({
            kind: "error",
            message: "wallet creation flow not wired; use the main menu",
          });
          return;
        }
        const kind = r.create.params.kind;
        onCreateWallet(kind, r.create.params.label);
        setDispatch({ kind: "createHandedOff", walletKind: kind, label: r.create.params.label });
      }
    } catch (e) {
      // Transport-level throw: always surface — the spinner must never
      // be left in "running" with no path out.
      setDispatch({ kind: "error", message: e instanceof Error ? e.message : String(e) });
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
    const ac = new AbortController();
    draftAbort.current = ac;
    const r = await call<DraftResponse>(
      "chat.draft",
      { prompt: text, chainId: phase.chainId, sessionKey: phase.sessionKey, history },
      { timeoutMs: 300_000, signal: ac.signal },
    );
    if (draftAbort.current === ac) draftAbort.current = null;
    // Esc-to-stop already rewrote the turns + dropped busy; bail.
    if (!r.ok && isCancelled(r.error)) return;
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
  const allLines = turns.flatMap((t, i) => turnToLines(t, i, t === latestSignable, wallets));
  const dropped = Math.max(0, allLines.length - transcriptBudget + (allLines.length > transcriptBudget ? 1 : 0));
  const visible = dropped > 0 ? allLines.slice(allLines.length - (transcriptBudget - 1)) : allLines;

  // The koi is the pane's identity cue: render it whenever chat owns the
  // main slot (showKoi) and the pane is tall enough for the 24×12 fish.
  // NOT gated on `turns.length === 0` — see the persistent rail below.
  const koiVisible = showKoi && contentHeight >= 14;

  // Everything except the koi rail: status row, then the welcome examples
  // (empty conversation) or the windowed transcript, then affordance +
  // input. Sits to the RIGHT of the koi when the rail is shown.
  const body = (
    <Box flexDirection="column" flexGrow={1} minWidth={0}>
      <Text wrap="truncate-end" color={theme.dim}>
        {phase.modelName ?? modelName ?? "local model"} · {phase.chainName} ({phase.chainId})
        {phase.busy ? " · " : ""}
        {phase.busy && (
          <Text color={theme.primary}>
            <Spinner type="dots" /> thinking… <Text color={theme.dim}>(esc to stop)</Text>
          </Text>
        )}
      </Text>
      {turns.length === 0 ? (
        // Welcome state: the koi (rail, below) carries the identity, so the
        // richer header only appears when that rail is present; otherwise
        // fall back to a bare examples list that fits a short pane.
        koiVisible ? (
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
                {"  "}<Text color={theme.primary}>swap 0.1 ETH to fxUSD</Text>
              </Text>
              <Text wrap="truncate-end" color={theme.dim}>
                {"  "}<Text color={theme.primary}>approve 100 fxUSD for vitalik.eth</Text>
              </Text>
            </Box>
          </Box>
        ) : (
          <Box flexDirection="column">
            <Text color={theme.dim}>Examples:</Text>
            <Text wrap="truncate-end" color={theme.dim}>
              {"  "}<Text color={theme.primary}>send 0.001 ETH to niard.eth</Text>
            </Text>
            <Text wrap="truncate-end" color={theme.dim}>
              {"  "}<Text color={theme.primary}>swap 0.1 ETH to fxUSD</Text>
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
            {phase.input.length > 0 ? phase.input : "(enter to type)"}
          </Text>
        )}
      </Box>
    </Box>
  );

  // Persistent koi rail. The koi is the main pane's identity cue, so it
  // STAYS for the whole session — welcome state and an active conversation
  // alike — instead of vanishing after the first request (the old behaviour
  // gated it on an empty transcript). Vertical windowing is unchanged: the
  // koi is a fixed 24×12 column beside `body`, which still gets the full
  // contentHeight. Dropped only when the pane is demoted to a side column
  // (showKoi=false) or is too short for the fish (contentHeight < 14).
  if (!koiVisible) return body;
  return (
    <Box flexDirection="row">
      <Box width={24} minWidth={24} height={12} flexShrink={0} marginRight={2}>
        <AnimatedKoi size="tiny" />
      </Box>
      {body}
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
  wallets: Array<{ name: string; address: string }> = [],
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
  // Head label: a friendly action name for a drafted intent, else the
  // model's plain-text answer, else a neutral dash. Deliberately NOT the
  // raw regex action ("swap" / "unknown") — that read as a cryptic
  // one-word reply with no explanation.
  const head =
    r.intentActionTag ? friendlyAction(r.intentActionTag)
    : (r.llmRaw && r.llmRaw.trim().length > 0) ? r.llmRaw.trim()
    : "—";
  const lines: React.ReactElement[] = [
    <Text key={k("h")} wrap="truncate-end">
      <Text color={theme.ok} bold>{"› le chat  "}</Text>
      <Text>{head}</Text>
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
  const firstErr = r.swapError ?? r.llmError ?? r.validateError ?? r.encodeError;
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
        {"  ↳ ready to sign: "}
        {friendlyAction(r.intentActionTag)}
        {" — confirm screen shows the full decode + simulation before any signature"}
      </Text>,
    );
  }
  const d = t.dispatch;
  if (d && d.kind !== "idle") {
    const text =
      d.kind === "running"
        ? r.audit
          ? "⠿ scanning approval history… (first scan per wallet ≈ 1 min; cached after)"
          : "⠿ dispatching…"
      : d.kind === "auditDone" ? `✓ audit: ${d.data.approvals.length + (d.data.nftApprovals?.length ?? 0) + (d.data.permit2Approvals?.length ?? 0)} approval(s)`
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
    // Inline audit results: riskiest rows first, capped for the pane —
    // the full chat (ctrl+o) has the complete list with block heights.
    if (d.kind === "auditDone") {
      const rows = approvalAuditRows(d.data as ApprovalAuditData, wallets);
      const shown = rows.slice(0, 8);
      shown.forEach((row, ri) =>
        lines.push(
          <Text key={k(`ar${ri}`)} wrap="truncate-end" color={row.warn ? theme.warn : theme.dim}>
            {"    "}
            {row.text}
          </Text>,
        ),
      );
      if (rows.length > shown.length)
        lines.push(
          <Text key={k("armore")} wrap="truncate-end" color={theme.dim}>
            {"    "}… {rows.length - shown.length} more — ctrl+o for the full list
          </Text>,
        );
      if (rows.length > 0)
        lines.push(
          <Text key={k("arhint")} wrap="truncate-end" color={theme.dim}>
            {"    "}↳ revoke one: {`"revoke ${d.data.approvals[0]?.tokenSymbol || "<token>"} for <spender address>"`}
          </Text>,
        );
    }
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
