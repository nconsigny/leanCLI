import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { formatEthCompact } from "../format.js";
import ChatPane from "../widgets/ChatPane.js";
import type { Phase, WalletBalance } from "./LlmChatFlow.js";
import { useTerminalSize } from "../dashboard/useTerminalSize.js";
import { useRpcConfig } from "../dashboard/rpcstatus.js";
import { useNetFeed, useStatusSnapshot, type NetLogEvent } from "../dashboard/netfeed.js";
import { useLlamaStatus } from "../dashboard/llamamon.js";
import { useSystemStats } from "../dashboard/sysmon.js";
import { useWalletData, type WalletRow } from "../dashboard/walletdata.js";

/**
 * Multiplexed dashboard — the tmux-style home screen. Five always-visible
 * panes over one terminal viewport:
 *
 *   ┌ le chat ───────────────┐┌ wallet ───────────────┐
 *   │ interactive, focused   ││ balances · ERC-20 ·   │
 *   │ by default             ││ shielded (on demand)  │
 *   │                        │├ rpc / light clients ──┤
 *   │                        ││ backend · helios ·    │
 *   │                        ││ colibri · oram-tee    │
 *   │                        │├ network ──────────────┤
 *   │                        ││ egress · traffic fold │
 *   │                        │├ llama.cpp / resources ┤
 *   │                        ││ model · slots · cpu…  │
 *   └────────────────────────┘└───────────────────────┘
 *   [tab] panes · [esc] menu · per-pane hints
 *
 * Input model: ink's useInput is BROADCAST (every mounted hook sees every
 * key), so focus is arbitrated manually — a single `activePane` value;
 * every pane-scoped useInput is gated with {isActive}, and only the chat
 * pane's TextInput ever has focus. Tab is safe as the pane cycler because
 * ink-text-input explicitly ignores it.
 *
 * Trust: this screen is display-only. The only path out of it that can
 * lead to a signature is the chat pane's onApprove handoff, which pushes
 * SendRawFlow (decode → simulate → ConfirmGate) exactly like the full
 * chat. Light-client / ORAM toggles change read plumbing, never signing.
 */

const PANES = ["chat", "wallet", "rpc", "net", "llm"] as const;
type PaneId = (typeof PANES)[number];

const PANE_HINTS: Record<PaneId, string> = {
  chat: "enter send · empty-enter act on draft · ctrl+o full chat · /clear reset",
  wallet: "r refresh · s sync shielded (slow, needs unlock)",
  rpc: "b read-backend · h helios · c colibri · o oram-tee",
  net: "c clear counters",
  llm: "read-only probes of llama-server + /proc",
};

type Props = {
  chatPhase: Phase;
  setChatPhase: React.Dispatch<React.SetStateAction<Phase>>;
  chatWallets: WalletBalance[];
  setChatWallets: React.Dispatch<React.SetStateAction<WalletBalance[]>>;
  onApprove: (
    tx: { to: string; value: string; data: string; rationale?: string; canonical?: string },
    chainId: number,
    wallet?: { kind: "eoa" | "tpm"; name: string; address: string },
  ) => void;
  onCreateWallet: (kind: "eoa" | "r1", label: string | undefined) => void;
  onOpenFullChat: () => void;
  onOpenChatHistory: () => void;
  onBack: () => void;
};

