import React, { useEffect, useRef, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import Select, { SelectItem } from "../widgets/Select.js";
import { KoiFrame } from "../widgets/KoiFrame.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { formatEth, hexToBigInt } from "../format.js";

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
    /** Optional pre-selected signing wallet derived from the regex
     *  draft's `from` field. Set when the user wrote
     *  "approve … from leanWallet" (or any phrasing the RuleParser
     *  recognises). SendRawFlow's picker is skipped when present. */
    wallet?: { kind: "eoa" | "tpm"; name: string; address: string },
  ) => void;
  /** Routes an `address.fresh` directive to the existing wallet-creation
   *  flow. Parent navigates to CreateEoaFlow (kind="eoa") or
   *  CreateR1Flow (kind="r1") with the label pre-known. The chat does
   *  NOT dispatch eoa.create / tpm.create directly because those RPCs
   *  need a passphrase / TPM PIN prompt that the existing flow already
   *  handles correctly (with confirm + masking). */
  onCreateWallet?: (kind: "eoa" | "r1", label: string | undefined) => void;
};

type OwnershipStatus =
  | "verified"
  | "locked"
  | "hardware"
  | "book"
  | "external"
  | "mismatch";

type OwnershipEntry = {
  key: string;
  address: string;
  status: OwnershipStatus;
  derivationPath?: string;
  derived?: string;
};

/** One entry in the agent's per-turn trace. Matches the JSON shape
 *  produced by `LeanKohaku.Agent.Trace.toJson`. Display-only — never
 *  gates signing. The TUI's foldable trace block under each assistant
 *  turn is the only consumer; the agent loop's own correctness is
 *  unaffected by what we render (or don't render) here. */
type TraceItem =
  | { kind: "assistant"; content: string; reasoning?: string }
  | { kind: "tool_call"; idx: number; name: string; argsJson: string }
  | { kind: "tool_result"; idx: number; ok: boolean; summary: string };

type DraftResponse = {
  regex?: {
    action: string;
    fields: { k: string; v: string }[];
    unresolved: string[];
    confidence: string;
    ownerships?: OwnershipEntry[];
  };
  llmRaw?: string;
  llmError?: string;
  intentActionTag?: string;
  canonical?: string;
  validateError?: string;
  /** Per-turn observability payload from `kohaku-agentd`. Optional;
   *  legacy / one-shot bridge replies omit it and the trace block
   *  simply doesn't render. */
  agentTrace?: TraceItem[];
  // Standard leaf-encodable response — model emits a tx-shaped Intent
  // and the daemon's encoder returns the {to, value, data} the TUI
  // routes through tx.simulate + ConfirmGate.
  encoded?: { to: string; value: number; data: string; chainId: number; sender?: string };
  encodeError?: string;
  modelAsk?: { error: string; question: string };
  // New non-tx-encoded action directives. Returned by chat.draft for
  // the privacy / hygiene / wallet-mgmt Intent variants. The TUI is
  // expected to dispatch the named daemon RPC (after a confirm
  // affordance for any signing path).
  //
  // For `prepare` (shielded.deposit / withdraw): the result is one or
  // more prepared txs that the TUI queues through per-tx ConfirmGate.
  // For `audit` (approvals.audit): the result is a read-only list
  // rendered inline.
  // For `create` (address.fresh): the result is the new wallet's
  // address (+ a BIP-39 mnemonic for the EOA case) handed off to the
  // existing wallet-creation flow which prompts for a passphrase.
  prepare?: {
    rpc: "shielded.prepareDeposit" | "shielded.prepareWithdraw";
    params: Record<string, unknown>;
  };
  audit?: {
    rpc: "daemon.approvals.list";
    params: Record<string, unknown>;
  };
  create?: {
    rpc: "eoa.create" | "tpm.create";
    params: {
      kind: "eoa" | "r1";
      deployImmediately: boolean;
      chainId: number;
      label?: string;
    };
  };
};

/** A row from `daemon.approvals.list`. The shape is the wire spec
 *  documented in the audit-approvals SKILL.md; today the daemon returns
 *  an empty list with implemented=false until the actual scan is wired. */
type ApprovalRow = {
  token: string;
  spender: string;
  amount: string;       // uint256 string-form
  lastSeenBlock: number;
};
type AuditResult = {
  chainId: number;
  approvals: ApprovalRow[];
  implemented: boolean;
  note?: string;
  wallet?: string;
};

type PreparedTx = { to: string; value: string; data: string };

/** Per-turn dispatch state for the chat.draft directive directives
 *  (prepare / audit / create). idle = button shown; running = RPC in
 *  flight; done = rendered inline; error = surfaced inline. */
type DispatchState =
  | { kind: "idle" }
  | { kind: "running" }
  | { kind: "auditDone"; data: AuditResult }
  | { kind: "prepareDone"; txs: PreparedTx[]; meta?: Record<string, unknown> }
  | { kind: "createHandedOff"; walletKind: "eoa" | "r1"; label?: string }
  | { kind: "error"; message: string };

type Turn =
  | { kind: "user"; text: string }
  | { kind: "assistant"; status: "pending" | "done"; result?: DraftResponse; error?: string; dispatch?: DispatchState }
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

/** Compact wallet+balance card shown in the chat header so the user
 *  has running context (top 5 wallets) without leaving the screen. */
type WalletBalance = {
  kind: "eoa" | "tpm";
  name: string;
  address: string;
  wei?: bigint;     // undefined while pending
  err?: string;
};

/** The daemon's chain.balance expects the chain *name* matching the
 *  per-chain endpoint keys in cfg.chainEndpoints. The chat's chainName
 *  state already holds that string; this helper just normalises and
 *  defends against accidental casing. */
function chainNameForBalance(chainName: string): string | undefined {
  if (!chainName) return undefined;
  return chainName.toLowerCase();
}

/** Cap on history turns sent to the daemon. The sidecar caps again to
 *  MAX_HISTORY_TURNS=6 — we send 8 so a "system" notice or two doesn't
 *  push real user turns out the top before the sidecar gets to filter. */
const TUI_HISTORY_CAP = 8;

