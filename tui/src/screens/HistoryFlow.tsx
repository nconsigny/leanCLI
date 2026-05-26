import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import Select, { SelectItem } from "../widgets/Select.js";
import { KoiFrame } from "../widgets/KoiFrame.js";
import {
  chatGetSession,
  chatListProposedTxs,
  chatListSessions,
  ProposedTxEntry,
  SessionListEntry,
  SessionTurn,
} from "../daemon.js";
import { theme } from "../theme.js";

/**
 * Read-only "le Chat history" screen.
 *
 * Two tabs:
 *   - Sessions:   reverse-chronological list of chat sessions. Enter
 *                 opens a session-detail view that replays each turn
 *                 (assistant prose, indented tool calls + result
 *                 summaries, reasoning under "thinking:") and the
 *                 footer reminds the user this is read-only.
 *   - Transactions: every `propose_send` call across all sessions,
 *                   newest-first, with a detail panel that shows the
 *                   full to / value / data / sender / summary and a
 *                   "Jump to session" affordance.
 *
 * Trust contract: every wire shape comes from the agentd's read-only
 * ops (`list_sessions`, `get_session`, `list_proposed_txs`). The TUI
 * NEVER re-signs from this screen. To re-execute a tx, the user has
 * to copy calldata into `kohaku tx send-raw` (or similar) — outside
 * the scope of this surface. Incognito sessions are filtered out at
 * the agentd level; they never reach this view.
 */

type Tab = "sessions" | "transactions";

/** TUI-side view of one assistant `tool_calls` entry. The agentd
 *  stores the array as a compact JSON string on disk; we parse it
 *  defensively (older rows or partial writes can be malformed). */
type ParsedToolCall = {
  id: string;
  name: string;
  argsJson: string;
};

/** Display-only cap on calldata in the propose_send detail panel.
 *  Matches the spec ("calldata first 200 chars"). Longer payloads
 *  surface with a trailing ellipsis + byte-count marker. */
const CALLDATA_DETAIL_CAP = 200;

/** Cap on inline tool-call argsJson in the session-detail trace,
 *  mirroring `LlmChatFlow.tsx`'s `clip` budget for the live trace
 *  block. */
const TRACE_ARGS_CAP = 80;

/** Best-effort parse for a `tool_calls` JSON column. Returns an empty
 *  array when the column is empty or malformed; the agentd's writer is
 *  the only producer today but historical rows may carry a different
 *  shape. */
function parseToolCalls(raw: string | undefined): ParsedToolCall[] {
  if (!raw) return [];
  try {
    const v = JSON.parse(raw);
    if (!Array.isArray(v)) return [];
    return v
      .map((x: unknown) => {
        if (!x || typeof x !== "object") return null;
        const o = x as Record<string, unknown>;
        return {
          id: typeof o.id === "string" ? o.id : "",
          name: typeof o.name === "string" ? o.name : "",
          argsJson: typeof o.argsJson === "string" ? o.argsJson : "",
        };
      })
      .filter((x): x is ParsedToolCall => x !== null && x.name.length > 0);
  } catch {
    return [];
  }
}

/** Best-effort extract of a `summary` field from a tool-result row's
 *  `content` JSON. Falls back to the raw content when parsing fails or
 *  the field is absent — same forgiveness rule as the agentd's walker. */
function summaryFromToolContent(content: string): string {
  if (!content) return "";
  try {
    const v = JSON.parse(content);
    if (v && typeof v === "object") {
      const s = (v as Record<string, unknown>).summary;
      if (typeof s === "string") return s;
    }
  } catch {
    // fall through
  }
  return content;
}

function shortDate(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return "?";
  try {
    const d = new Date(ms);
    // YYYY-MM-DD HH:MM in local time. Sortable + glanceable.
    const pad = (n: number) => n.toString().padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  } catch {
    return "?";
  }
}

function shortAddr(s: string | undefined): string {
  if (!s) return "?";
  if (s.length <= 12) return s;
  return `${s.slice(0, 8)}…${s.slice(-4)}`;
}

function clip(s: string, n: number): string {
  if (s.length <= n) return s;
  return s.slice(0, n) + "…";
}

function calldataPreview(data: string): string {
  if (!data) return "0x";
  if (data.length <= 14) return data;
  return data.slice(0, 14) + "…";
}