export default function Dashboard({
  chatPhase,
  setChatPhase,
  chatWallets,
  setChatWallets,
  onApprove,
  onCreateWallet,
  onOpenFullChat,
  onOpenChatHistory,
  onBack,
}: Props) {
  const { columns, rows } = useTerminalSize();
  const [activePane, setActivePane] = useState<PaneId>("chat");

  // One-time llm.ensureUp: gets {baseUrl, model} and lazily spawns
  // llama-server if configured. Deliberately NOT polled — the RPC has a
  // spawn side effect; the live loop uses read-only HTTP probes instead.
  const [llmInfo, setLlmInfo] = useState<{ baseUrl: string | null; model?: string; outcome?: string }>(
    { baseUrl: null },
  );
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{ outcome: string; baseUrl?: string; model?: string }>("llm.ensureUp", {});
      if (cancelled) return;
      if (r.ok) {
        setLlmInfo({ baseUrl: r.result.baseUrl ?? null, model: r.result.model, outcome: r.result.outcome });
      } else {
        setLlmInfo({ baseUrl: null, outcome: r.error.message });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // Tiered data sources (cadences chosen by measured cost — see each hook).
  const { cfg, actions } = useRpcConfig(5_000);
  const { snap } = useStatusSnapshot(30_000);
  const feed = useNetFeed(cfg.logPath);
  const llama = useLlamaStatus(llmInfo.baseUrl, 5_000);
  const sys = useSystemStats(2_500);
  const wallet = useWalletData(cfg.chainName);

  // Mirror wallet rows into the lifted chat wallets so draft sender
  // hints can pre-select a signing wallet (and the full chat screen
  // opens with the same context).
  useEffect(() => {
    const derived: WalletBalance[] = wallet.rows
      .filter((r): r is WalletRow & { kind: "eoa" | "tpm" } => r.kind === "eoa" || r.kind === "tpm")
      .slice(0, 5)
      .map((r) => ({ kind: r.kind, name: r.name, address: r.address, wei: r.wei }));
    setChatWallets(derived);
  }, [wallet.rows]);

  // Global pane navigation. Esc always returns to the main menu — chat
  // state is lifted into App, so nothing is lost.
  useInput((_ch, key) => {
    if (key.escape) {
      onBack();
      return;
    }
    if (key.tab) {
      setActivePane((p) => {
        const idx = PANES.indexOf(p);
        const step = key.shift ? PANES.length - 1 : 1;
        return PANES[(idx + step) % PANES.length] ?? "chat";
      });
    }
  });

  // Pane-scoped bare-letter shortcuts. Never active while the chat pane
  // holds focus (its TextInput owns printable keys there).
  useInput(
    (ch) => {
      if (activePane === "wallet") {
        if (ch === "r") wallet.refresh();
        if (ch === "s") wallet.syncShielded();
      } else if (activePane === "rpc") {
        if (ch === "b") actions.cycleReadBackend();
        if (ch === "h") actions.toggleHelios();
        if (ch === "c") actions.toggleColibri();
        if (ch === "o") actions.toggleSafeNode();
      } else if (activePane === "net") {
        if (ch === "c") feed.clear();
      }
    },
    { isActive: activePane !== "chat" },
  );

  if (columns < 96 || rows < 32) {
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text color={theme.warn} bold>
          dashboard needs at least 96×32 — current {columns}×{rows}
        </Text>
        <Text color={theme.dim}>enlarge the terminal, or press esc for the main menu</Text>
      </Box>
    );
  }

  // Height budget. The TUI lives in the alternate screen buffer: anything
  // taller than the viewport is lost, so every pane gets a hard height
  // and renders at most (height - border(2) - title(1)) single lines.
  const H = rows - 1; // one row reserved for the footer
  const chatW = Math.max(50, Math.floor(columns * 0.58));
  const rightW = columns - chatW;
  const rpcH = 9;
  const netH = 8;
  const llmH = 9;
  const walletH = H - rpcH - netH - llmH;

  return (
    <Box flexDirection="column" width={columns}>
      <Box flexDirection="row" width={columns} height={H}>
        <PaneFrame title="le chat" focused={activePane === "chat"} width={chatW} height={H}>
          <ChatPane
            phase={chatPhase}
            setPhase={setChatPhase}
            wallets={chatWallets}
            isFocused={activePane === "chat"}
            contentHeight={H - 3}
            modelName={llmInfo.model}
            onApprove={onApprove}
            onCreateWallet={onCreateWallet}
            onOpenFull={onOpenFullChat}
            onOpenHistory={onOpenChatHistory}
          />
        </PaneFrame>
        <Box flexDirection="column" width={rightW}>
          <PaneFrame title="wallet" focused={activePane === "wallet"} width={rightW} height={walletH}>
            <WalletBox data={wallet} snap={snap} budget={walletH - 3} />
          </PaneFrame>
          <PaneFrame title="rpc / light clients" focused={activePane === "rpc"} width={rightW} height={rpcH}>
            <RpcBox cfg={cfg} pending={actions.pending} budget={rpcH - 3} />
          </PaneFrame>
          <PaneFrame title="network" focused={activePane === "net"} width={rightW} height={netH}>
            <NetBox feed={feed} snap={snap} logPath={cfg.logPath} />
          </PaneFrame>
          <PaneFrame title="llama.cpp / resources" focused={activePane === "llm"} width={rightW} height={llmH}>
            <LlmBox llama={llama} sys={sys} chatPhase={chatPhase} outcome={llmInfo.outcome} />
          </PaneFrame>
        </Box>
      </Box>
      <Text wrap="truncate-end" color={theme.dim}>
        {" tab/shift-tab panes · esc menu · "}
        <Text color={theme.highlight}>{activePane}</Text>
        {" ▸ "}
        {PANE_HINTS[activePane]}
      </Text>
    </Box>
  );
}