/** Summarise an assistant turn to a short string suitable for replay
 *  through the LLM. We deliberately keep this lossy: full canonical
 *  text, model trace, and tool transcripts are dropped because they
 *  would balloon context and the sidecar re-runs tool calls per turn
 *  anyway. The point of history is to remember *what the user already
 *  said* and *what was offered/asked back*, not to relitigate state. */
function summariseAssistantTurn(t: Extract<Turn, { kind: "assistant" }>): string | null {
  if (t.status === "pending") return null;
  if (t.error) return `[error] ${t.error}`;
  const r = t.result;
  if (!r) return null;
  if (r.modelAsk?.question) {
    return `[ask] ${r.modelAsk.question}`;
  }
  if (r.encoded && r.intentActionTag) {
    const canon = r.canonical ? ` · ${r.canonical}` : "";
    return `[drafted ${r.intentActionTag}]${canon}`;
  }
  if (r.validateError) return `[validateError] ${r.validateError}`;
  if (r.encodeError) return `[encodeError] ${r.encodeError}`;
  if (r.llmError) return `[llmError] ${r.llmError}`;
  return null;
}

/** Build the history array forwarded to chat.draft. Filters out
 *  ephemeral system rows and pending turns, summarises assistant
 *  turns, and slices to the most recent TUI_HISTORY_CAP entries. */
function buildChatHistory(turns: Turn[]): { role: "user" | "assistant"; content: string }[] {
  const out: { role: "user" | "assistant"; content: string }[] = [];
  for (const t of turns) {
    if (t.kind === "user") {
      out.push({ role: "user", content: t.text });
    } else if (t.kind === "assistant") {
      const s = summariseAssistantTurn(t);
      if (s) out.push({ role: "assistant", content: s });
    }
    // system turns (in-chat notices) are intentionally dropped.
  }
  return out.slice(-TUI_HISTORY_CAP);
}

type Phase =
  | { kind: "boot" } // initial ensureUp + chains fetch
  | { kind: "needChain"; chains: ConfiguredChain[]; modelName?: string }
  | {
      kind: "chat";
      chainId: number;
      chainName: string;
      modelName?: string;
      turns: Turn[];
      input: string;
      busy: boolean;
      /** Opaque per-chat-open key forwarded to the agentd's sticky
       *  cache. Minted with `crypto.randomUUID()` when the chat opens
       *  (and rotated on `/clear`). The agentd keys its sticky-session
       *  cache by `(chainId, sessionKey)`, so a failed turn on one
       *  open cannot pollute the next open or the next `/clear` cycle.
       *  Never used as a secret — collision resistance is enough. */
      sessionKey: string;
    }
  | { kind: "fatal"; message: string };

/** Mint a fresh, opaque per-chat-open key. Prefers Node's built-in
 *  `crypto.randomUUID()` (available since 14.17 — the TUI ships on
 *  modern Node) and falls back to a time+random concatenation when
 *  the runtime omits it. Not used as a secret. */