function calldataDetail(data: string): string {
  if (!data) return "0x";
  if (data.length <= CALLDATA_DETAIL_CAP) return data;
  // Byte-count marker borrowed from `Trace.truncateForTrace`'s shape so
  // the cap reason is obvious at a glance.
  const bytes = Math.max(0, (data.length - 2) / 2);
  return data.slice(0, CALLDATA_DETAIL_CAP) + `…[${bytes} bytes]`;
}

type Props = {
  onDone: () => void;
};

/** Top-level state machine for the history screen. Mirrors the
 *  Sessions / Transactions tab toggle as a sum type so the renderer
 *  doesn't have to coordinate ad-hoc booleans. */
type Mode =
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "fatal"; message: string }
  | {
      kind: "ready";
      tab: Tab;
      sessions: SessionListEntry[];
      txs: ProposedTxEntry[];
      // When set, the Sessions tab is showing detail for this session id.
      sessionDetail?: SessionDetailState;
      // Index of the expanded propose_send in `txs` (Transactions tab).
      expandedTxIndex?: number;
    };

type SessionDetailState =
  | { kind: "loading"; sessionId: number }
  | { kind: "incognito"; sessionId: number }
  | { kind: "error"; sessionId: number; message: string }
  | {
      kind: "loaded";
      sessionId: number;
      createdAt: number;
      chainId?: number;
      sessionKey?: string;
      turns: SessionTurn[];
    };

