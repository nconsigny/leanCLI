import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { call } from "../daemon.js";
import { theme } from "../theme.js";
import { formatEthCompact } from "../format.js";
import ChatPane from "../widgets/ChatPane.js";
import WalletsHub, { type WalletsAction } from "./WalletsHub.js";
import SendRawFlow, { type SendRawWallet } from "./SendRawFlow.js";
import StatusFlow from "./StatusFlow.js";
import type { Wallet } from "../types.js";
import type { CreateKind } from "./CreateWalletPicker.js";
import { newSessionKey, type Phase, type WalletBalance } from "./LlmChatFlow.js";
import { useTerminalSize } from "../dashboard/useTerminalSize.js";
import { useRpcConfig } from "../dashboard/rpcstatus.js";
import { useNetFeed, useStatusSnapshot, type NetLogEvent } from "../dashboard/netfeed.js";
import { useLlamaStatus } from "../dashboard/llamamon.js";
import { useLlmModels } from "../dashboard/llmcontrol.js";
import { usePrivacyStatus } from "../dashboard/settingsdata.js";
import { useSystemStats } from "../dashboard/sysmon.js";
import { useWalletData, type WalletRow } from "../dashboard/walletdata.js";
import Select from "../widgets/Select.js";
import { EmbeddedContext } from "../embedded.js";

/**
 * Multiplexed dashboard — the tmux-style home screen. Five always-visible
 * panes over one terminal viewport:
 *
 *   ┌ le chat ───────────────┐┌ wallet ───────────────┐
 *   │ interactive, focused   ││ balances · ERC-20 ·   │
 *   │ by default             ││ shielded (on demand)  │
 *   │                        │├ rpc / light clients ──┤
 *   │                        ││ provider (rpc/helios/ │
 *   │                        ││ colibri) · oram-tee   │
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

const PANES = ["chat", "wallet", "network", "llm", "settings"] as const;
type PaneId = (typeof PANES)[number];

// Hints for the highlighted pane in the navigation footer (nothing entered).
// Enter activates the highlighted pane; while it's merely highlighted its
// shortcuts are live (chat included — chat is entered for typing via Enter).
const PANE_HINTS: Record<PaneId, string> = {
  chat: "enter to type · ctrl+o full chat",
  wallet: "enter open hub · o full-screen hub · r refresh · s sync shielded",
  network: "enter open Status · r refresh · live RPC / light-client / egress",
  llm: "enter open model manager · m launch model · read-only probes",
  settings: "enter open settings · p provider (rpc/helios/colibri) · o oram · x more",
};

type Props = {
  chatPhase: Phase;
  setChatPhase: React.Dispatch<React.SetStateAction<Phase>>;
  chatWallets: WalletBalance[];
  setChatWallets: React.Dispatch<React.SetStateAction<WalletBalance[]>>;
  /** Surface a broadcast outcome (from the in-pane send) back into the
   *  chat conversation — wired to App's `injectBroadcastIntoChat`. The
   *  approve→sign flow itself now renders INSIDE the dashboard's main
   *  pane (see `pendingSend`), so the dashboard no longer pushes a
   *  full-screen send; it only needs the chat-injection callback. */
  onChatBroadcastResult: (success: boolean, result?: unknown) => void;
  onCreateWallet: (kind: "eoa", label: string | undefined) => void;
  onOpenFullChat: () => void;
  onOpenChatHistory: () => void;
  /** Expand the focused pane to its dedicated full screen. */
  onOpenWallets: () => void;
  /** Launch a wallet SEND/SWAP/SHIELD/UNSHIELD/MANAGE flow for the
   *  embedded hub — wired to App's `handleHubPick`, which pushes the
   *  corresponding full-screen flow on top of the dashboard. */
  onWalletAction: (action: WalletsAction, wallet: Wallet, chain: string) => void;
  /** CREATE tab in the embedded hub → push a create/add/import flow. */
  onWalletCreate: (kind: CreateKind) => void;
  onOpenStatus: () => void;
  onOpenNetworkMonitor: () => void;
  /** Trusted-registry screen (reached from the embedded Status pane). */
  onOpenTrustedRegistry: () => void;
  /** More-commands sub-menu (resolve · decode · archived · daemon),
   *  surfaced from the settings pane. */
  onOpenMore: () => void;
  /** A sub-flow (wallet SEND/SWAP/MANAGE, CREATE, More commands, …) that
   *  App injects into the MAIN pane instead of replacing the dashboard.
   *  When set it owns input (modal) and renders in place of the pane
   *  root; the dashboard stays mounted so pane state persists. */
  mainOverlay?: React.ReactNode;
  onBack: () => void;
};