/* ---------- frame ---------- */

function PaneFrame({
  title,
  focused,
  width,
  height,
  children,
}: {
  title: string;
  focused: boolean;
  width: number;
  height: number;
  children: React.ReactNode;
}) {
  return (
    <Box
      flexDirection="column"
      width={width}
      height={height}
      borderStyle={focused ? "double" : "single"}
      borderColor={focused ? theme.highlight : theme.dim}
      paddingX={1}
    >
      <Text
        wrap="truncate-end"
        bold
        color={focused ? theme.koiCream : theme.dim}
        backgroundColor={focused ? theme.koiInk : undefined}
      >
        {` ${title} `}
      </Text>
      {children}
    </Box>
  );
}

/** Single truncated line — the only safe row shape inside fixed-height
 *  panes (one physical terminal line, no wrap). */
function Line({ children, color }: { children: React.ReactNode; color?: string }) {
  return (
    <Text wrap="truncate-end" color={color}>
      {children}
    </Text>
  );
}

/* ---------- wallet box ---------- */

function formatUnits(b: bigint, decimals: number): string {
  const base = 10n ** BigInt(decimals);
  const whole = b / base;
  const centi = ((b % base) * 100n) / base;
  return centi === 0n ? `${whole}` : `${whole}.${centi.toString().padStart(2, "0")}`;
}

