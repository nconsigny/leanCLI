import React, { useEffect, useState } from "react";
import { useApp } from "ink";
import { call } from "./daemon.js";
import MainMenu, { MainAction } from "./screens/MainMenu.js";
import WalletsHub, { WalletsAction } from "./screens/WalletsHub.js";
import ActionPicker, { Action as WalletAction } from "./screens/ActionPicker.js";
import PrivateActionsMenu from "./screens/PrivateActionsMenu.js";
import SendFlow from "./screens/SendFlow.js";
import SwapFlow from "./screens/SwapFlow.js";
import ShieldFlow from "./screens/ShieldFlow.js";
import CreateEoaFlow from "./screens/CreateEoaFlow.js";
import CreateR1Flow from "./screens/CreateR1Flow.js";
import ImportEoaFlow from "./screens/ImportEoaFlow.js";
import CreateWalletPicker, { CreateKind } from "./screens/CreateWalletPicker.js";
import DecodeIntentFlow from "./screens/DecodeIntentFlow.js";
import LlmChatFlow from "./screens/LlmChatFlow.js";
import MasterUnlockGate from "./screens/MasterUnlockGate.js";
import SendRawFlow from "./screens/SendRawFlow.js";
import DecodeTypedDataFlow from "./screens/DecodeTypedDataFlow.js";
import RevealMnemonicFlow from "./screens/RevealMnemonicFlow.js";
import AddAccountFlow from "./screens/AddAccountFlow.js";
import ArchivedAccountsScreen from "./screens/ArchivedAccountsScreen.js";
import { archiveKey, toggleArchive } from "./archiveStore.js";
import PrivacyMenu from "./screens/PrivacyMenu.js";
import NetworkScreen from "./screens/NetworkScreen.js";
import NetworkMonitor from "./screens/NetworkMonitor.js";
import {
  LockToggleFlow,
  ResolveFlow,
  DaemonScreen,
  DetailsScreen,
  HistoryScreen,
  BalanceRefreshScreen,
  MoreCommandsScreen,
} from "./screens/SimpleFlows.js";
import { Wallet } from "./types.js";

type Screen =
  // Startup probe — calls `wallet.master.status`. Resolves to either
  // `master-unlock` (when the wallet is initialized but not unlocked) or
  // `main`. Renders a tiny spinner while in flight; users entering during
  // a slow daemon start see "checking master…" instead of a flash of an
  // empty MainMenu.
  | { kind: "boot" }
  | { kind: "main" }
  | { kind: "wallets" }
  | { kind: "actions"; wallet: Wallet }
  | { kind: "send"; wallet: Wallet; chain?: string }
  | { kind: "swap"; wallet: Wallet }
  | { kind: "shield"; wallet: Wallet }
  | { kind: "lock-toggle"; wallet: Wallet }
  | { kind: "reveal-mnemonic"; wallet: Wallet }
  | { kind: "details"; wallet: Wallet }
  | { kind: "history"; wallet: Wallet }
  | { kind: "balance-refresh"; wallet: Wallet }
  | { kind: "create-wallet" }
  | { kind: "create-eoa" }
  | { kind: "create-r1" }
  | { kind: "add-account" }
  | { kind: "import-eoa" }
  | { kind: "private" }
  | { kind: "privacy" }
  | { kind: "network" }
  | { kind: "network-monitor" }
  | { kind: "resolve" }
  | { kind: "daemon" }
  | { kind: "more" }
  | { kind: "decode-intent" }
  | { kind: "llm-chat" }
  | { kind: "decode-typed-data" }
  | { kind: "archived-accounts" }
  | {
      kind: "send-raw";
      tx: { to: string; value: string; data: string; rationale?: string; canonical?: string };
      chainId: number;
      /** Pre-selected signing wallet. Currently set by LlmChatFlow when the
       *  user's prompt carried a `from <name>` hint that the regex
       *  resolved to one of their EOAs/TPMs — skips the picker. */
      wallet?: { kind: "eoa" | "tpm"; name: string; address: string };
    };