export default function Dashboard({
  chatPhase,
  setChatPhase,
  chatWallets,
  setChatWallets,
  onChatBroadcastResult,
  onCreateWallet,
  onOpenFullChat,
  onOpenChatHistory,
  onOpenWallets,
  onWalletAction,
  onWalletCreate,
  onOpenStatus,
  onOpenNetworkMonitor,
  onOpenTrustedRegistry,
  onOpenMore,
  mainOverlay,
  onBack,
}: Props) {
  const { columns, rows } = useTerminalSize();
  const [activePane, setActivePane] = useState<PaneId>("chat");
  const llmModels = useLlmModels();
  const privacy = usePrivacyStatus(10_000);
  // Which pane occupies the big left slot. `chat` is the default and is
  // NOT modal. Any other pane swapped in (Enter) becomes a focused modal
  // that owns all keys; the dashboard's global + pane-scoped handlers
  // stand down so r/enter/esc don't collide, and esc inside swaps back.
  const [mainPane, setMainPane] = useState<PaneId>("chat");
  // Whether the chat pane has been ENTERED for typing. Chat behaves like
  // every other pane: highlighting it (Tab) only selects it — the footer
  // hints and pane shortcuts stay live — and Enter enters typing mode. Esc
  // leaves. It persists across Tab the same way a non-chat pane stays in the
  // main slot, so Tab'ing off chat and back resumes typing without re-Enter.
  const [chatTyping, setChatTyping] = useState<boolean>(false);
  // A chat-approved draft, captured locally so the decode→simulate→
  // ConfirmGate→sign flow renders IN the main pane instead of taking
  // over the whole screen. Only ever set while the chat pane is the
  // main pane and focused (approve can't fire otherwise), so it
  // overrides `renderMain` regardless of `mainPane`. Trust path is
  // unchanged — it's the same SendRawFlow, just embedded.
  const [pendingSend, setPendingSend] = useState<{
    tx: { to: string; value: string; data: string; rationale?: string; canonical?: string };
    chainId: number;
    wallet?: SendRawWallet;
  } | null>(null);
  const sendActive = pendingSend !== null;
  const overlayActive = mainOverlay != null;
  // The highlighted pane "owns" the keyboard (it's been entered/activated).
  // Uniform across panes: the highlight must be on the main-slot pane, AND
  // either it's a non-chat pane (in the slot = entered) or it's chat that
  // has been entered for typing (`chatTyping`). Tab'ing the highlight off it
  // drops this to false → the dashboard's nav + footer hints take back over.
  const modalFocused =
    activePane === mainPane && (mainPane !== "chat" || chatTyping);
  // Modal = main slot owns all keys; the dashboard's global + pane-scoped
  // handlers stand down. A focused expanded pane, an in-pane send, OR an
  // App-injected sub-flow overlay all count.
  const modalActive = modalFocused || sendActive || overlayActive;

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
  // The wallet pane is ALWAYS visible on the dashboard, so poll its balance
  // whenever the dashboard is mounted (every 60s — minimal, and token
  // discovery is already hub-only). usePoll stops automatically when the
  // dashboard unmounts for a full-screen view, so there's no background
  // polling while you're off the dashboard. (Gating this on wallet-focus was
  // wrong: it left the always-visible pane stale until focused — the "slow on
  // the dashboard, fast in the hub" symptom.)
  const wallet = useWalletData(cfg.chainName);

  // Mirror wallet rows into the lifted chat wallets so draft sender
  // hints can pre-select a signing wallet (and the full chat screen
  // opens with the same context).
  useEffect(() => {
    // Mirror BOTH signer kinds (eoa + sphincs) so a draft whose sender
    // hint is a SPHINCS smart account resolves and the confirm flow
    // pre-selects it. Skip address-less rows (an uncomputed SPHINCS
    // counterfactual) — they can't be a signing target yet and would
    // produce an un-pickable pre-select.
    const derived: WalletBalance[] = wallet.rows
      .filter((r): r is WalletRow & { kind: "eoa" | "sphincs" } =>
        (r.kind === "eoa" || r.kind === "sphincs") && !!r.address)
      .slice(0, 5)
      .map((r) => ({ kind: r.kind, name: r.name, address: r.address, wei: r.wei }));
    setChatWallets(derived);
  }, [wallet.rows]);

  // Global pane navigation. Esc always returns to the main menu — chat
  // state is lifted into App, so nothing is lost.
  // Cycle the daemon-wide active chain (global ctrl+n). Switches the
  // daemon's default via network.use AND rotates the chat to a fresh
  // session on the new chain — "switching chains switches sessions".
  const cycleChain = () => {
    const list = cfg.perChain;
    if (list.length < 2) return;
    const curId = cfg.chainId ?? list.find((c) => c.isCurrent)?.chainId ?? list[0]?.chainId;
    const idx = list.findIndex((c) => c.chainId === curId);
    const next = list[(idx + 1) % list.length] ?? list[0];
    if (!next) return;
    actions.setChain(next.chainId);
    setChatPhase({
      kind: "chat",
      chainId: next.chainId,
      chainName: next.name,
      modelName: llmInfo.model,
      turns: [],
      input: "",
      busy: false,
      sessionKey: newSessionKey(),
    });
  };

  const nextPane = (cur: PaneId, shift: boolean): PaneId => {
    // Tab order follows the visual layout: the main pane first, then the
    // side rail top-to-bottom (same order renderSummary lays them out).
    // Keeping the main pane at the head — instead of its fixed PANES slot —
    // means tabbing past the last rail pane returns straight to the main
    // pane, so no pane is visited twice in a cycle.
    const order: PaneId[] = [mainPane, ...PANES.filter((p) => p !== mainPane)];
    const idx = order.indexOf(cur);
    const step = shift ? order.length - 1 : 1;
    return order[(idx + step) % order.length] ?? mainPane;
  };

  useInput(
    (ch, key) => {
      if (key.escape) {
        // While a chat draft is in flight, Esc means "stop generating" —
        // ChatPane owns that (it aborts the request and keeps you in the
        // chat). Yield the key to it: don't also drop out of typing mode.
        if (
          chatTyping &&
          activePane === "chat" &&
          chatPhase.kind === "chat" &&
          chatPhase.busy
        ) {
          return;
        }
        // Leaving chat typing comes first: esc stops typing → back to nav.
        if (chatTyping) {
          setChatTyping(false);
          return;
        }
        if (mainPane !== "chat") {
          // A pane is expanded. If the highlight is still ON it, esc belongs
          // to that pane's own handler (it collapses back to chat). If the
          // highlight has Tab'd off it, the modal isn't listening, so we
          // collapse the view here.
          if (activePane !== mainPane) setMainPane("chat");
          return;
        }
        // Navigation on chat: esc backs out to the main menu.
        onBack();
        return;
      }
      // Global chain switch — works from any pane (incl. while typing in
      // chat, since it's a ctrl-combo the TextInput ignores).
      if (key.ctrl && ch === "n") {
        cycleChain();
        return;
      }
      if (key.tab) {
        // One rule everywhere: Tab navigates, Enter activates. Tab only
        // moves the selection highlight — in BOTH the multiplexed view and
        // while a pane is expanded. It never swaps the main slot by itself;
        // the pane-scoped Enter handler below does that. Tab'ing off an
        // expanded pane hands keys back to the dashboard (modalFocused → false).
        setActivePane((p) => nextPane(p, key.shift));
      }
    },
    // Active in the multiplexed view AND while a pane is swapped in (so
    // tab/ctrl+n keep working); only a sub-flow overlay or in-pane send
    // takes the keys away entirely.
    { isActive: !overlayActive && !sendActive },
  );

  // Pane navigation commit + pane-scoped shortcuts. Active in the
  // multiplexed view and in an expanded view after Tab'ing the highlight
  // off the focused modal; stands down only while a pane is the focused
  // modal (it owns its keys) or a send/overlay is up.
  useInput(
    (ch, key) => {
      // Enter ACTIVATES the highlighted pane. Chat → bring it to the main
      // slot and enter typing mode. Any other pane → bring it into the main
      // slot (wallet→hub, network→Status, llm→model manager, settings→toggles).
      // Tab never changes the main slot; only this does.
      if (key.return) {
        if (activePane === "chat") {
          setMainPane("chat");
          setChatTyping(true);
        } else if (activePane !== mainPane) {
          setMainPane(activePane);
          setChatTyping(false);
        }
        return;
      }
      // Printable per-pane shortcuts. Skipped only while CHAT is the
      // highlighted pane (Enter there opens typing; we don't want letters
      // doing pane actions while chat is selected). With the highlight on any
      // other pane, r/s/o/p/m act on it — works in the multiplexed view too.
      if (activePane === "chat") return;
      // `r` refreshes wallet balances from ANY non-chat pane — a quick
      // "update my balances"; no other pane binds `r`.
      if (ch === "r") wallet.refresh();
      if (activePane === "wallet") {
        if (ch === "s") wallet.syncShielded();
        if (ch === "o") onOpenWallets();
      } else if (activePane === "settings") {
        // Single-select provider cycle (rpc → helios → colibri) flips the
        // backend + light-client sidecars together; ORAM is an orthogonal
        // on/off layer over whichever provider is active.
        if (ch === "p") actions.cycleProvider();
        if (ch === "o") actions.toggleSafeNode();
        if (ch === "x") onOpenMore();
      } else if (activePane === "llm") {
        if (ch === "m") setMainPane("llm");
      }
    },
    { isActive: !modalActive },
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
  // Pane-row height. Total frame = H (pane row) + 1 (footer). We reserve
  // TWO rows, not one: a frame that exactly fills the viewport makes many
  // terminals scroll when the last cell is written, pushing the top line
  // above the viewport — and Ink can't erase a line that scrolled off, so
  // on the way back to the menu it leaks through as a "ghost dashboard".
  // Leaving one blank row at the bottom keeps the frame strictly inside
  // the viewport so Ink's own eraseLines fully clears it on transition.
  const H = rows - 2;
  const chatW = Math.max(50, Math.floor(columns * 0.58));
  const rightW = columns - chatW;

  // Right-column height budget. llm/settings get fixed compact heights;
  // network SCALES with the viewport. It's the best at-a-glance pane
  // (chain · provider · light-client · verified · egress · live request
  // tail), so it stays compact on a small terminal (≈11 rows — wallet was
  // getting starved otherwise) but grows toward 20 in full screen, where
  // the extra rows surface more of the request tail instead of whitespace.
  // The flexible pane(s) — wallet and/or chat — take the remainder, so a
  // taller network trims the top pane by the same amount.
  const networkH = Math.max(11, Math.min(20, Math.floor(H * 0.34)));
  const FIXED: Partial<Record<PaneId, number>> = { network: networkH, llm: 9, settings: 6 };
  const sidePanes = PANES.filter((p) => p !== mainPane);
  const fixedTotal = sidePanes.reduce((a, p) => a + (FIXED[p] ?? 0), 0);
  const flexCount = sidePanes.filter((p) => FIXED[p] === undefined).length;
  const remainder = Math.max(6, H - fixedTotal);
  const heightOf = (p: PaneId): number => {
    if (FIXED[p] !== undefined) return FIXED[p]!;
    if (flexCount <= 1) return remainder;
    // chat + wallet both in side: wallet takes the larger share.
    const walletShare = Math.max(8, Math.floor(remainder * 0.55));
    return p === "wallet" ? walletShare : Math.max(6, remainder - walletShare);
  };

  // --- compact (side-column) renderers -----------------------------------
  // `isMain` controls the koi: it's the main pane's identity cue, so a
  // demoted side-column chat suppresses it.
  const renderChat = (w: number, h: number, isMain = false) => (
    <PaneFrame title="le chat" focused={activePane === "chat"} width={w} height={h}>
      <ChatPane
        phase={chatPhase}
        setPhase={setChatPhase}
        wallets={chatWallets}
        // Chat is writable only once ENTERED (Enter on the highlighted chat
        // pane → `chatTyping`) and while the highlight is on it. Merely
        // highlighting chat selects it without grabbing keys, so the footer
        // hints and other panes' shortcuts stay live; Esc leaves typing.
        isFocused={chatTyping && activePane === "chat"}
        contentHeight={h - 3}
        showKoi={isMain}
        modelName={llmInfo.model}
        onApprove={(tx, chainId, wallet) => setPendingSend({ tx, chainId, wallet })}
        onCreateWallet={onCreateWallet}
        onOpenFull={onOpenFullChat}
        onOpenHistory={onOpenChatHistory}
      />
    </PaneFrame>
  );
  const renderSummary = (p: PaneId, w: number, h: number) => {
    switch (p) {
      case "chat":
        return renderChat(w, h);
      case "wallet":
        return (
          <PaneFrame title="wallet" focused={activePane === "wallet"} width={w} height={h}>
            <WalletBox data={wallet} snap={snap} budget={h - 3} />
          </PaneFrame>
        );
      case "network":
        return (
          <PaneFrame title="network / status" focused={activePane === "network"} width={w} height={h}>
            <NetworkBox cfg={cfg} pending={actions.pending} feed={feed} snap={snap} budget={h - 3} />
          </PaneFrame>
        );
      case "llm":
        return (
          <PaneFrame title="llama.cpp / resources" focused={activePane === "llm"} width={w} height={h}>
            <LlmBox llama={llama} sys={sys} chatPhase={chatPhase} outcome={llmInfo.outcome} />
          </PaneFrame>
        );
      case "settings":
        return (
          <PaneFrame title="settings" focused={activePane === "settings"} width={w} height={h}>
            <SettingsBox cfg={cfg} privacy={privacy} budget={h - 3} />
          </PaneFrame>
        );
    }
  };

  // --- expanded (main-slot) view; non-chat panes are focused modals ------
  const renderMain = () => {
    // A chat-approved draft takes over the main slot: the full pre-sign
    // pipeline (decode → simulate → ConfirmGate → sign) renders here as a
    // focused modal. `overflow="hidden"` clips the (narrower → taller)
    // confirm card to the pane rather than letting it scroll the buffer.
    // onDone returns to chat and surfaces the broadcast result there.
    if (pendingSend) {
      return (
        <Box width={chatW} height={H} flexDirection="column" overflow="hidden">
          <EmbeddedContext.Provider value={true}>
            <SendRawFlow
              tx={pendingSend.tx}
              chainId={pendingSend.chainId}
              wallet={pendingSend.wallet}
              onDone={(success, result) => {
                onChatBroadcastResult(success, result);
                setPendingSend(null);
              }}
            />
          </EmbeddedContext.Provider>
        </Box>
      );
    }
    // App-injected sub-flow (wallet hub action, CREATE, More commands, …)
    // renders here, over whatever pane is in the main slot, keeping the
    // dashboard shell + side panes visible. The flow owns input; its own
    // esc/back pops the sub-stack and returns to the pane root.
    if (mainOverlay) {
      return (
        <Box width={chatW} height={H} flexDirection="column" overflow="hidden">
          {/* Injected sub-flows (wallet hub action, SPHINCS hub, CREATE,
              More commands, …) render "embedded": KoiFrame (→ Layout /
              RpcRunner) drops the 24-col koi so the squeezed-in flow fits
              the ~58%-width slot. The static panes (wallet hub, Status)
              keep their koi — they have room. */}
          <EmbeddedContext.Provider value={true}>
            {mainOverlay}
          </EmbeddedContext.Provider>
        </Box>
      );
    }
    switch (mainPane) {
      case "chat":
        return renderChat(chatW, H, true);
      case "wallet":
        // WalletsHub paints its own "Wallets" title via Layout, so we add a
        // focus-coloured border (no extra title line) to match the blue
        // focus cue every other main pane shows.
        return (
          <Box
            width={chatW}
            height={H}
            flexDirection="column"
            borderStyle={modalFocused ? "double" : "single"}
            borderColor={modalFocused ? theme.highlight : theme.dim}
          >
            <WalletsHub
              isActive={modalFocused}
              onPick={(a, wal, chain) => onWalletAction(a, wal, chain)}
              onCreate={onWalletCreate}
              onBack={() => setMainPane("chat")}
            />
          </Box>
        );
      case "network":
        // StatusFlow paints its own title via Layout; add the matching
        // focus-coloured border (no extra title line) for a consistent cue.
        return (
          <Box
            width={chatW}
            height={H}
            flexDirection="column"
            borderStyle={modalFocused ? "double" : "single"}
            borderColor={modalFocused ? theme.highlight : theme.dim}
          >
            <StatusFlow
              isActive={modalFocused}
              onLiveMonitor={onOpenNetworkMonitor}
              onTrustedRegistry={onOpenTrustedRegistry}
              onBack={() => setMainPane("chat")}
            />
          </Box>
        );
      case "llm":
        return (
          <PaneFrame title="llama.cpp / model manager" focused={modalFocused} width={chatW} height={H}>
            <LlmManager
              isActive={modalFocused}
              control={llmModels}
              llama={llama}
              sys={sys}
              chatPhase={chatPhase}
              outcome={llmInfo.outcome}
              onBack={() => setMainPane("chat")}
            />
          </PaneFrame>
        );
      case "settings":
        return (
          <PaneFrame title="settings" focused={modalFocused} width={chatW} height={H}>
            <SettingsManager
              isActive={modalFocused}
              cfg={cfg}
              actions={actions}
              privacy={privacy}
              onOpenMore={onOpenMore}
              onBack={() => setMainPane("chat")}
            />
          </PaneFrame>
        );
    }
  };

  // Footer shown while a pane is ENTERED (owns the keyboard) — one per pane,
  // plus the in-pane send/overlay flows.
  const modalFooter = overlayActive
    ? "in-pane flow · ←/esc back · dashboard stays open"
    : sendActive
    ? "review & sign in pane · enter confirm · esc cancel"
    : mainPane === "chat"
      ? "type your message · enter send · empty-enter act on draft · ctrl+o full chat · /clear reset · esc stop typing"
      : mainPane === "wallet"
        ? "←/→ action · ↑/↓ wallet · enter run · n chain · r refresh · a archive · tab pane · esc back to chat"
        : mainPane === "network"
          ? "r refresh · m live monitor · t trusted registry · tab pane · esc back to chat"
          : mainPane === "llm"
            ? "↑/↓ model · enter launch · tab pane · esc back to chat"
            : "↑/↓ move · enter select · tab pane · esc back to chat";

  return (
    <Box flexDirection="column" width={columns}>
      <Box flexDirection="row" width={columns} height={H}>
        {renderMain()}
        <Box flexDirection="column" width={rightW}>
          {sidePanes.map((p) => (
            <React.Fragment key={p}>{renderSummary(p, rightW, heightOf(p))}</React.Fragment>
          ))}
        </Box>
      </Box>
      {modalActive ? (
        <Text wrap="truncate-end" color={theme.dim}>
          {` ${overlayActive ? "flow" : sendActive ? "send" : mainPane} ▸ ${modalFooter}`}
        </Text>
      ) : (
        <Text wrap="truncate-end" color={theme.dim}>
          {" tab panes · esc menu · ctrl+n chain · "}
          <Text color={theme.highlight}>{activePane}</Text>
          {" ▸ "}
          {PANE_HINTS[activePane]}
        </Text>
      )}
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

function formatTokenUnits(b: bigint, decimals: number, maxFrac = 6): string {
  const base = 10n ** BigInt(decimals);
  const whole = b / base;
  const frac = b % base;
  if (frac === 0n || maxFrac <= 0) return whole.toString();
  const scale = 10n ** BigInt(Math.min(decimals, maxFrac));
  const shown = (frac * scale) / base;
  if (shown === 0n) return `${whole}.<${"0".repeat(Math.min(decimals, maxFrac) - 1)}1`;
  const trimmed = shown.toString().padStart(Math.min(decimals, maxFrac), "0").replace(/0+$/, "");
  return `${whole}.${trimmed}`;
}

function joinAaveTokens(
  reserves: NonNullable<ReturnType<typeof useWalletData>["rows"][number]["defiAave"]>["reserves"],
  side: "supplied" | "borrowed",
): string {
  const parts = reserves
    .map((r) => {
      const amount = side === "supplied" ? r.supplied : r.borrowed;
      return amount > 0n ? `${formatTokenUnits(amount, r.decimals)} ${r.symbol}` : null;
    })
    .filter((x): x is string => !!x);
  return parts.length > 0 ? parts.join(" · ") : "0";
}

/** `$` amount from a base-currency uint256 (Aave base ccy = USD, 8 dp). */
function formatUsdBase(b: bigint, decimals: number): string {
  return `$${formatUnits(b, decimals)}`;
}

/** Health factor: 1e18-scaled to 2 dp, or ∞ when there's no debt (the
 *  Pool returns uint256-max). */
function formatHf(hf: bigint, debt: bigint): string {
  if (debt === 0n) return "∞";
  return formatUnits(hf, 18);
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
    // DeFi: only render when there's an open Aave position, to keep the
    // pane uncluttered for wallets without one. Morpho/Curve are
    // "coming soon" and intentionally not shown on the dashboard.
    if (r.defiAave) {
      const d = r.defiAave;
      const supplied = d.reserves.length > 0
        ? joinAaveTokens(d.reserves, "supplied")
        : formatUsdBase(d.collateralBase, d.baseDecimals);
      const borrowed = d.reserves.length > 0
        ? joinAaveTokens(d.reserves, "borrowed")
        : formatUsdBase(d.debtBase, d.baseDecimals);
      lines.push(
        <Line key={`${r.kind}:${r.name}:defi`} color={theme.koiCream}>
          {"  ⚓ Aave "}
          supplied {supplied} · borrowed {borrowed} · HF {formatHf(d.healthFactor, d.debtBase)}
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
        <Text color={theme.dim}>
          <Spinner type="dots" />
        </Text>
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
      provider{" "}
      <Text color={theme.highlight} bold>
        {pending === "provider" ? "…" : (cfg.readBackend ?? "?")}
      </Text>
      {cfg.transport ? ` · transport ${cfg.transport}` : ""}
    </Line>,
    <Line key="lc" color={theme.dim}>
      light-client{" "}
      {cfg.readBackend === "helios"
        ? onOff(cfg.helios, pending === "provider")
        : cfg.readBackend === "colibri"
          ? onOff(cfg.colibri, pending === "provider")
          : <Text color={theme.dim}>○ none (rpc)</Text>}
      {" · oram-tee "}
      {onOff(cfg.safeNode, pending === "oram-tee")}
    </Line>,
    // The headline answer to "am I verified?": balances, reads (eth_call,
    // latest nonce, in-window logs) AND tx.simulate all route through the
    // active light client and are consensus-verified — ONLY when the matching
    // sidecar is actually running (backend=helios with the sidecar down is NOT
    // verified). Unverifiable-by-design reads (pending nonce, gas/fee
    // heuristics, deep logs) degrade helios→colibri→direct; those are the
    // exception, not the rule, so the headline says reads ARE verified.
    (() => {
      const rb = cfg.readBackend;
      const v =
        rb === "helios" && cfg.helios?.running
          ? { c: theme.ok, t: "✓ verified: balances + reads + simulate via helios" }
          : rb === "colibri" && cfg.colibri?.running
            ? { c: theme.ok, t: "✓ verified: balances + reads + simulate via colibri" }
            : rb === "helios"
              ? { c: theme.warn, t: "⚠ backend=helios but sidecar OFF — reads NOT verified" }
              : rb === "colibri"
                ? { c: theme.warn, t: "⚠ backend=colibri but sidecar OFF — reads NOT verified" }
                : { c: theme.dim, t: "reads use raw RPC — not consensus-verified" };
      return (
        <Line key="verified" color={v.c}>
          {v.t}
        </Line>
      );
    })(),
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

/* ---------- network / status box (merged rpc + net summary) ---------- */

/** Compact merge of the rpc/light-client summary (RpcBox) with a one-line
 *  egress/totals readout AND a live request tail (the last few events from
 *  the same JSONL feed the standalone Network monitor tails). Full detail
 *  (sidecars, chains, restart actions, the full scrolling log) lives in the
 *  embedded Status / monitor screens — Enter on this pane. */
function NetworkBox({
  cfg,
  pending,
  feed,
  snap,
  budget,
}: {
  cfg: ReturnType<typeof useRpcConfig>["cfg"];
  pending: string | null;
  feed: ReturnType<typeof useNetFeed>;
  snap: { network: { rpc: { ip: string; egressSrc: string; egressDev: string; host: string } } } | null;
  budget: number;
}) {
  const s = feed.stats;
  // Vertical budget split: the rpc/light-client summary keeps priority (it's
  // the "am I verified" headline), one line for egress + totals, then the
  // live request tail. The tail grows with the pane — 0 rows when cramped,
  // up to 5 in full screen — so a tall network pane shows real traffic
  // instead of whitespace, and a short one degrades to just the summary.
  const egressLines = 1;
  const tailRows = Math.max(0, Math.min(5, budget - 5 - egressLines - 1)); // -1: tail header
  const rpcBudget = Math.max(3, budget - egressLines - (tailRows > 0 ? tailRows + 1 : 0));
  const tail = tailRows > 0 ? feed.recent.slice(-tailRows) : [];
  return (
    <Box flexDirection="column">
      <RpcBox cfg={cfg} pending={pending} budget={rpcBudget} />
      <Line color={theme.dim}>
        egress <Text color={theme.koiCream}>{snap?.network.rpc.egressSrc || "…"}</Text>
        {" · req "}<Text color={theme.primary}>{s.requests}</Text>
        {" · ok "}<Text color={theme.ok}>{s.ok}</Text>
        {" · err "}<Text color={theme.err}>{s.errors}</Text>
        {" · denied "}<Text color={theme.warn}>{s.denied}</Text>
      </Line>
      {tailRows > 0 && (
        <>
          <Line color={theme.dim}>recent ▾ last {tailRows}{feed.error ? ` · ${feed.error}` : ""}</Line>
          {tail.length === 0 ? (
            <Line color={theme.dim}>{"  · no traffic yet"}</Line>
          ) : (
            tail.map((e, i) => <NetEventLine key={`${e.ts_ms}-${i}`} e={e} />)
          )}
        </>
      )}
    </Box>
  );
}

/** One truncated line per network event in the dashboard's request tail —
 *  a condensed cousin of NetworkMonitor's EventRow (glyph · method · host/
 *  backend · ms). Errors/denials show the error text in place of the host. */
function NetEventLine({ e }: { e: NetLogEvent }) {
  const isErr = e.kind === "rpc-error" || e.kind === "exception" || e.kind === "parse-error" || e.kind === "malformed";
  const glyph = e.kind === "request" ? "→" : e.kind === "response" ? "←" : isErr ? "✗" : e.kind === "denied" ? "⊘" : "·";
  const color = e.kind === "response" ? theme.ok : isErr ? theme.err : e.kind === "denied" ? theme.warn : theme.dim;
  const detail =
    isErr || e.kind === "denied"
      ? typeof e.error === "string"
        ? e.error
        : e.error
          ? JSON.stringify(e.error)
          : e.kind
      : e.host ?? e.backend ?? "";
  const ms = e.ms !== undefined ? ` ${e.ms}ms` : "";
  return (
    <Line>
      <Text color={color}>{glyph} </Text>
      <Text color={theme.primary}>{e.method || "?"}</Text>
      <Text color={theme.dim}>{detail ? ` ${detail}` : ""}{ms}</Text>
    </Line>
  );
}

/* ---------- settings box (backend + light-clients + privacy) ---------- */

/** Compact settings summary: active read backend, light-client states,
 *  and the privacy allow-list (display-only). */
function SettingsBox({
  cfg,
  privacy,
  budget,
}: {
  cfg: ReturnType<typeof useRpcConfig>["cfg"];
  privacy: ReturnType<typeof usePrivacyStatus>;
  budget: number;
}) {
  const lines: React.ReactElement[] = [
    <Line key="be" color={theme.dim}>
      provider <Text color={theme.highlight} bold>{cfg.readBackend ?? "?"}</Text>
    </Line>,
    <Line key="lc" color={theme.dim}>
      light-client{" "}
      {cfg.readBackend === "helios"
        ? onOff(cfg.helios, false)
        : cfg.readBackend === "colibri"
          ? onOff(cfg.colibri, false)
          : <Text color={theme.dim}>○ none (rpc)</Text>}
      {" · oram "}
      {onOff(cfg.safeNode, false)}
    </Line>,
    <Line key="pv" color={theme.dim}>
      privacy{" "}
      {privacy.enabledPrivacy.length > 0 ? (
        <Text color={theme.koiCream}>{privacy.enabledPrivacy.join(", ")}</Text>
      ) : (
        <Text color={theme.dim}>none</Text>
      )}
    </Line>,
    <Line key="pr" color={theme.dim}>
      provider <Text color={theme.koiCream}>{privacy.provider ?? "?"}</Text>
    </Line>,
  ];
  return <Box flexDirection="column">{lines.slice(0, Math.max(1, budget))}</Box>;
}

/** Expanded settings view (main slot): live backend cycle + light-client
 *  toggles (these RPCs exist), and a display-only privacy section (the
 *  allow-list is boot-time `LEANCLI_PRIVACY` — no runtime toggle). */
function onOffText(s: { running: boolean } | null, pendingThis: boolean): string {
  if (pendingThis) return "…";
  if (s === null) return "?";
  return s.running ? "on" : "off";
}

/** Expanded settings view (main slot): an arrow-navigable menu (↑/↓ +
 *  enter) like the main menu. Rows toggle the read backend / light
 *  clients live (those RPCs exist) or open More commands. The privacy
 *  allow-list stays a display-only footer (boot-time LEANCLI_PRIVACY). */
function SettingsManager({
  isActive,
  cfg,
  actions,
  privacy,
  onOpenMore,
  onBack,
}: {
  isActive: boolean;
  cfg: ReturnType<typeof useRpcConfig>["cfg"];
  actions: ReturnType<typeof useRpcConfig>["actions"];
  privacy: ReturnType<typeof usePrivacyStatus>;
  onOpenMore: () => void;
  onBack: () => void;
}) {
  // Esc backs out; ←/→/↑/↓ + enter are owned by the Select below. Stands
  // down entirely when the dashboard highlight has Tab'd off this pane.
  useInput(
    (_ch, key) => {
      if (key.escape) onBack();
    },
    { isActive },
  );
  const items = [
    {
      label: `Provider — ${actions.pending === "provider" ? "…" : (cfg.readBackend ?? "?")}  (enter cycles rpc → helios → colibri)`,
      value: "provider",
      key: "provider",
    },
    {
      label: `ORAM-TEE proxy — ${onOffText(cfg.safeNode, actions.pending === "oram-tee")}  (layers over the active provider)`,
      value: "oram",
      key: "oram",
    },
    {
      label: "More commands → resolve · decode intent / typed-data · archived accounts · daemon",
      value: "more",
      key: "more",
    },
  ];
  const run = (v: string) => {
    if (v === "provider") actions.cycleProvider();
    else if (v === "oram") actions.toggleSafeNode();
    else if (v === "more") onOpenMore();
  };
  return (
    <Box flexDirection="column">
      <Line color={theme.dim}>↑/↓ move · enter select · esc back to chat</Line>
      <Box marginTop={1} flexDirection="column">
        <Select
          items={items}
          isFocused={isActive}
          onSelect={(it) => run((it as { value: string }).value)}
        />
      </Box>
      <Box marginTop={1}>
        <Line color={theme.koiCream}>Privacy plugins</Line>
      </Box>
      <Line color={theme.dim}>
        enabled:{" "}
        {privacy.enabledPrivacy.length > 0 ? (
          <Text color={theme.koiCream}>{privacy.enabledPrivacy.join(", ")}</Text>
        ) : (
          <Text color={theme.dim}>none</Text>
        )}
        {"  ·  provider: "}
        <Text color={theme.koiCream}>{privacy.provider ?? "?"}</Text>
      </Line>
      <Line color={theme.dim}>
        set at boot via LEANCLI_PRIVACY — edit daemon.env & restart to change.
      </Line>
    </Box>
  );
}

/* ---------- llama.cpp model launch picker ---------- */

/**
 * Full-screen overlay (opened with `m` on the llm pane) to switch the
 * local model. Lists the operator's predefined launch profiles
 * (LLM_MODELS_CONFIG); selecting one calls `llm.launch`, which stops the
 * running llama-server and spawns the chosen profile. Read-backend
 * plumbing only — never a signing path. Esc returns to the dashboard;
 * the live pane poll then shows the new model loading → up.
 */
function LlmLaunchPicker({
  isActive,
  control,
  onClose,
}: {
  isActive: boolean;
  control: ReturnType<typeof useLlmModels>;
  onClose: () => void;
}) {
  // Esc closes whenever we're not mid-launch (don't strand a spawn). Stands
  // down when the dashboard highlight has Tab'd off the llm pane.
  useInput(
    (_ch, key) => {
      if (key.escape && control.pending === null) onClose();
    },
    { isActive },
  );

  const items = control.models.map((m) => ({
    label: m.description ? `${m.name} — ${m.description}` : m.name,
    value: m.name,
    key: m.name,
  }));

  return (
    <Box flexDirection="column" paddingX={1}>
      <Text color={theme.koiCream} bold>
        launch local model{" "}
        <Text color={theme.dim}>· stops the running llama-server first</Text>
      </Text>
      <Box marginTop={1} flexDirection="column">
        {!control.loaded ? (
          <Text color={theme.dim}>
            <Spinner type="dots" /> loading profiles…
          </Text>
        ) : control.pending !== null ? (
          <Text color={theme.warn}>
            <Spinner type="dots" /> launching {control.pending}… (stopping old server, then loading)
          </Text>
        ) : items.length === 0 ? (
          <Box flexDirection="column">
            <Text color={theme.warn}>no model profiles configured.</Text>
            <Text color={theme.dim}>
              drop a JSON array of {"{ name, args, binary?, description? }"} at:
            </Text>
            <Text color={theme.primary}>
              {control.configPath ?? "~/.config/leancli/models.json"}
            </Text>
            <Text color={theme.dim}>then restart leancli-daemon. esc to go back.</Text>
          </Box>
        ) : (
          <Select
            items={items}
            isFocused={isActive}
            onSelect={(it) => void control.launch(it.value)}
          />
        )}
      </Box>
      {control.result && (
        <Box marginTop={1}>
          <Text
            color={control.result.includes("failed") ? theme.err : theme.ok}
          >
            {control.result}
          </Text>
        </Box>
      )}
      <Box marginTop={1}>
        <Text color={theme.dim}>
          {control.pending === null ? "enter launch · esc back" : "please wait…"}
        </Text>
      </Box>
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
        {sys.llamaCpuPct !== null && (
          <>
            {" · proc "}
            {/* >100% = more than one core busy → the model is on CPU. */}
            <Text color={sys.llamaCpuPct > 100 ? theme.warn : theme.primary}>
              {sys.llamaCpuPct}%
            </Text>
          </>
        )}
      </Line>
      <Line color={theme.dim}>
        cpu <Text color={theme.primary}>{sys.cpuPct === null ? "…" : `${sys.cpuPct}%`}</Text>
        {" · load "}
        {sys.load1 === null ? "n/a" : `${sys.load1.toFixed(2)}/${sys.cores}`}
        {" · mem "}
        <Text color={theme.primary}>{memLine}</Text>
      </Line>
      {gpu ? (
        <Line color={theme.dim}>
          {`gpu ${gpu.name}${gpu.utilPct !== undefined ? ` ${gpu.utilPct}%` : ""}${
            gpu.vramUsedMb !== undefined && gpu.vramTotalMb !== undefined
              ? ` · vram ${(gpu.vramUsedMb / 1024).toFixed(1)}/${(gpu.vramTotalMb / 1024).toFixed(0)}G`
              : ""
          }`}
        </Line>
      ) : sys.gpuError ? (
        <Line color={theme.err}>{`gpu ⚠ ${sys.gpuError}`}</Line>
      ) : (
        <Line color={theme.dim}>gpu: none detected</Line>
      )}
      {/* Actionable banner: llama answered but no GPU is in play, so it is
          running on CPU. Red when a driver error explains why (the user must
          fix the driver); amber for a genuinely CPU-only host. Ordered before
          the spawn-args hint so it wins if the pane clips. */}
      {llama.up === true && sys.gpus.length === 0 && (
        <Line color={sys.gpuError ? theme.err : theme.warn}>
          {sys.gpuError
            ? "↳ llama-server is on CPU — fix the GPU driver (error above)"
            : "↳ llama-server running on CPU (no GPU detected)"}
        </Line>
      )}
      {(llama.slotsAvailable === false || llama.metricsAvailable === false) && (
        <Line color={theme.dim}>hint: LLM_SPAWN_ARGS="--slots --metrics" enables slots+tok/s</Line>
      )}
    </Box>
  );
}

/* ---------- llama.cpp / model manager (expanded main view) ---------- */

/** Expanded LLM pane: live resource readout (LlmBox) plus the model
 *  launch picker (LlmLaunchPicker) inline. Esc (when not mid-launch)
 *  returns to chat-main. */
function LlmManager({
  isActive,
  control,
  llama,
  sys,
  chatPhase,
  outcome,
  onBack,
}: {
  isActive: boolean;
  control: ReturnType<typeof useLlmModels>;
  llama: ReturnType<typeof useLlamaStatus>;
  sys: ReturnType<typeof useSystemStats>;
  chatPhase: Phase;
  outcome?: string;
  onBack: () => void;
}) {
  return (
    <Box flexDirection="column">
      <LlmBox llama={llama} sys={sys} chatPhase={chatPhase} outcome={outcome} />
      <Box marginTop={1} flexDirection="column">
        <LlmLaunchPicker isActive={isActive} control={control} onClose={onBack} />
      </Box>
    </Box>
  );
}