export default function HistoryFlow({ onDone }: Props) {
  const [mode, setMode] = useState<Mode>({ kind: "loading" });

  // Initial load: fetch both tabs' data in parallel so tab-toggling is
  // instant once we're past the boot screen. Either failing is a hard
  // error (the persistent agent socket is the only source); the TUI
  // renders the message so the user sees the actionable cause.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [s, t] = await Promise.all([
        chatListSessions({ limit: 100 }),
        chatListProposedTxs({ limit: 100 }),
      ]);
      if (cancelled) return;
      if (!s.ok) {
        const m = s.error.message;
        // -32601 = "history available only in persistent mode" — set
        // a clearer headline so the user knows why this is empty.
        if (s.error.code === -32601 || /persistent mode/.test(m)) {
          setMode({
            kind: "fatal",
            message:
              "Chat history is only available when the persistent agent daemon (kohaku-agentd) is running. " +
              "Start it via your systemd user unit (or `kohaku-agentd &`) and reopen this screen.",
          });
          return;
        }
        setMode({ kind: "error", message: `chat.listSessions failed: ${m}` });
        return;
      }
      if (!t.ok) {
        setMode({
          kind: "error",
          message: `chat.listProposedTxs failed: ${t.error.message}`,
        });
        return;
      }
      setMode({
        kind: "ready",
        tab: "sessions",
        sessions: s.result.sessions ?? [],
        txs: t.result.txs ?? [],
      });
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // Global keys. Esc returns to chat from any sub-state EXCEPT the
  // session-detail view (where it returns to the session list first).
  useInput((input, key) => {
    if (mode.kind !== "ready") {
      if (key.escape) onDone();
      return;
    }
    // Inside session detail: Esc returns to the list, NOT to chat.
    // This mirrors the existing convention (one Esc unwinds one
    // layer of UI state).
    if (mode.sessionDetail) {
      if (key.escape) {
        setMode({ ...mode, sessionDetail: undefined });
      }
      return;
    }
    // Inside an expanded tx panel: Esc collapses it (rather than
    // leaving the screen) so the user can re-fold without losing
    // their list position.
    if (mode.expandedTxIndex !== undefined) {
      if (key.escape) {
        setMode({ ...mode, expandedTxIndex: undefined });
      }
      return;
    }
    if (key.escape) {
      onDone();
      return;
    }
    // Tab toggle: s/t letters, plus arrow-left/right. Letters are
    // captured globally (not via the Select widget) so they work on
    // both tabs.
    if (input === "s" && mode.tab !== "sessions") {
      setMode({ ...mode, tab: "sessions", expandedTxIndex: undefined });
      return;
    }
    if (input === "t" && mode.tab !== "transactions") {
      setMode({ ...mode, tab: "transactions", sessionDetail: undefined });
      return;
    }
    if (key.leftArrow || key.rightArrow) {
      const next: Tab = mode.tab === "sessions" ? "transactions" : "sessions";
      setMode({
        ...mode,
        tab: next,
        sessionDetail: next === "sessions" ? mode.sessionDetail : undefined,
        expandedTxIndex: next === "transactions" ? mode.expandedTxIndex : undefined,
      });
      return;
    }
  });

  // Open a session-detail subview from either tab.
  const openSession = (sessionId: number) => {
    if (mode.kind !== "ready") return;
    setMode({
      ...mode,
      tab: "sessions",
      sessionDetail: { kind: "loading", sessionId },
    });
    (async () => {
      const r = await chatGetSession(sessionId);
      if (!r.ok) {
        // Detect the agentd's structured `kind:"incognito"` envelope —
        // it travels through the bridge as a -32000 error whose
        // `data.kind` field carries the tag.
        const dataKind = (() => {
          // The wallet daemon's error.data may be a JSON-stringified
          // object inside the message (callOnce appends data via
          // `JSON.stringify(err.data)`); we both check direct match and
          // a substring fallback.
          if (/incognito/i.test(r.error.message)) return "incognito";
          return undefined;
        })();
        setMode((prev) =>
          prev.kind === "ready"
            ? {
                ...prev,
                sessionDetail:
                  dataKind === "incognito"
                    ? { kind: "incognito", sessionId }
                    : { kind: "error", sessionId, message: r.error.message },
              }
            : prev,
        );
        return;
      }
      setMode((prev) =>
        prev.kind === "ready"
          ? {
              ...prev,
              sessionDetail: {
                kind: "loaded",
                sessionId,
                createdAt: r.result.createdAt,
                chainId: r.result.chainId,
                sessionKey: r.result.sessionKey,
                turns: r.result.turns ?? [],
              },
            }
          : prev,
      );
    })();
  };

  if (mode.kind === "loading") {
    return (
      <Container>
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          loading chat history…
        </Text>
      </Container>
    );
  }
  if (mode.kind === "fatal" || mode.kind === "error") {
    return (
      <Container>
        <Text color={theme.err}>{mode.message}</Text>
        <Box marginTop={1}>
          <Text color={theme.dim}>esc — back to chat</Text>
        </Box>
      </Container>
    );
  }

  if (mode.sessionDetail) {
    return (
      <Container>
        <TabBar tab="sessions" />
        <SessionDetail state={mode.sessionDetail} />
        <Footer detail />
      </Container>
    );
  }

  return (
    <Container>
      <TabBar tab={mode.tab} />
      {mode.tab === "sessions" ? (
        <SessionsList
          sessions={mode.sessions}
          onOpen={openSession}
        />
      ) : (
        <TransactionsList
          txs={mode.txs}
          expandedIndex={mode.expandedTxIndex}
          onExpand={(idx) =>
            setMode({
              ...mode,
              expandedTxIndex: idx === mode.expandedTxIndex ? undefined : idx,
            })
          }
          onJumpToSession={(sid) => openSession(sid)}
        />
      )}
      <Footer />
    </Container>
  );
}

/* ---------- Layout chrome ---------- */

function Container({ children }: { children: React.ReactNode }) {
  return (
    <Box flexDirection="column" paddingX={1}>
      <KoiFrame>
        <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
          {" le chat · history "}
        </Text>
        <Text color={theme.dim}>read-only · replay only · no resume from this screen</Text>
      </KoiFrame>
      <Box marginTop={1} flexDirection="column">
        {children}
      </Box>
    </Box>
  );
}

function TabBar({ tab }: { tab: Tab }) {
  return (
    <Box>
      <Text color={tab === "sessions" ? theme.primary : theme.dim} bold>
        {tab === "sessions" ? "▶ Sessions " : "  Sessions "}
      </Text>
      <Text color={tab === "transactions" ? theme.primary : theme.dim} bold>
        {tab === "transactions" ? "▶ Transactions" : "  Transactions"}
      </Text>
    </Box>
  );
}

function Footer({ detail }: { detail?: boolean }) {
  return (
    <Box marginTop={1}>
      <Text color={theme.dim}>
        {detail
          ? "esc — back to list"
          : "s/t — switch tab · ↑↓ — move · enter — open · esc — back to chat"}
      </Text>
    </Box>
  );
}

/* ---------- Sessions tab ---------- */