function WalletBox({
  data,
  snap,
  budget,
}: {
  data: ReturnType<typeof useWalletData>;
  snap: { wallet: { masterUnlocked: boolean; unlockedSlotCount: number } } | null;
  budget: number;
}) {
  const lines: React.ReactElement[] = [];
  lines.push(
    <Line key="master" color={theme.dim}>
      master{" "}
      {snap === null ? (
        "…"
      ) : snap.wallet.masterUnlocked ? (
        <Text color={theme.ok}>unlocked</Text>
      ) : (
        <Text color={theme.warn}>LOCKED</Text>
      )}
      {snap !== null ? ` · ${snap.wallet.unlockedSlotCount} slot(s) open` : ""}
    </Line>,
  );
  if (data.enumErr) {
    lines.push(<Line key="enum-err" color={theme.err}>✗ {data.enumErr}</Line>);
  }
  for (const r of data.rows) {
    lines.push(<WalletHead key={`${r.kind}:${r.name}:h`} r={r} />);
    if (r.address) {
      lines.push(
        <Line key={`${r.kind}:${r.name}:a`} color={theme.dim}>
          {"  "}{r.address}
        </Line>,
      );
    } else {
      // SPHINCS slot whose CREATE2 counterfactual hasn't been computed.
      lines.push(
        <Line key={`${r.kind}:${r.name}:a`} color={theme.warn}>
          {"  address not computed — finish setup in the Wallets hub"}
        </Line>,
      );
    }
    if (r.tokens && r.tokens.length > 0) {
      lines.push(
        <Line key={`${r.kind}:${r.name}:t`} color={theme.accent}>
          {"  "}
          {r.tokens.slice(0, 4).map((t) => `${t.symbol} ${formatUnits(t.balance, t.decimals)}`).join(" · ")}
          {r.tokens.length > 4 ? ` +${r.tokens.length - 4}` : ""}
        </Line>,
      );
    }
  }
  if (data.droppedRows > 0) {
    lines.push(
      <Line key="more" color={theme.dim}>
        … +{data.droppedRows} more wallet(s) — see Wallets hub
      </Line>,
    );
  }
  // shielded section
  if (data.shielded.kind === "idle") {
    lines.push(
      <Line key="sh" color={theme.dim}>
        ⛊ shielded: press <Text color={theme.highlight}>s</Text> to sync (slow · needs unlock)
      </Line>,
    );
  } else if (data.shielded.kind === "syncing") {
    lines.push(
      <Line key="sh" color={theme.primary}>
        ⛊ shielded: <Spinner type="dots" /> syncing — first run can take minutes
      </Line>,
    );
  } else {
    const { railgun, pp } = data.shielded;
    lines.push(
      <Line key="sh" color={theme.koiCream}>
        ⛊ railgun: {"err" in railgun ? <Text color={theme.err}>error</Text> : `${railgun.count} note(s)`}
        {" · pp: "}
        {"err" in pp ? <Text color={theme.err}>error</Text> : `${pp.count} entry(ies)`}
      </Line>,
    );
    const detail: string[] = [];
    if (!("err" in railgun)) detail.push(...railgun.lines.map((l) => `rg ${l}`));
    else detail.push(`rg ✗ ${railgun.err}`);
    if (!("err" in pp)) detail.push(...pp.lines.map((l) => `pp ${l}`));
    else detail.push(`pp ✗ ${pp.err}`);
    for (let i = 0; i < Math.min(2, detail.length); i++) {
      lines.push(
        <Line key={`shd${i}`} color={theme.dim}>
          {"  "}{detail[i]}
        </Line>,
      );
    }
  }
  return <Box flexDirection="column">{lines.slice(0, Math.max(1, budget))}</Box>;
}

function WalletHead({ r }: { r: WalletRow }) {
  return (
    <Line>
      <Text color={theme.dim}>[{r.kind}] </Text>
      <Text bold>{r.name}</Text>
      <Text color={theme.dim}> · {r.chain} · </Text>
      {!r.address ? (
        <Text color={theme.dim}>—</Text>
      ) : r.balErr ? (
        <Text color={theme.err}>balance error</Text>
      ) : r.wei === undefined ? (
        <Text color={theme.dim}>…</Text>
      ) : (
        <Text color={theme.ok}>{formatEthCompact(r.wei, 4)}</Text>
      )}
      {r.locked === true && <Text color={theme.warn}> 🔒</Text>}
    </Line>
  );
}

/* ---------- rpc box ---------- */

function onOff(s: { running: boolean } | null, pendingThis: boolean): React.ReactElement {
  if (pendingThis) return <Text color={theme.dim}>…</Text>;
  if (s === null) return <Text color={theme.dim}>?</Text>;
  return s.running ? <Text color={theme.ok}>● on</Text> : <Text color={theme.dim}>○ off</Text>;
}

