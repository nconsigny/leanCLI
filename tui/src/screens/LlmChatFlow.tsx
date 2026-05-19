import React, { useEffect, useRef, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import Select, { SelectItem } from "../widgets/Select.js";
import AnimatedKoi from "../widgets/AnimatedKoi.js";
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

type Phase =
  | { kind: "boot" } // initial ensureUp + chains fetch
  | { kind: "needChain"; chains: ConfiguredChain[]; modelName?: string }
  | { kind: "chat"; chainId: number; chainName: string; modelName?: string; turns: Turn[]; input: string; busy: boolean }
  | { kind: "fatal"; message: string };

export default function LlmChatFlow({ onDone, onApprove }: Props) {
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
          })
        }
      />
    );
  }

  // Shared between the explicit signing affordance and the
  // "enter on empty input" shortcut so a single source of truth
  // governs what "confirm" means.
  const proceedWith = (turn: Extract<Turn, { kind: "assistant" }>) => {
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
      onProceed={proceedWith}
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
      <Box flexDirection="row">
        <Box marginRight={2}>
          <AnimatedKoi size="tiny" />
        </Box>
        <Box
          borderStyle="double"
          borderColor={theme.koiRed}
          paddingX={2}
          paddingY={0}
          flexDirection="column"
          flexGrow={1}
        >
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
        </Box>
      </Box>
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
}) {
  // Find the most recent encoded assistant turn — the [Sign + broadcast]
  // button (when focused) acts on this one.
  const latestSignable = [...turns].reverse().find(
    (t): t is Extract<Turn, { kind: "assistant" }> =>
      t.kind === "assistant" && t.status === "done" && !!t.result?.encoded,
  );

  // Tab cycles focus between the text input and the sign button. The
  // text input gets focus by default; the button only becomes
  // focusable when there's actually a draft to sign. Holding the
  // distinction explicitly in state lets us tell ink-text-input to
  // STOP capturing keystrokes when focus is on the button — otherwise
  // Tab would just insert a "\t" into the prompt.
  const [focus, setFocus] = useState<"input" | "sign">("input");
  // If the draft goes away (e.g. user retried and got an ask) and we
  // were on the sign button, drop focus back to input.
  useEffect(() => {
    if (!latestSignable && focus === "sign") setFocus("input");
  }, [latestSignable, focus]);

  useInput((_ch, key) => {
    if (busy) return;
    if (key.tab && latestSignable) {
      setFocus((f) => (f === "input" ? "sign" : "input"));
      return;
    }
    // Enter while the button has focus → sign. (Enter inside the
    // text input is handled by ink-text-input's onSubmit.)
    if (key.return && focus === "sign" && latestSignable) {
      onProceed(latestSignable);
      // Stay on the button for the next draft, or drop back to input
      // — handing back to input is more useful since the next thing
      // the user does is usually type a refinement.
      setFocus("input");
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
            <TurnRow key={i} turn={t} isLatestSignable={t === latestSignable} />
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
            ? "tab — toggle focus · enter — act on focused element · esc — leave chat"
            : "enter — send · esc — leave chat"}
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
          <Text color={theme.primary} bold>↳ tab to the [Sign + broadcast] button below, then enter to confirm </Text>
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
