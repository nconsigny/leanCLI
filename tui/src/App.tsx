import React, { useEffect, useState } from "react";
import { useApp } from "ink";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { call } from "./daemon.js";

// BootGate's hasRpcConfigured() helper does a synchronous fs check on
// daemon.json before letting the gate fall through to MainMenu. Aliasing
// the node-stdlib functions keeps the helper readable down below where
// the gate lives.
const pathJoin = path.join;
const homeDir = os.homedir;
const fileExists = (p: string) => {
  try { return fs.existsSync(p); } catch { return false; }
};
const readFile = (p: string) => fs.readFileSync(p, "utf8");
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
import MasterInitGate from "./screens/MasterInitGate.js";
import RpcSetupGate from "./screens/RpcSetupGate.js";
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
  | { kind: "master-unlock" }
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
  // Bumped whenever the master-unlock gate closes so MainMenu re-queries
  // `wallet.master.status` and the locked-badge state stays consistent
  // with the daemon. The bump is unconditional (we don't know whether the
  // user actually unlocked or Esc'd out); a redundant refetch is cheap.
  const [masterStatusKey, setMasterStatusKey] = useState(0);

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
      case "unlock":          return push({ kind: "master-unlock" });
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
          masterStatusKey={masterStatusKey}
        />
      );
    case "master-unlock":
      return (
        <MasterUnlockGate
          onDone={() => {
            setMasterStatusKey((k) => k + 1);
            pop();
          }}
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

/** Startup gate. On a fresh install three things might be missing.
 *  Until commit 25edc78 the daemon refused to start without an RPC URL,
 *  which forced RPC-first ordering. Post commit 25edc78 the daemon
 *  starts without one (LeanKohaku/Daemon/Config.lean — empty URL
 *  sentinel) and refuses RPC-needing ops lazily, so we can now ask the
 *  user for their wallet master *before* the RPC URL — security setup
 *  before network setup, which is what a wallet UX should always do.
 *
 *  Order:
 *
 *   1. Wallet master KEK. `wallet.master.status` reports `initialized:
 *      false` on a fresh box → route to `MasterInitGate`. Master init
 *      is pure local crypto (PBKDF2 → KEK → optional TPM seal), it
 *      doesn't need network, so it really can run first.
 *
 *   2. RPC URL. We can't ask the daemon "do you have an RPC URL"
 *      directly (no such method, and adding one for one bit of state
 *      is overkill), so we fs-check `daemon.json` from Node — same
 *      file RpcSetupGate writes. If missing or no rpc_urls entry,
 *      route to `RpcSetupGate`.
 *
 *   3. Session unlock. Initialized + RPC set → `MasterUnlockGate`. We
 *      re-prompt every TUI launch on purpose (in-memory unlock is a
 *      CLI convenience, not a TUI bypass).
 *
 *  Esc at any step bails out to MainMenu unblocked; per-slot unlocks
 *  still work as the fallback. */
function BootGate({ onDone }: { onDone: () => void }) {
  type Status =
    | { kind: "probing" }
    | { kind: "needs-init" }
    | { kind: "needs-rpc" }
    | { kind: "needs-unlock" }
    | { kind: "pass-through" };

  const [status, setStatus] = React.useState<Status>({ kind: "probing" });

  React.useEffect(() => {
    if (status.kind !== "probing") return;
    let cancelled = false;
    (async () => {
      const r = await call<{
        initialized: boolean;
        masterUnlocked: boolean;
      }>("wallet.master.status");
      if (cancelled) return;
      if (!r.ok) {
        // Daemon unreachable even with auto-spawn in daemon.ts — surface
        // the failure rather than silently routing to RpcSetupGate, since
        // the daemon now starts without rpc_url and `!ok` means something
        // else is wrong (binary missing, permissions, etc).
        setStatus({ kind: "pass-through" });
        return;
      }
      if (!r.result!.initialized) {
        setStatus({ kind: "needs-init" });
        return;
      }
      if (!hasRpcConfigured()) {
        setStatus({ kind: "needs-rpc" });
        return;
      }
      setStatus({ kind: "needs-unlock" });
    })();
    return () => {
      cancelled = true;
    };
  }, [status.kind]);

  React.useEffect(() => {
    if (status.kind === "pass-through") onDone();
  }, [status.kind]);

  if (status.kind === "needs-init") {
    // After master init, re-probe instead of jumping straight to MainMenu —
    // a fresh install with no daemon.json should chain into RpcSetupGate
    // next, not strand the user without an RPC endpoint.
    return <MasterInitGate onDone={() => setStatus({ kind: "probing" })} />;
  }

  if (status.kind === "needs-rpc") {
    return <RpcSetupGate onDone={() => setStatus({ kind: "pass-through" })} />;
  }

  if (status.kind === "needs-unlock") {
    return <MasterUnlockGate onDone={onDone} />;
  }
  return null;
}

/** Mirror of `kohakuspawn`'s `has_rpc_configured` shell helper, scoped
 *  to the file format the TUI writes. Checks for a non-empty
 *  `rpc_urls.<chain>` entry or a non-empty top-level `rpc_url` in
 *  `$LEANKOHAKU_CONFIG` / `$XDG_CONFIG_HOME/leankohaku/daemon.json`. */
function hasRpcConfigured(): boolean {
  try {
    const cfg =
      process.env.LEANKOHAKU_CONFIG ||
      pathJoin(
        process.env.XDG_CONFIG_HOME || pathJoin(homeDir(), ".config"),
        "leankohaku",
        "daemon.json",
      );
    if (!fileExists(cfg)) return false;
    const json = JSON.parse(readFile(cfg));
    if (!json || typeof json !== "object") return false;
    if (typeof json.rpc_url === "string" && json.rpc_url.trim() !== "") {
      return true;
    }
    const map = json.rpc_urls;
    if (!map || typeof map !== "object") return false;
    for (const k of Object.keys(map)) {
      const v = map[k];
      if (typeof v === "string" && v.trim() !== "") return true;
      if (
        v && typeof v === "object" && typeof v.url === "string" &&
        v.url.trim() !== ""
      ) {
        return true;
      }
    }
    return false;
  } catch {
    return false;
  }
}