function RpcBox({
  cfg,
  pending,
  budget,
}: {
  cfg: ReturnType<typeof useRpcConfig>["cfg"];
  pending: string | null;
  budget: number;
}) {
  const lines: React.ReactElement[] = [
    <Line key="chain" color={theme.dim}>
      chain <Text color={theme.koiCream}>{cfg.chainName ?? "?"}</Text>
      {cfg.chainId !== null ? ` (${cfg.chainId})` : ""} · policy{" "}
      <Text color={theme.koiCream}>{cfg.policy ?? "?"}</Text>
    </Line>,
    <Line key="rpc" color={theme.dim}>
      rpc <Text color={theme.primary}>{cfg.rpcUrl ?? "…"}</Text>
    </Line>,
    <Line key="backend" color={theme.dim}>
      read backend{" "}
      <Text color={theme.highlight} bold>
        {pending === "backend" ? "…" : (cfg.readBackend ?? "?")}
      </Text>
      {cfg.transport ? ` · transport ${cfg.transport}` : ""}
    </Line>,
    <Line key="lc" color={theme.dim}>
      helios {onOff(cfg.helios, pending === "helios")} · colibri{" "}
      {onOff(cfg.colibri, pending === "colibri")} · oram-tee{" "}
      {onOff(cfg.safeNode, pending === "oram-tee")}
    </Line>,
    cfg.oramProxyUrl ? (
      <Line key="oram" color={theme.ok}>⛨ reads exec via ORAM proxy {cfg.oramProxyUrl}</Line>
    ) : cfg.safeNode?.running && cfg.safeNode.attestation ? (
      <Line key="oram" color={theme.dim}>
        ⛨ tee {cfg.safeNode.attestation.teeType ?? "?"} · pin{" "}
        {(cfg.safeNode.attestation.pin ?? "").slice(0, 12)}…
      </Line>
    ) : (
      <Line key="oram" color={theme.dim}>ens {cfg.ensUrl ?? "—"}</Line>
    ),
  ];
  if (cfg.error) {
    lines.push(<Line key="err" color={theme.err}>✗ {cfg.error}</Line>);
  }
  return <Box flexDirection="column">{lines.slice(0, Math.max(1, budget))}</Box>;
}

/* ---------- network box ---------- */

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function NetBox({
  feed,
  snap,
  logPath,
}: {
  feed: ReturnType<typeof useNetFeed>;
  snap: { network: { rpc: { ip: string; egressSrc: string; egressDev: string; host: string } } } | null;
  logPath: string | null | undefined;
}) {
  const ep = snap?.network.rpc;
  const s = feed.stats;
  const avg = s.totalSamples === 0 ? 0 : Math.round(s.totalMs / s.totalSamples);
  const last: NetLogEvent | undefined = feed.recent[feed.recent.length - 1];
  return (
    <Box flexDirection="column">
      <Line color={theme.dim}>
        {/* Local route source for the RPC host — NOT the public/exit IP. */}
        egress src <Text color={theme.koiCream}>{ep?.egressSrc || "…"}</Text>
        {ep?.egressDev ? `@${ep.egressDev}` : ""}
      </Line>
      <Line color={theme.dim}>
        server <Text color={theme.accent}>{s.lastIp ?? ep?.ip ?? "…"}</Text>
        {ep?.host ? ` (${ep.host})` : ""}
      </Line>
      <Line color={theme.dim}>
        req <Text color={theme.primary}>{s.requests}</Text> · ok{" "}
        <Text color={theme.ok}>{s.ok}</Text> · err <Text color={theme.err}>{s.errors}</Text> · denied{" "}
        <Text color={theme.warn}>{s.denied}</Text>
      </Line>
      <Line color={theme.dim}>
        avg <Text color={theme.accent}>{avg}ms</Text> · ↓{" "}
        <Text color={theme.accent}>{formatBytes(s.totalBytes)}</Text>
        {logPath === null ? " · log disabled (LEANCLI_NETWORK_LOG)" : ""}
      </Line>
      {feed.error ? (
        <Line color={theme.err}>✗ {feed.error}</Line>
      ) : s.lastErr ? (
        <Line color={theme.err}>last-err {s.lastErr}</Line>
      ) : (
        <Line color={theme.dim}>
          {last ? `last ${last.kind} ${last.method}${last.host ? ` @${last.host}` : ""}` : "waiting for traffic…"}
        </Line>
      )}
    </Box>
  );
}

/* ---------- llama.cpp / resources box ---------- */

/** tokens/s from the most recent chat turn's llm_call trace item — the
 *  in-band fallback when llama-server runs without --metrics. The TUI's
 *  TraceItem type omits llm_call, so probe the raw objects. */