function SessionsList({
  sessions,
  onOpen,
}: {
  sessions: SessionListEntry[];
  onOpen: (sessionId: number) => void;
}) {
  if (sessions.length === 0) {
    return (
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.dim}>No sessions on record yet.</Text>
        <Text color={theme.dim}>
          Open a chat from the main menu and ask "le chat" a question; sessions
          appear here once the agent daemon writes them to disk.
        </Text>
      </Box>
    );
  }
  const items: SelectItem<SessionListEntry>[] = sessions.map((s) => {
    const date = shortDate(s.createdAt);
    const chain =
      typeof s.chainId === "number" ? `chain ${s.chainId}` : "chain ?";
    const prompt = s.firstUserPrompt ?? "(no user prompt)";
    return {
      label: `[${date}] [${chain}] ${prompt} · ${s.turnCount} turn${s.turnCount === 1 ? "" : "s"}`,
      value: s,
      key: `s-${s.sessionId}`,
    };
  });
  return (
    <Box marginTop={1} flexDirection="column">
      <Select
        items={items}
        onSelect={(it) => onOpen(it.value.sessionId)}
      />
    </Box>
  );
}

function SessionDetail({ state }: { state: SessionDetailState }) {
  if (state.kind === "loading") {
    return (
      <Box marginTop={1}>
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          loading session #{state.sessionId}…
        </Text>
      </Box>
    );
  }
  if (state.kind === "incognito") {
    return (
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.warn}>
          Session #{state.sessionId} was incognito — no rows were stored on
          disk, so there is nothing to replay.
        </Text>
      </Box>
    );
  }
  if (state.kind === "error") {
    return (
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.err}>session #{state.sessionId}: {state.message}</Text>
      </Box>
    );
  }
  // loaded
  return (
    <Box marginTop={1} flexDirection="column">
      <Box>
        <Text color={theme.primary} bold>
          session #{state.sessionId}
        </Text>
        <Text color={theme.dim}>
          {"  "}created {shortDate(state.createdAt)} ·{" "}
          {typeof state.chainId === "number" ? `chain ${state.chainId}` : "chain ?"}
          {state.sessionKey ? ` · key ${shortKey(state.sessionKey)}` : ""} ·{" "}
          {state.turns.length} turn{state.turns.length === 1 ? "" : "s"}
        </Text>
      </Box>
      <Box marginTop={1} flexDirection="column" borderStyle="single" borderColor={theme.dim} paddingX={1}>
        {state.turns.length === 0 ? (
          <Text color={theme.dim}>(session has no stored turns)</Text>
        ) : (
          state.turns.map((t, i) => <TurnRow key={i} turn={t} />)
        )}
      </Box>
    </Box>
  );
}

function shortKey(k: string): string {
  if (k.length <= 12) return k;
  return `${k.slice(0, 8)}…${k.slice(-4)}`;
}

function TurnRow({ turn }: { turn: SessionTurn }) {
  const calls = parseToolCalls(turn.toolCallsJson);
  if (turn.role === "user") {
    return (
      <Box flexDirection="column" marginBottom={1}>
        <Text color={theme.primary} bold>
          › you
        </Text>
        <Box paddingLeft={2}>
          <Text>{turn.content || "(empty)"}</Text>
        </Box>
      </Box>
    );
  }
  if (turn.role === "assistant") {
    return (
      <Box flexDirection="column" marginBottom={1}>
        <Box>
          <Text color={theme.ok} bold>
            › le chat
          </Text>
          <Text color={theme.dim}>{"  "}seq {turn.seq}</Text>
        </Box>
        {turn.content && (
          <Box paddingLeft={2}>
            <Text>{turn.content}</Text>
          </Box>
        )}
        {calls.length > 0 && (
          <Box flexDirection="column" paddingLeft={2}>
            {calls.map((c, i) => (
              <Text key={i} color={theme.primary}>
                → {c.name}({clip(c.argsJson, TRACE_ARGS_CAP)})
              </Text>
            ))}
          </Box>
        )}
      </Box>
    );
  }
  if (turn.role === "tool") {
    const summary = summaryFromToolContent(turn.content);
    return (
      <Box flexDirection="column" marginBottom={1}>
        <Box paddingLeft={2}>
          <Text color={theme.dim}>
            ← {turn.toolCallId ? `[${turn.toolCallId.slice(0, 8)}] ` : ""}
            {clip(summary || "(empty)", 200)}
          </Text>
        </Box>
      </Box>
    );
  }
  if (turn.role === "system") {
    return (
      <Box marginBottom={1}>
        <Text color={theme.dim}>· system: {clip(turn.content || "(empty)", 200)}</Text>
      </Box>
    );
  }
  return (
    <Box marginBottom={1}>
      <Text color={theme.dim}>
        · {turn.role}: {clip(turn.content || "(empty)", 200)}
      </Text>
    </Box>
  );
}