/** Stack-based screen navigator. Push on navigate, pop on Esc/back; the
 *  bottom of the stack is the main menu so Quit always exits the app. */
export default function App() {
  const { exit } = useApp();
  // Start at the boot probe rather than MainMenu — we render the master
  // unlock gate (if needed) before showing anything else. The gate's
  // `onDone` callback unrolls the stack onto MainMenu, so navigating Back
  // from MainMenu never lands the user on the gate again.
  const [stack, setStack] = useState<Screen[]>([{ kind: "boot" }]);
  const [walletsRefreshKey, setWalletsRefreshKey] = useState(0);
  // Colibri stateless simulation runs the EVM locally inside a WASM light
  // client with committee-verified state proofs. Toggling here sends
  // daemon.colibri.toggle so the persistent sidecar lifecycle is owned by
  // the daemon (one bootstrap, reused across calls). Initial state pulls
  // from daemon.colibri.status; the env var is a convenience auto-enable
  // for power users.
  const [colibriEnabled, setColibriEnabled] = useState(false);
  const [colibriPending, setColibriPending] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{ running?: boolean }>("daemon.colibri.status", {});
      if (cancelled) return;
      if (r.ok && r.result?.running) setColibriEnabled(true);
      else if (process.env.KOHAKU_COLIBRI === "1") {
        // Power-user auto-enable: ask the daemon to spawn one.
        await call("daemon.colibri.toggle", { enable: true });
        if (!cancelled) setColibriEnabled(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const toggleColibri = async () => {
    if (colibriPending) return;
    setColibriPending(true);
    const target = !colibriEnabled;
    const r = await call<{ running?: boolean }>("daemon.colibri.toggle", {
      enable: target,
    });
    if (r.ok) setColibriEnabled(r.result?.running === true);
    setColibriPending(false);
  };

  const top = stack[stack.length - 1]!;
  const push = (s: Screen) => setStack((prev) => [...prev, s]);
  const pop = () => {
    setStack((prev) => (prev.length > 1 ? prev.slice(0, -1) : prev));
  };

  const handleMain = (a: MainAction) => {
    switch (a) {
      case "wallets":         return push({ kind: "wallets" });
      case "le-chat":         return push({ kind: "llm-chat" });
      case "create-wallet":   return push({ kind: "create-wallet" });
      case "private":         return push({ kind: "private" });
      case "network":         return push({ kind: "network" });
      case "toggle-colibri":  return void toggleColibri();
      case "more":            return push({ kind: "more" });
      case "quit":            return exit();
    }
  };

  const handleCreatePick = (k: CreateKind) => {
    if (k === "back") return pop();
    // Replace the picker on the stack with the chosen flow so Esc from the
    // form returns to MainMenu rather than back to the picker. The
    // `add-account` branch reuses the same convention because it shares
    // the entry-point semantics of "create something" — landing back on
    // the picker after a successful derivation would be redundant. Same
    // applies to `import-bip39`, which used to be its own main-menu
    // entry but is now folded in here.
    const next: Screen =
      k === "eoa" ? { kind: "create-eoa" }
      : k === "r1" ? { kind: "create-r1" }
      : k === "import-bip39" ? { kind: "import-eoa" }
      : { kind: "add-account" };
    setStack((prev) => [...prev.slice(0, -1), next]);
  };

  const handleWalletAction = (w: Wallet, a: WalletAction) => {
    switch (a) {
      case "send":             return push({ kind: "send", wallet: w });
      case "swap":             return push({ kind: "swap", wallet: w });
      case "shield":           return push({ kind: "shield", wallet: w });
      case "lock-toggle":      return push({ kind: "lock-toggle", wallet: w });
      case "reveal-mnemonic":  return push({ kind: "reveal-mnemonic", wallet: w });
      case "details":          return push({ kind: "details", wallet: w });
      case "history":          return push({ kind: "history", wallet: w });
      case "balance-refresh":  return push({ kind: "balance-refresh", wallet: w });
      case "add-account":      return push({ kind: "add-account" });
      case "archive":
        toggleArchive(archiveKey(w.kind, w.name, w.accountIndex));
        return finishAction();
      case "back":             return pop();
    }
  };

  /** Hub picked an action+wallet+chain. SEND/SWAP/SHIELD jump straight into
   *  their flow; CUSTOM lands on the per-wallet ActionPicker so the user
   *  can drive any of the wallet-management ops. `chain` is the WalletsHub
   *  toggle (mainnet/sepolia for EOAs, "sepolia" for TPM). */
  const handleHubPick = (a: WalletsAction, w: Wallet, chain: string) => {
    switch (a) {
      case "send":   return push({ kind: "send", wallet: w, chain });
      case "swap":   return push({ kind: "swap", wallet: w });
      case "shield": return push({ kind: "shield", wallet: w });
      case "custom": return push({ kind: "actions", wallet: w });
    }
  };

  // After any inline action that may have changed balances/lock state,
  // bump the refreshKey so the wallet list re-fetches when we land on it.
  const finishAction = () => {
    setWalletsRefreshKey((k) => k + 1);
    pop();
  };

  switch (top.kind) {
    case "main":
      return (
        <MainMenu
          onPick={handleMain}
          colibriEnabled={colibriEnabled}
          colibriPending={colibriPending}
        />
      );
    case "wallets":
      return (
        <WalletsHub
          refreshKey={walletsRefreshKey}
          onPick={handleHubPick}
          onBack={pop}
        />
      );
    case "actions":
      return (
        <ActionPicker
          wallet={top.wallet}
          onPick={(a) => handleWalletAction(top.wallet, a)}
          onBack={pop}
        />
      );
    case "send":
      return (
        <SendFlow
          wallet={top.wallet}
          chain={top.chain}
          colibriEnabled={colibriEnabled}
          onDone={finishAction}
        />
      );
    case "swap":
      return <SwapFlow wallet={top.wallet} onDone={finishAction} />;
    case "shield":
      return <ShieldFlow wallet={top.wallet} onDone={finishAction} />;
    case "lock-toggle":
      return <LockToggleFlow wallet={top.wallet} onDone={finishAction} />;
    case "reveal-mnemonic":
      return <RevealMnemonicFlow wallet={top.wallet} onDone={pop} />;
    case "details":
      return <DetailsScreen wallet={top.wallet} onDone={pop} />;
    case "history":
      return <HistoryScreen wallet={top.wallet} onDone={pop} />;
    case "balance-refresh":
      return <BalanceRefreshScreen wallet={top.wallet} onDone={finishAction} />;
    case "create-wallet":
      return <CreateWalletPicker onPick={handleCreatePick} />;
    case "create-eoa":
      return <CreateEoaFlow onDone={finishAction} />;
    case "create-r1":
      return <CreateR1Flow onDone={finishAction} />;
    case "add-account":
      return <AddAccountFlow onDone={finishAction} />;
    case "import-eoa":
      return <ImportEoaFlow onDone={finishAction} />;
    case "private":
      return (
        <PrivateActionsMenu
          onPick={(a) => {
            if (a === "back") return pop();
            if (a === "privacy-pools") push({ kind: "privacy" });
          }}
        />
      );
    case "privacy":
      return <PrivacyMenu onDone={pop} />;
    case "network":
      return (
        <NetworkScreen
          onPick={(a) => {
            if (a === "monitor") push({ kind: "network-monitor" });
            else if (a === "back") pop();
          }}
          onBack={pop}
        />
      );
    case "network-monitor":
      return <NetworkMonitor onDone={pop} />;
    case "resolve":
      return <ResolveFlow onDone={pop} />;
    case "daemon":
      return <DaemonScreen onDone={pop} />;
    case "more":
      return (
        <MoreCommandsScreen
          onDone={pop}
          onPick={(a) => {
            if (a === "resolve") push({ kind: "resolve" });
            else if (a === "decode-intent") push({ kind: "decode-intent" });
            else if (a === "decode-typed-data") push({ kind: "decode-typed-data" });
            else if (a === "archived-accounts") push({ kind: "archived-accounts" });
            else if (a === "daemon") push({ kind: "daemon" });
          }}
        />
      );
    case "decode-intent":
      return <DecodeIntentFlow onDone={pop} />;
    case "llm-chat":
      return (
        <LlmChatFlow
          onDone={pop}
          onApprove={(tx, chainId, wallet) =>
            push({ kind: "send-raw", tx, chainId, wallet })
          }
          onCreateWallet={(kind, _label) => {
            // The existing creation flows ask the user to type the
            // label themselves (with validation + uniqueness checks),
            // so we don't pre-fill from the chat — the model's
            // suggestion is documented in the chat as
            // `createHandedOff` and the user re-types if they want
            // that exact name. This keeps the trusted creation path
            // owning the canonical label vocabulary.
            push({ kind: kind === "eoa" ? "create-eoa" : "create-r1" });
          }}
        />
      );
    case "send-raw":
      return (
        <SendRawFlow
          tx={top.tx}
          chainId={top.chainId}
          wallet={top.wallet}
          onDone={finishAction}
        />
      );
    case "decode-typed-data":
      return <DecodeTypedDataFlow onDone={pop} />;
    case "archived-accounts":
      return <ArchivedAccountsScreen onDone={finishAction} />;
    case "boot":
      // Master unlock gate or pass-through. `onDone` replaces the boot
      // screen with MainMenu (not push) so back-out from MainMenu cannot
      // return here.
      return (
        <BootGate
          onDone={() => setStack([{ kind: "main" }])}
        />
      );
  }
}

/** Startup probe → master-unlock-gate-or-pass-through.
 *
 *  Always prompts when a manifest exists (`initialized === true`), even
 *  if the daemon already holds a live KEK from a prior CLI session.
 *  Rationale: a TUI session is a long-running interactive surface, and
 *  users expect every session to begin with explicit auth — the daemon's
 *  in-memory unlock state is a CLI convenience, not a TUI bypass.
 *  Successful unlock just re-issues `wallet.unlock`, which the daemon
 *  treats idempotently (replaces the slot, restarts the TTL).
 *
 *  Skip only when there is no manifest (legacy install, never ran
 *  `wallet master init`) or when the status probe fails (daemon down,
 *  parser error — per-slot prompts still work as fallback). */
function BootGate({ onDone }: { onDone: () => void }) {
  const [status, setStatus] = React.useState<
    | { kind: "probing" }
    | { kind: "show-gate" }
    | { kind: "pass-through" }
  >({ kind: "probing" });

  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<{
        initialized: boolean;
        masterUnlocked: boolean;
      }>("wallet.master.status");
      if (cancelled) return;
      if (r.ok && r.result?.initialized) {
        setStatus({ kind: "show-gate" });
      } else {
        // No manifest, or status probe failed. Per-slot unlock remains
        // available for individual EOAs; skip the prompt.
        setStatus({ kind: "pass-through" });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  React.useEffect(() => {
    if (status.kind === "pass-through") onDone();
  }, [status.kind]);

  if (status.kind === "show-gate") {
    // Esc inside the gate falls through to MainMenu in locked mode; the
    // per-slot prompts are still available.
    return <MasterUnlockGate onDone={onDone} />;
  }
  // Probing / pass-through: don't paint MainMenu yet (its data fetches
  // would race with our probe). The pass-through case dispatches onDone
  // in the effect above; the next render is the parent MainMenu.
  return null;
}