function traceTokRate(phase: Phase): number | null {
  if (phase.kind !== "chat") return null;
  for (let i = phase.turns.length - 1; i >= 0; i--) {
    const t = phase.turns[i];
    if (t?.kind !== "assistant" || t.status !== "done" || !t.result?.agentTrace) continue;
    const items = t.result.agentTrace as unknown as Record<string, unknown>[];
    for (let j = items.length - 1; j >= 0; j--) {
      const it = items[j];
      if (
        it &&
        it.kind === "llm_call" &&
        typeof it.completionTokens === "number" &&
        typeof it.durationMs === "number" &&
        it.durationMs > 0
      ) {
        return it.completionTokens / (it.durationMs / 1000);
      }
    }
  }
  return null;
}

function LlmBox({
  llama,
  sys,
  chatPhase,
  outcome,
}: {
  llama: ReturnType<typeof useLlamaStatus>;
  sys: ReturnType<typeof useSystemStats>;
  chatPhase: Phase;
  outcome?: string;
}) {
  const tokFallback = traceTokRate(chatPhase);
  const tok =
    llama.tokPerSec !== undefined
      ? { v: llama.tokPerSec, src: llama.tokSrc === "metrics" ? "metrics" : "metrics avg" }
      : tokFallback !== null
        ? { v: tokFallback, src: "last turn" }
        : null;
  const memLine =
    sys.memUsedKb !== null && sys.memTotalKb !== null
      ? `${(sys.memUsedKb / 1048576).toFixed(1)}/${(sys.memTotalKb / 1048576).toFixed(0)}G`
      : "n/a";
  const gpu = sys.gpus[0];
  return (
    <Box flexDirection="column">
      <Line>
        <Text color={theme.koiCream} bold>{llama.model ?? "(model unknown)"}</Text>
        {"  "}
        {llama.up === null ? (
          <Text color={theme.dim}>probing…</Text>
        ) : llama.loading ? (
          <Text color={theme.warn}>◌ loading model</Text>
        ) : llama.up ? (
          <Text color={theme.ok}>● up</Text>
        ) : (
          <Text color={theme.err}>○ down{outcome ? ` (${outcome})` : ""}</Text>
        )}
      </Line>
      <Line color={theme.dim}>
        ctx {llama.nCtx ?? "?"} · slots{" "}
        {llama.slotsAvailable === true
          ? `${llama.slotsBusy ?? "?"}/${llama.totalSlots ?? "?"}`
          : llama.slotsAvailable === false
            ? "n/a"
            : llama.totalSlots !== undefined
              ? `?/${llama.totalSlots}`
              : "…"}
      </Line>
      <Line color={theme.dim}>
        tok/s{" "}
        {tok ? (
          <>
            <Text color={theme.ok}>{tok.v.toFixed(1)}</Text>
            <Text color={theme.dim}> ({tok.src})</Text>
          </>
        ) : (
          "n/a"
        )}
      </Line>
      <Line color={theme.dim}>
        cpu <Text color={theme.primary}>{sys.cpuPct === null ? "…" : `${sys.cpuPct}%`}</Text>
        {" · load "}
        {sys.load1 === null ? "n/a" : `${sys.load1.toFixed(2)}/${sys.cores}`}
        {" · mem "}
        <Text color={theme.primary}>{memLine}</Text>
      </Line>
      <Line color={theme.dim}>
        {gpu
          ? `gpu ${gpu.name}${gpu.utilPct !== undefined ? ` ${gpu.utilPct}%` : ""}${
              gpu.vramUsedMb !== undefined && gpu.vramTotalMb !== undefined
                ? ` · vram ${(gpu.vramUsedMb / 1024).toFixed(1)}/${(gpu.vramTotalMb / 1024).toFixed(0)}G`
                : ""
            }`
          : "gpu: none detected"}
      </Line>
      {(llama.slotsAvailable === false || llama.metricsAvailable === false) && (
        <Line color={theme.dim}>hint: LLM_SPAWN_ARGS="--slots --metrics" enables slots+tok/s</Line>
      )}
    </Box>
  );
}