function newSessionKey(): string {
  try {
    const c = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
    if (c && typeof c.randomUUID === "function") return c.randomUUID();
  } catch {
    // fall through
  }
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

export default function LlmChatFlow({ onDone, onApprove, onCreateWallet }: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "boot" });
  // Top-5 wallet balances shown in the header. Fetched lazily — chat
  // is usable before this returns. Empty list = "we haven't tried yet".
  const [wallets, setWallets] = useState<WalletBalance[]>([]);

  // Boot: ensureUp + fetch configured chains from the daemon.
  useEffect(() => {
    if (phase.kind !== "boot") return;
    (async () => {
      // 1. ensure llama-server.
      const r = await call<{ outcome: string; model?: string; baseUrl?: string }>("llm.ensureUp", {});
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
        chainId: number;
        rpc?: { url: string };
        perChain: { name: string; chainId: number; url: string; isCurrent: boolean }[];
      }>("network.show", {});
      if (!n.ok) {
        setPhase({ kind: "fatal", message: `network.show failed: ${n.error.message}` });
        return;
      }
      const chains = (n.result.perChain ?? []).filter((c) => c.chainId > 0);
      if (chains.length === 0) {
        // Diagnostic the user can act on without leaving the TUI to grep config.
        // We surface (a) what the daemon's default endpoint currently is and
        // (b) the exact commands to populate per-chain entries. The daemon
        // also auto-bootstraps `chain_endpoints[primary]` from `rpc_url` at
        // startup (LeanKohaku/Daemon/Config.lean), so seeing this error means
        // either chain_id resolved to something with no known name (e.g. an
        // L2 we don't know yet) or rpc_url itself is unset.
        const activeUrl = n.result.rpc?.url ?? "(unset)";
        const cid = n.result.chainId ?? "?";
        const cidName =
          cid === 1 ? "mainnet" : cid === 11155111 ? "sepolia" : `chain ${cid}`;
        setPhase({
          kind: "fatal",
          message:
            `No per-chain RPCs configured.\n\n` +
            `Daemon state:\n` +
            `  active default rpc_url:  ${activeUrl}\n` +
            `  daemon chainId:          ${cid} (${cidName})\n\n` +
            `Fix one of:\n` +
            `  kohaku network set-rpc-chain mainnet <mainnet-rpc-url>\n` +
            `  kohaku network set-rpc-chain sepolia <sepolia-rpc-url>\n\n` +
            `Or export MAINNET_RPC_URL / SEPOLIA_RPC_URL (e.g. in ./.env) and ` +
            `restart the daemon.`,
        });
        return;
      }
      setPhase({ kind: "needChain", chains, modelName: r.result?.model });
    })();
  }, [phase.kind]);

  // Fetch top-5 wallets + their balances once the user has entered the
  // chat phase (i.e. picked a chain). Sequential because public RPCs
  // throttle bursts; each balance lands as it arrives so the header
  // fills in progressively.
  useEffect(() => {
    if (phase.kind !== "chat") return;
    let cancelled = false;
    (async () => {
      const a = await call<{ accounts: { type: string; name: string; address: string }[] }>(
        "account.list",
        {},
      );
      if (cancelled || !a.ok) return;
      // Expand each EOA into its BIP-32 sub-accounts so a slot with
      // "leanWallet/ops" + "leanWallet/0" both show up — the user
      // expects to see (and address) any address they've created.
      // TPM wallets have no sub-accounts; they pass through as-is.
      const expanded: WalletBalance[] = [];
      for (const x of a.result.accounts ?? []) {
        if (!x || !x.address) continue;
        if (x.type === "tpm") {
          expanded.push({ kind: "tpm", name: x.name, address: x.address });
          continue;
        }
        if (x.type !== "eoa") continue;
        const sub = await call<{
          accounts: { index: number; path: string; address: string; label?: string }[];
        }>("eoa.account.list", { name: x.name });
        if (cancelled) return;
        if (sub.ok && Array.isArray(sub.result?.accounts) && sub.result.accounts.length > 0) {
          for (const acct of sub.result.accounts) {
            if (!acct?.address) continue;
            const subLabel = acct.label ?? String(acct.index);
            expanded.push({
              kind: "eoa",
              name: `${x.name}/${subLabel}`,
              address: acct.address,
            });
          }
        } else {
          expanded.push({ kind: "eoa", name: x.name, address: x.address });
        }
      }
      const top5 = expanded.slice(0, 5);
      setWallets(top5);
      const chainName = phase.kind === "chat" ? chainNameForBalance(phase.chainName) : undefined;
      for (let i = 0; i < top5.length; i++) {
        if (cancelled) return;
        const w = top5[i];
        if (!w) continue;
        // TPM wallets only support Sepolia today; everyone else uses
        // the chat's chain selection. The daemon does the same gate.
        const chain = w.kind === "tpm" ? "sepolia" : chainName;
        const r = await call<{ balance: string }>("chain.balance", {
          address: w.address,
          chain,
        });
        if (cancelled) return;
        setWallets((prev) => {
          const next = [...prev];
          const slot = next[i];
          if (!slot) return prev;
          next[i] = r.ok
            ? { ...slot, wei: hexToBigInt(r.result?.balance) }
            : { ...slot, err: r.error.message };
          return next;
        });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [phase.kind, phase.kind === "chat" ? phase.chainName : null]);

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
        modelName={phase.modelName}
        onPick={(c) =>
          setPhase({
            kind: "chat",
            chainId: c.chainId,
            chainName: c.name,
            modelName: phase.modelName,
            turns: [],
            input: "",
            busy: false,
            // Fresh per-chat-open key. The agentd's sticky cache is
            // keyed by (chainId, sessionKey), so a previous chat open
            // on the same chain — even one that ended on a failed
            // swap turn — cannot pollute this open. Token-budget
            // rollover and `/clear` both rotate this key further.
            sessionKey: newSessionKey(),
          })
        }
      />
    );
  }

  // Update the dispatch state of a single assistant turn (matched by
  // reference identity in phase.turns). Centralises the "find the right
  // index, copy the array, splice" boilerplate so the executors below
  // don't each reinvent it.
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

  /** Fire the directive's RPC and route the result. Audit dispatches
   *  in-place (read-only). Prepare calls the prepare RPC and routes
   *  the FIRST returned tx through onApprove (the existing per-tx
   *  ConfirmGate path); the prepared-tx list is also shown so the
   *  user sees what they're walking through. Create hands off to the
   *  existing wallet-creation flow via onCreateWallet — that flow
   *  already handles passphrase / TPM PIN prompts. */
  const executeDirective = async (turn: Extract<Turn, { kind: "assistant" }>) => {
    const r = turn.result;
    if (!r) return;
    if (turn.dispatch && turn.dispatch.kind !== "idle") return;
    updateTurnDispatch(turn, { kind: "running" });
    if (r.audit) {
      const resp = await call<AuditResult>(r.audit.rpc, r.audit.params, { timeoutMs: 60_000 });
      if (!resp.ok) {
        updateTurnDispatch(turn, { kind: "error", message: resp.error.message });
        return;
      }
      updateTurnDispatch(turn, { kind: "auditDone", data: resp.result });
      return;
    }
    if (r.prepare) {
      // shielded.prepareDeposit/prepareWithdraw can take 30-60s on the
      // first call (the bridge sidecar loads the SDK + syncs PP state
      // from chain). The 5-minute cap matches chat.draft's own cap.
      const resp = await call<{ txs?: PreparedTx[]; transactions?: PreparedTx[] }>(
        r.prepare.rpc,
        r.prepare.params,
        { timeoutMs: 300_000 },
      );
      if (!resp.ok) {
        updateTurnDispatch(turn, { kind: "error", message: resp.error.message });
        return;
      }
      // The bridge has used both shape names historically; accept either.
      const txs = (resp.result.txs ?? resp.result.transactions ?? []) as PreparedTx[];
      updateTurnDispatch(turn, { kind: "prepareDone", txs });
      // Auto-queue the first tx through the existing per-tx ConfirmGate
      // (SendRawFlow): users have already pressed Execute, and the
      // canonical Intent + simulate result reach them via the next
      // screen. Multi-tx bundles surface every prepared tx in the list
      // above; the user re-triggers for subsequent txs.
      if (txs.length > 0 && onApprove) {
        const first = txs[0];
        if (first) {
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
      }
      return;
    }
    if (r.create) {
      if (!onCreateWallet) {
        updateTurnDispatch(turn, {
          kind: "error",
          message: "wallet creation flow not wired; open WalletsHub > Create EOA / R1 from the main menu",
        });
        return;
      }
      const kind = r.create.params.kind;
      const label = r.create.params.label;
      onCreateWallet(kind, label);
      updateTurnDispatch(turn, { kind: "createHandedOff", walletKind: kind, label });
      return;
    }
  };

  // Shared between the explicit signing affordance and the
  // "enter on empty input" shortcut so a single source of truth
  // governs what "confirm" means.
  const proceedWith = (turn: Extract<Turn, { kind: "assistant" }>) => {
    if (!turn.result?.encoded || !onApprove) return;
    const enc = turn.result.encoded;
    // Pre-select the signing wallet so SendRawFlow skips its picker.
    // Source preference (most reliable first):
    //   1. `encoded.sender` — populated when the agent's `propose_send`
    //      tool call carried a `sender` field (which it should whenever
    //      `slot_lookup` resolved the user's wallet earlier in the
    //      conversation).
    //   2. `regex.fields.from` — the regex layer's resolved "from" hint
    //      (e.g. "approve X from leanWallet" parses it directly).
    // Match by address, case-insensitive (addresses round-trip through
    // lowercase in some places).
    const senderHint =
      enc.sender ??
      turn.result.regex?.fields?.find((kv) => kv.k === "from")?.v;
    const preselected = (() => {
      if (!senderHint) return undefined;
      const want = senderHint.toLowerCase();
      const w = wallets.find((wb) => wb.address.toLowerCase() === want);
      if (!w) return undefined;
      return { kind: w.kind, name: w.name, address: w.address };
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

  return (
    <ChatBody
      chainId={phase.chainId}
      chainName={phase.chainName}
      modelName={phase.modelName}
      wallets={wallets}
      turns={phase.turns}
      input={phase.input}
      busy={phase.busy}
      onInputChange={(v) => setPhase({ ...phase, input: v })}
      onSubmit={async () => {
        if (phase.busy) return;
        const text = phase.input.trim();
        // Enter inside the input box always means "send" — the sign
        // affordance has moved to a separate Tab-focusable button
        // above this bar (see ChatBody). Empty enter is a no-op.
        if (text.length === 0) return;
        // `/clear` interception. Silent handoff: the literal `/clear`
        // is NOT echoed as a chat turn. We fire-and-await a best-effort
        // rollover RPC (the agentd closes the cached session id and
        // runs the standard memory extraction, gated by the existing
        // `autoExtractMinMessages` floor), mint a fresh sessionKey, and
        // replace the visible turns with a single in-chat marker.
        // Errors are logged via the resulting `system` notice but never
        // block the rotation — the new sessionKey alone is enough to
        // route subsequent turns to a fresh agentd session.
        const firstToken = text.split(/\s+/, 1)[0];
        if (firstToken === "/clear") {
          const oldKey = phase.sessionKey;
          // Eagerly clear UI + mint new key so the user sees the
          // rotation regardless of the RPC outcome.
          const newKey = newSessionKey();
          setPhase({
            ...phase,
            input: "",
            sessionKey: newKey,
            turns: [
              { kind: "system", text: "(context cleared — new mission)", tone: "info" },
            ],
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
        // Build history from prior turns (NOT including the user turn
        // we're about to send — that goes in `prompt`). Each assistant
        // turn is summarised to a short string; the sidecar caps the
        // final list, so we pass up to 8 here and let it slice.
        const history = buildChatHistory(phase.turns);
        const turnsAfterUser: Turn[] = [
          ...phase.turns,
          { kind: "user", text },
          { kind: "assistant", status: "pending" },
        ];
        setPhase({ ...phase, turns: turnsAfterUser, input: "", busy: true });
        // chat.draft can take a long time: a thinking model (Qwen3 with
        // its <think> reasoning trace, gpt-oss with reasoning_content)
        // routinely produces 2–4k tokens of reasoning before the final
        // JSON, and the agentic tool-call loop multiplies this by up to
        // MAX_TOOL_TURNS round-trips. 60s (the default) chops the
        // sidecar mid-generation and surfaces as "sidecar crash exit 1".
        // 5 min is generous but still finite — beyond that, the user
        // wants to bail rather than wait.
        const r = await call<DraftResponse>(
          "chat.draft",
          {
            prompt: text,
            chainId: phase.chainId,
            // Forward the opaque per-chat-open key so the agentd's
            // sticky cache scopes by (chainId, sessionKey). Older
            // daemons (or non-persistent agent modes) ignore this
            // field; the call works either way.
            sessionKey: phase.sessionKey,
            history,
          },
          { timeoutMs: 300_000 },
        );
        const finished: Turn = r.ok
          ? { kind: "assistant", status: "done", result: r.result }
          : { kind: "assistant", status: "done", error: r.error.message };
        // Replace the pending assistant turn with the finished one.
        const updated = [...turnsAfterUser];
        updated[updated.length - 1] = finished;
        setPhase((p) => (p.kind === "chat" ? { ...p, turns: updated, busy: false } : p));
      }}
      onProceed={proceedWith}
      onExecute={executeDirective}
    />
  );
}

/* ---------- Sub-components ---------- */

/** Outer chrome for the chat screen. Three regions:
 *  - Left rail: the koi (Claude-Code-logo-equivalent for this screen).
 *  - Header rectangle (right of koi): title + chain + optional wallet list.
 *  - Body: whatever the phase renders (chain picker / chat / error).
 *  The koi reuses the same AnimatedKoi widget the main menu shows so
 *  the chat is visually anchored to the wallet's identity. */
function Container({
  children,
  chainTag,
  wallets,
  modelName,
}: {
  children: React.ReactNode;
  chainTag: string;
  wallets?: WalletBalance[];
  modelName?: string;
}) {
  return (
    <Box flexDirection="column" paddingX={1}>
      <KoiFrame>
        <Text color={theme.koiCream} backgroundColor={theme.koiInk} bold>
          {" le chat · local LLM "}
          {chainTag !== "…" ? `· ${chainTag}` : ""}
        </Text>
        {modelName && (
          <Text color={theme.dim}>
            model: <Text color={theme.primary}>{modelName}</Text>
          </Text>
        )}
        <Text color={theme.dim}>
          untrusted model · regex+ENS+wallet seed · Lean validator · canonical text in confirm
        </Text>
        {wallets && wallets.length > 0 && (
          <Box marginTop={1} flexDirection="column">
            <Text color={theme.dim}>Top wallets ({wallets.length}):</Text>
            {wallets.map((w) => (
              <WalletRow key={`${w.kind}-${w.name}-${w.address}`} w={w} />
            ))}
          </Box>
        )}
      </KoiFrame>
      <Box marginTop={1} flexDirection="column">{children}</Box>
    </Box>
  );
}

function WalletRow({ w }: { w: WalletBalance }) {
  // Full plain-text address — never truncated. Project rule: every
  // surface that shows an address shows all 42 chars so the user can
  // copy + verify character-by-character without extra clicks.
  let amount: React.ReactNode;
  if (w.err) amount = <Text color={theme.err}>error</Text>;
  else if (w.wei === undefined) amount = <Text color={theme.dim}>…</Text>;
  // formatEth already includes " ETH" in its return — don't double it.
  else amount = <Text>{formatEth(w.wei)}</Text>;
  return (
    <Text>
      <Text color={theme.dim}>{`  ${(w.kind === "tpm" ? "[tpm] " : "[eoa] ").padEnd(7)}`}</Text>
      <Text>{w.name.padEnd(22)}</Text>
      <Text color={theme.dim}>{w.address}{"  "}</Text>
      {amount}
    </Text>
  );
}

/** Lists the daemon's already-configured chains and lets the user pick
 *  one with arrow keys. No free-text chainId input — the daemon's own
 *  per-chain endpoint map is the source of truth, so the user never
 *  has to re-set an RPC URL to start a chat on a different chain. */
function ChainPicker({
  chains,
  modelName,
  onPick,
}: {
  chains: ConfiguredChain[];
  modelName?: string;
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
        {modelName && (
          <Text color={theme.dim}>
            Model: <Text color={theme.primary}>{modelName}</Text>{" "}
            <Text color={theme.dim}>· swap by restarting llama-server with another -hf flag or setting LOCAL_LLM_MODEL</Text>
          </Text>
        )}
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
  modelName,
  wallets,
  turns,
  input,
  busy,
  onInputChange,
  onSubmit,
  onProceed,
  onExecute,
}: {
  chainId: number;
  chainName: string;
  modelName?: string;
  wallets: WalletBalance[];
  turns: Turn[];
  input: string;
  busy: boolean;
  onInputChange: (v: string) => void;
  onSubmit: () => void;
  onProceed: (turn: Extract<Turn, { kind: "assistant" }>) => void;
  onExecute: (turn: Extract<Turn, { kind: "assistant" }>) => void;
}) {
  // Find the most recent encoded assistant turn — the [Sign + broadcast]
  // button (when focused) acts on this one.
  const latestSignable = [...turns].reverse().find(
    (t): t is Extract<Turn, { kind: "assistant" }> =>
      t.kind === "assistant" && t.status === "done" && !!t.result?.encoded,
  );
  // Latest assistant turn carrying a directive (prepare/audit/create)
  // that has NOT been dispatched yet. The [Execute] button acts on it.
  // Once dispatch has fired (state ≠ idle/undefined), the button hides;
  // re-triggering would need a new chat turn so the user explicitly
  // re-confirms intent.
  const latestExecutable = [...turns].reverse().find(
    (t): t is Extract<Turn, { kind: "assistant" }> => {
      if (t.kind !== "assistant" || t.status !== "done") return false;
      const r = t.result;
      if (!r) return false;
      if (!(r.prepare || r.audit || r.create)) return false;
      const d = t.dispatch;
      return !d || d.kind === "idle";
    },
  );

  // Tab cycles focus between the text input and the sign button. The
  // text input gets focus by default; the button only becomes
  // focusable when there's actually a draft to sign. Holding the
  // distinction explicitly in state lets us tell ink-text-input to
  // STOP capturing keystrokes when focus is on the button — otherwise
  // Tab would just insert a "\t" into the prompt.
  const [focus, setFocus] = useState<"input" | "sign" | "execute">("input");
  // Set of assistant-turn indices whose agentTrace block is expanded.
  // Folded by default; `t` toggles the LATEST assistant turn that
  // carries a trace. This keeps the keybinding simple (one global
  // toggle), since trace-of-the-current-turn is the dominant case.
  const [expandedTraces, setExpandedTraces] = useState<Set<number>>(
    () => new Set<number>(),
  );
  // If the draft goes away (e.g. user retried and got an ask) and we
  // were on a button, drop focus back to input.
  useEffect(() => {
    if (!latestSignable && focus === "sign") setFocus("input");
    if (!latestExecutable && focus === "execute") setFocus("input");
  }, [latestSignable, latestExecutable, focus]);

  // Index of the most recent assistant turn that has a trace payload
  // we could expand. Used by the `t` keybinding; null when no such
  // turn exists yet (e.g. first prompt still pending).
  const latestTraceIdx: number | null = (() => {
    for (let i = turns.length - 1; i >= 0; i--) {
      const t = turns[i];
      if (
        t &&
        t.kind === "assistant" &&
        t.status === "done" &&
        t.result?.agentTrace &&
        t.result.agentTrace.length > 0
      ) {
        return i;
      }
    }
    return null;
  })();

  useInput((ch, key) => {
    if (busy) return;
    // Ctrl+T toggles expand/collapse of the most recent assistant
    // turn's trace block. Plain `t` collides with chat input — ink's
    // `useInput` fires globally regardless of which widget is
    // focused, so a bare letter binding would eat every `t` typed
    // into the message box. Modifier-gated keys reach this hook
    // without being captured by ink-text-input.
    if (key.ctrl && ch === "t" && latestTraceIdx !== null) {
      setExpandedTraces((prev) => {
        const next = new Set(prev);
        if (next.has(latestTraceIdx)) next.delete(latestTraceIdx);
        else next.add(latestTraceIdx);
        return next;
      });
      return;
    }
    if (key.tab) {
      // Tab cycles among the buttons that currently exist:
      //   input → (sign if present) → (execute if present) → input
      // Build the live ring on each press so removed buttons drop out.
      const ring: ("input" | "sign" | "execute")[] = ["input"];
      if (latestSignable) ring.push("sign");
      if (latestExecutable) ring.push("execute");
      if (ring.length === 1) return;
      const idx = ring.indexOf(focus);
      setFocus(ring[(idx + 1) % ring.length] ?? "input");
      return;
    }
    if (key.return && focus === "sign" && latestSignable) {
      onProceed(latestSignable);
      setFocus("input");
      return;
    }
    if (key.return && focus === "execute" && latestExecutable) {
      onExecute(latestExecutable);
      setFocus("input");
      return;
    }
  });

  return (
    <Container chainTag={`${chainName} (${chainId})`} wallets={wallets} modelName={modelName}>
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
            <TurnRow
              key={i}
              turn={t}
              isLatestSignable={t === latestSignable}
              traceExpanded={expandedTraces.has(i)}
              isLatestTrace={i === latestTraceIdx}
            />
          ))
        )}
      </Box>

      {/* Sign button (only when a draft is pending). Sits above the
        input box; gets focus via Tab. Border changes color and label
        gets a ✓ glyph when focused so the user can see "I'm about to
        sign on enter" before they press it. */}
      {latestSignable && (
        <Box
          marginTop={1}
          borderStyle={focus === "sign" ? "double" : "single"}
          borderColor={focus === "sign" ? theme.ok : theme.dim}
          paddingX={1}
        >
          <Text color={focus === "sign" ? theme.ok : theme.dim} bold>
            {focus === "sign" ? "▶  ✓ Sign + broadcast (enter)" : "   ✓ Sign + broadcast (tab to focus)"}
          </Text>
          <Text color={theme.dim}>
            {"   "}
            ↳ {latestSignable.result?.intentActionTag ?? "encoded draft"} ·{" "}
            simulate + ConfirmGate runs after this
          </Text>
        </Box>
      )}
      {/* Execute button — fires the prepare/audit/create directive's
        RPC. Distinct from [Sign + broadcast] because the underlying
        action shape is different (no encoded tx in hand; the daemon
        prepare RPC returns one). For prepare, the FIRST prepared tx
        is auto-queued through ConfirmGate; for audit, results render
        inline; for create, the user is handed off to the existing
        wallet-creation flow. */}
      {latestExecutable && (
        <Box
          marginTop={1}
          borderStyle={focus === "execute" ? "double" : "single"}
          borderColor={focus === "execute" ? theme.primary : theme.dim}
          paddingX={1}
        >
          <Text color={focus === "execute" ? theme.primary : theme.dim} bold>
            {focus === "execute"
              ? `▶  ⚡ Execute ${actionableLabel(latestExecutable)} (enter)`
              : `   ⚡ Execute ${actionableLabel(latestExecutable)} (tab to focus)`}
          </Text>
          <Text color={theme.dim}>
            {"   "}
            ↳ calls {actionableRpc(latestExecutable)}
          </Text>
        </Box>
      )}

      {/* Input bar — double-border rectangle pinned below the conversation,
        evoking Claude Code's prompt bar. ink-text-input only captures
        keystrokes while focus is on the input; tabbing to the sign
        button frees up Enter for the sign action. */}
      <Box
        marginTop={1}
        flexDirection="column"
        borderStyle="double"
        borderColor={busy ? theme.dim : focus === "input" ? theme.primary : theme.dim}
        paddingX={1}
      >
        <Box>
          <Text color={busy ? theme.dim : focus === "input" ? theme.primary : theme.dim} bold>
            {focus === "input" ? ">  " : "·  "}
          </Text>
          {busy ? (
            <Text color={theme.dim}>
              <Spinner type="dots" /> thinking…
            </Text>
          ) : (
            <TextInput
              value={input}
              onChange={onInputChange}
              onSubmit={onSubmit}
              focus={focus === "input"}
            />
          )}
        </Box>
      </Box>
      <Box marginTop={0}>
        <Text color={theme.dim}>
          {latestSignable
            ? "tab — toggle focus · enter — act on focused element · "
            : "enter — send · "}
          {latestTraceIdx !== null ? "ctrl+t — toggle trace · " : ""}
          /clear — new session ·{" "}
          esc — leave chat
        </Text>
      </Box>
    </Container>
  );
}

function TurnRow({
  turn,
  isLatestSignable,
  traceExpanded,
  isLatestTrace,
}: {
  turn: Turn;
  isLatestSignable: boolean;
  /** Whether THIS turn's trace block is currently expanded. */
  traceExpanded: boolean;
  /** True for the most recent assistant turn that carries a trace —
   *  the one the global `t` keybinding will toggle. Used purely for
   *  the hint text on the fold line. */
  isLatestTrace: boolean;
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
          <Text color={theme.primary} bold>↳ tab to the [Sign + broadcast] button below, then enter to confirm </Text>
          <Text color={theme.dim}>(simulate + ConfirmGate)</Text>
        </Box>
      )}
      {(r.prepare || r.audit || r.create) && (
        <DirectiveBlock prepare={r.prepare} audit={r.audit} create={r.create} />
      )}
      <DispatchBlock dispatch={turn.dispatch} />
      {r.agentTrace && r.agentTrace.length > 0 && (
        <AgentTraceBlock
          trace={r.agentTrace}
          expanded={traceExpanded}
          isLatestTrace={isLatestTrace}
        />
      )}
    </Box>
  );
}

/** Maximum number of trace-block lines to render when expanded. Past
 *  this cap we show a `… N more` tail. Keeps a runaway agent loop
 *  from blowing past the terminal height. */
const TRACE_VISIBLE_LINE_CAP = 30;

/** Crude token estimator: ~4 chars per token. Used only for the
 *  folded summary line ("· 312 tokens reasoning"); a real tokenizer
 *  would be overkill for a display hint. */
function estimateReasoningTokens(trace: TraceItem[]): number {
  let chars = 0;
  for (const item of trace) {
    if (item.kind === "assistant" && item.reasoning) {
      chars += item.reasoning.length;
    }
  }
  return Math.ceil(chars / 4);
}

/** Truncate s to n chars with an ellipsis tail. Display-only. */
function clip(s: string, n: number): string {
  if (s.length <= n) return s;
  return s.slice(0, n) + "…";
}

/** Foldable per-turn trace block. Closed by default; renders a single
 *  summary line. When expanded, renders each trace item with a short
 *  prefix as documented in the design doc. */
function AgentTraceBlock({
  trace,
  expanded,
  isLatestTrace,
}: {
  trace: TraceItem[];
  expanded: boolean;
  isLatestTrace: boolean;
}) {
  const toolCallCount = trace.filter((x) => x.kind === "tool_call").length;
  const reasoningTokens = estimateReasoningTokens(trace);
  const hint = isLatestTrace ? " (press ctrl+t to toggle)" : "";
  if (!expanded) {
    return (
      <Box paddingLeft={5} marginTop={1}>
        <Text color={theme.dim}>
          ▸ {toolCallCount} tool call{toolCallCount === 1 ? "" : "s"} ·{" "}
          {reasoningTokens} tokens reasoning{hint}
        </Text>
      </Box>
    );
  }
  // Expanded: render each item with a short prefix. Cap at
  // TRACE_VISIBLE_LINE_CAP lines (some items render across two lines —
  // reasoning sits below its assistant). We count rendered lines as we
  // go and bail with a `… N more` marker when over the cap.
  type RenderedLine = { text: string; color: string; nested?: boolean };
  const lines: RenderedLine[] = [];
  for (const item of trace) {
    if (lines.length >= TRACE_VISIBLE_LINE_CAP) break;
    if (item.kind === "assistant") {
      const head = item.content.replace(/\s+/g, " ").slice(0, 120);
      lines.push({
        text: `· assistant: ${head}`,
        color: theme.dim,
      });
      if (item.reasoning && lines.length < TRACE_VISIBLE_LINE_CAP) {
        const thinking = clip(item.reasoning.replace(/\s+/g, " "), 400);
        lines.push({
          text: `  ⌐ thinking: ${thinking}`,
          color: theme.dim,
          nested: true,
        });
      }
    } else if (item.kind === "tool_call") {
      const args = clip(item.argsJson, 80);
      lines.push({
        text: `→ ${item.name}(${args})`,
        color: theme.primary,
      });
    } else {
      const tag = item.ok ? "ok" : "err";
      lines.push({
        text: `← ${tag}: ${item.summary}`,
        color: item.ok ? theme.ok : theme.err,
      });
    }
  }
  const dropped = Math.max(0, trace.length - lines.filter(
    (l) => !l.nested,
  ).length);
  return (
    <Box paddingLeft={5} marginTop={1} flexDirection="column">
      <Text color={theme.dim}>
        ▾ {toolCallCount} tool call{toolCallCount === 1 ? "" : "s"} ·{" "}
        {reasoningTokens} tokens reasoning{hint}
      </Text>
      {lines.map((line, i) => (
        <Text key={i} color={line.color}>
          {"  "}
          {line.text}
        </Text>
      ))}
      {dropped > 0 && (
        <Text color={theme.dim}>
          {"  "}… {dropped} more item{dropped === 1 ? "" : "s"}
        </Text>
      )}
    </Box>
  );
}

/** Renders the chat.draft response's `prepare` / `audit` / `create`
 *  directive. These are NOT encoded txs — they tell the TUI which
 *  daemon RPC to call next. Today this block is informational: it
 *  shows the user what's about to happen and which RPC will fire.
 *  Dispatch wiring (calling the RPC, queuing prepared txs through
 *  per-tx ConfirmGate, handing freshAddress creation off to the
 *  existing wallet-flow) lands in a follow-up — keeping the daemon
 *  side of step E testable first. */
function DirectiveBlock({
  prepare,
  audit,
  create,
}: {
  prepare?: DraftResponse["prepare"];
  audit?: DraftResponse["audit"];
  create?: DraftResponse["create"];
}) {
  return (
    <Box paddingLeft={5} marginTop={1} flexDirection="column">
      {prepare && (
        <Box flexDirection="column">
          <Text color={theme.primary} bold>
            ↳ next: <Text color={theme.ok}>{prepare.rpc}</Text>
          </Text>
          <Text color={theme.dim}>
            {"  "}params: {compactParams(prepare.params)}
          </Text>
          <Text color={theme.dim}>
            {"  "}each prepared tx runs through simulate + ConfirmGate before signing
          </Text>
        </Box>
      )}
      {audit && (
        <Box flexDirection="column">
          <Text color={theme.primary} bold>
            ↳ next: <Text color={theme.ok}>{audit.rpc}</Text>{" "}
            <Text color={theme.dim}>(read-only)</Text>
          </Text>
          <Text color={theme.dim}>
            {"  "}params: {compactParams(audit.params)}
          </Text>
        </Box>
      )}
      {create && (
        <Box flexDirection="column">
          <Text color={theme.primary} bold>
            ↳ next: <Text color={theme.ok}>{create.rpc}</Text>
          </Text>
          <Text color={theme.dim}>
            {"  "}kind: {create.params.kind}
            {create.params.label ? ` · label: ${create.params.label}` : ""}
            {create.params.kind === "r1" && create.params.deployImmediately
              ? " · deploy: yes"
              : ""}
          </Text>
          {create.params.kind === "eoa" && (
            <Text color={theme.warn}>
              {"  "}EOA path will surface a 12-word BIP-39 mnemonic — write it down before continuing
            </Text>
          )}
        </Box>
      )}
    </Box>
  );
}

/** Compact one-line JSON of params — strips quotes around values for
 *  display readability; users see `chainId=11155111` instead of the
 *  raw `{"chainId":11155111}`. Not a serialiser — display-only. */
function compactParams(p: Record<string, unknown>): string {
  return Object.entries(p)
    .map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`)
    .join(" · ");
}

/** Short label for the [Execute] button — distinguishes the three
 *  directive types so the user sees "Execute audit" / "Execute prepare"
 *  / "Execute create wallet" before pressing enter. */
function actionableLabel(turn: Extract<Turn, { kind: "assistant" }>): string {
  const r = turn.result;
  if (!r) return "(no directive)";
  if (r.audit) return "audit";
  if (r.prepare) return r.prepare.rpc === "shielded.prepareDeposit" ? "shield prepare" : "unshield prepare";
  if (r.create) return r.create.params.kind === "eoa" ? "create EOA" : "create R1";
  return "directive";
}

function actionableRpc(turn: Extract<Turn, { kind: "assistant" }>): string {
  const r = turn.result;
  if (!r) return "—";
  if (r.audit) return r.audit.rpc;
  if (r.prepare) return r.prepare.rpc;
  if (r.create) return r.create.rpc;
  return "—";
}

/** Render the dispatch state of an assistant turn. Idle / undefined =>
 *  null (the [Execute] button is the entire affordance). Running shows
 *  a spinner with context. Done renders the result inline per kind.
 *  Errors surface verbatim. */
function DispatchBlock({ dispatch }: { dispatch?: DispatchState }) {
  if (!dispatch || dispatch.kind === "idle") return null;
  if (dispatch.kind === "running") {
    return (
      <Box paddingLeft={5} marginTop={1}>
        <Text color={theme.primary}>
          <Spinner type="dots" /> dispatching…
        </Text>
      </Box>
    );
  }
  if (dispatch.kind === "error") {
    return (
      <Box paddingLeft={5} marginTop={1} flexDirection="column">
        <Text color={theme.err} bold>✗ dispatch failed</Text>
        <Text color={theme.err}>{dispatch.message}</Text>
      </Box>
    );
  }
  if (dispatch.kind === "auditDone") {
    const d = dispatch.data;
    return (
      <Box paddingLeft={5} marginTop={1} flexDirection="column">
        <Text color={theme.ok} bold>
          ✓ audit complete · {d.approvals.length} approval(s){d.wallet ? ` for ${shortAddr(d.wallet)}` : ""}
        </Text>
        {!d.implemented && d.note && (
          <Text color={theme.warn}>! {d.note}</Text>
        )}
        {d.approvals.map((row, i) => (
          <Text key={i} color={theme.dim}>
            {"  "}#{i + 1} token={shortAddr(row.token)} · spender={shortAddr(row.spender)} ·
            {" "}amount={row.amount} · lastBlock={row.lastSeenBlock}
          </Text>
        ))}
      </Box>
    );
  }
  if (dispatch.kind === "prepareDone") {
    const txs = dispatch.txs;
    return (
      <Box paddingLeft={5} marginTop={1} flexDirection="column">
        <Text color={theme.ok} bold>
          ✓ prepared {txs.length} tx{txs.length === 1 ? "" : "s"}
        </Text>
        {txs.length > 0 && (
          <Text color={theme.dim}>
            {"  "}tx 1 of {txs.length} auto-queued through simulate + ConfirmGate
            {txs.length > 1 ? " · remaining txs re-trigger via the next chat turn" : ""}
          </Text>
        )}
        {txs.map((t, i) => (
          <Text key={i} color={theme.dim}>
            {"  "}#{i + 1} to={shortAddr(t.to)} value={t.value} data={t.data.slice(0, 14)}…
          </Text>
        ))}
      </Box>
    );
  }
  if (dispatch.kind === "createHandedOff") {
    return (
      <Box paddingLeft={5} marginTop={1} flexDirection="column">
        <Text color={theme.ok} bold>
          ↳ handed off to wallet-creation flow ({dispatch.walletKind === "eoa" ? "EOA / BIP-39" : "R1 / TPM hardware key"}
          {dispatch.label ? `, label: ${dispatch.label}` : ""})
        </Text>
        {dispatch.walletKind === "eoa" && (
          <Text color={theme.warn}>
            ! the creation screen surfaces a 12-word BIP-39 mnemonic — write it down before leaving
          </Text>
        )}
      </Box>
    );
  }
  return null;
}

function shortAddr(s: string): string {
  return s;
}

function RegexLine({
  regex,
}: {
  regex: NonNullable<DraftResponse["regex"]>;
}) {
  // Pull amount-related fields out so we can render them as one
  // readable summary line; the remaining k=v pairs still print below
  // so power users see exactly what the parser captured.
  const fieldMap = new Map(regex.fields.map((kv) => [kv.k, kv.v]));
  const amount = fieldMap.get("amount");
  const asset = fieldMap.get("asset");
  const amountBase = fieldMap.get("amountBase");
  const summaryAmount =
    amount && asset
      ? amountBase
        ? `${amount} ${asset.toUpperCase()}  (${amountBase} base units)`
        : `${amount} ${asset.toUpperCase()}`
      : null;
  const restFields = regex.fields.filter(
    (kv) => kv.k !== "amount" && kv.k !== "asset" && kv.k !== "amountBase",
  );

  return (
    <Box paddingLeft={5} flexDirection="column">
      {summaryAmount && (
        <Text color={theme.ok} bold>
          amount: {summaryAmount}
        </Text>
      )}
      {restFields.length > 0 && (
        <Text color={theme.dim}>
          regex: {restFields.map((kv) => `${kv.k}=${kv.v}`).join("  ")}
        </Text>
      )}
      {regex.ownerships && regex.ownerships.length > 0 && (
        <Box flexDirection="column" marginTop={0}>
          {regex.ownerships.map((o, i) => (
            <OwnershipBadge key={i} entry={o} />
          ))}
        </Box>
      )}
      {regex.unresolved.map((u, i) => (
        <Text key={i} color={theme.dim}>! {u}</Text>
      ))}
    </Box>
  );
}

// Per-field address-ownership badge. Renders the safety claim that
// `chat.draft` is willing to make for a regex-resolved address.
// Backed by the proven invariant 14.1
// (LeanKohaku/Invariants/AddressOwnership.lean): the daemon can only
// emit `verified` after re-deriving the unlocked seed at the recorded
// BIP-44 path and structurally comparing to the address shown here.
function OwnershipBadge({ entry }: { entry: OwnershipEntry }) {
  const short =
    entry.address.length > 14
      ? `${entry.address.slice(0, 8)}…${entry.address.slice(-4)}`
      : entry.address;
  switch (entry.status) {
    case "verified":
      return (
        <Text color={theme.ok}>
          ✓ {entry.key}={short} · locally re-derived ({entry.derivationPath})
        </Text>
      );
    case "locked":
      return (
        <Text color={theme.warn}>
          ⚠ {entry.key}={short} · ownership not re-derived (wallet locked)
        </Text>
      );
    case "hardware":
      return (
        <Text color={theme.ok}>
          ⛨ {entry.key}={short} · TPM-bound key (hardware-owned)
        </Text>
      );
    case "book":
      return (
        <Text color={theme.dim}>
          ⓘ {entry.key}={short} · address-book entry (not your wallet)
        </Text>
      );
    case "external":
      return (
        <Text color={theme.dim}>
          · {entry.key}={short} · external address
        </Text>
      );
    case "mismatch":
      return (
        <Text color={theme.err}>
          ✗ {entry.key}={short} · DERIVATION MISMATCH (record claims {short}, seed derives {entry.derived ?? "?"})
        </Text>
      );
  }
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