/* ---------- Transactions tab ---------- */

function TransactionsList({
  txs,
  expandedIndex,
  onExpand,
  onJumpToSession,
}: {
  txs: ProposedTxEntry[];
  expandedIndex: number | undefined;
  onExpand: (idx: number) => void;
  onJumpToSession: (sessionId: number) => void;
}) {
  if (txs.length === 0) {
    return (
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.dim}>
          No propose_send calls on record yet.
        </Text>
        <Text color={theme.dim}>
          Any signing draft the agent produced via the chat flow appears here once
          the session is persisted.
        </Text>
      </Box>
    );
  }
  // Currently expanded row carries its own affordances (Jump to session)
  // via a keyboard handler at the row level.
  return (
    <Box marginTop={1} flexDirection="column">
      <Select
        items={txs.map((p, i) => ({
          label: txRowLabel(p, i === expandedIndex),
          value: { p, i },
          key: `tx-${p.sessionId}-${p.turnIndex}-${i}`,
        }))}
        onSelect={(it) => onExpand(it.value.i)}
      />
      {expandedIndex !== undefined && txs[expandedIndex] && (
        <TxDetail
          tx={txs[expandedIndex]!}
          onJumpToSession={() => onJumpToSession(txs[expandedIndex]!.sessionId)}
        />
      )}
    </Box>
  );
}

function txRowLabel(p: ProposedTxEntry, expanded: boolean): string {
  const date = shortDate(p.ts);
  const chain = `chain ${p.chainId}`;
  const sender = shortAddr(p.sender);
  const to = shortAddr(p.to);
  const value = p.value || "0";
  const dataPrev = calldataPreview(p.data);
  const marker = expanded ? "▾" : "▸";
  return `${marker} [${date}] [${chain}] ${sender} → ${to} · ${value} · ${dataPrev}`;
}

function TxDetail({
  tx,
  onJumpToSession,
}: {
  tx: ProposedTxEntry;
  onJumpToSession: () => void;
}) {
  // Use an input handler scoped here so Enter on the detail panel
  // triggers the jump-to-session affordance without colliding with
  // the Select widget's own Enter handler (the Select consumed Enter
  // to expand this panel; once expanded, Enter has a new meaning).
  useInput((_input, key) => {
    if (key.return) onJumpToSession();
  });
  return (
    <Box marginTop={1} flexDirection="column" borderStyle="single" borderColor={theme.dim} paddingX={1}>
      <Text color={theme.primary} bold>
        propose_send · session #{tx.sessionId} turn {tx.turnIndex}
      </Text>
      <Text color={theme.dim}>
        proposed {shortDate(tx.ts)} · session created {shortDate(tx.sessionCreatedAt)}
      </Text>
      <Box marginTop={1} flexDirection="column">
        <Text>
          <Text color={theme.dim}>chainId  </Text>
          {tx.chainId}
        </Text>
        <Text>
          <Text color={theme.dim}>to       </Text>
          {tx.to || "?"}
        </Text>
        <Text>
          <Text color={theme.dim}>value    </Text>
          {tx.value || "0"}
        </Text>
        <Text>
          <Text color={theme.dim}>sender   </Text>
          {tx.sender ?? "(not recorded)"}
        </Text>
        <Text>
          <Text color={theme.dim}>data     </Text>
          {calldataDetail(tx.data)}
        </Text>
        {tx.summaryFromTool && (
          <Box flexDirection="column" marginTop={1}>
            <Text color={theme.dim}>summary (from tool result):</Text>
            <Text>{clip(tx.summaryFromTool, 400)}</Text>
          </Box>
        )}
      </Box>
      <Box marginTop={1}>
        <Text color={theme.primary} bold>
          ▶ enter — jump to session #{tx.sessionId}
        </Text>
        <Text color={theme.dim}>
          {"   "}esc — collapse panel
        </Text>
      </Box>
    </Box>
  );
}
