import React, { useEffect, useState } from "react";
import { Box, Text, useApp } from "ink";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { call, isSystemdManaged, systemdMarkerPath } from "./daemon.js";

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
import CreateSphincsHybridFlow from "./screens/CreateSphincsHybridFlow.js";
import SphincsAccountsHub from "./screens/SphincsAccountsHub.js";
import ImportEoaFlow from "./screens/ImportEoaFlow.js";
import CreateWalletPicker, { CreateKind } from "./screens/CreateWalletPicker.js";
import DecodeIntentFlow from "./screens/DecodeIntentFlow.js";
import LlmChatFlow from "./screens/LlmChatFlow.js";
import MasterUnlockGate from "./screens/MasterUnlockGate.js";
import MasterInitGate from "./screens/MasterInitGate.js";
import RpcSetupGate from "./screens/RpcSetupGate.js";
import NetworkPolicyGate from "./screens/NetworkPolicyGate.js";
import SendRawFlow from "./screens/SendRawFlow.js";
import DecodeTypedDataFlow from "./screens/DecodeTypedDataFlow.js";
import RevealMnemonicFlow from "./screens/RevealMnemonicFlow.js";
import AddAccountFlow from "./screens/AddAccountFlow.js";
import ArchivedAccountsScreen from "./screens/ArchivedAccountsScreen.js";
import { archiveKey, toggleArchive } from "./archiveStore.js";
import PrivacyMenu from "./screens/PrivacyMenu.js";
import NetworkScreen from "./screens/NetworkScreen.js";
import NetworkMonitor from "./screens/NetworkMonitor.js";
import StatusFlow from "./screens/StatusFlow.js";
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
  | { kind: "create-sphincs-hybrid" }
  | { kind: "sphincs-accounts" }
  | { kind: "add-account" }
  | { kind: "import-eoa" }
  | { kind: "private" }
  | { kind: "privacy" }
  | { kind: "network" }
  | { kind: "network-monitor" }
  | { kind: "status" }
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

  // Defer the Colibri status probe until BootGate finishes. This used to
  // run unconditionally at mount, which triggered daemon auto-spawn
  // (daemon.ts#ensureDaemon on ENOENT) BEFORE BootGate's fs phase had
  // written daemon.json. The daemon would come up with empty rpc_urls,
  // auto-start Colibri against no upstream (Daemon/Server.lean#5104),
  // and then every chain read would EPIPE through colibri.uds because
  // the bridge couldn't reach any RPC. Waiting for the "main" screen
  // guarantees daemon.json is fully populated by the time we ask the
  // daemon anything.
  const bootDone = stack[stack.length - 1]?.kind !== "boot";
  useEffect(() => {
    if (!bootDone) return;
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
  }, [bootDone]);

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
      case "wallets":          return push({ kind: "wallets" });
      case "le-chat":          return push({ kind: "llm-chat" });
      case "create-wallet":    return push({ kind: "create-wallet" });
      case "sphincs-accounts": return push({ kind: "sphincs-accounts" });
      case "private":          return push({ kind: "private" });
      case "status":           return push({ kind: "status" });
      case "toggle-colibri":   return void toggleColibri();
      case "unlock":           return push({ kind: "master-unlock" });
      case "more":             return push({ kind: "more" });
      case "quit":             return exit();
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
      : k === "sphincs-hybrid" ? { kind: "create-sphincs-hybrid" }
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
    case "create-sphincs-hybrid":
      return <CreateSphincsHybridFlow onDone={finishAction} />;
    case "sphincs-accounts":
      return <SphincsAccountsHub onBack={pop} />;
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
    case "status":
      return (
        <StatusFlow
          onLiveMonitor={() => push({ kind: "network-monitor" })}
          onBack={pop}
        />
      );
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

/** Startup gate. Four things might be missing on a fresh install:
 *
 *   1. RPC URL (daemon.json#rpc_urls). fs-probe.
 *   2. network_policy (daemon.json#network_policy). fs-probe.
 *   3. wallet master KEK (master.json). daemon RPC `wallet.master.status`.
 *   4. session unlock (in-memory). daemon RPC `wallet.master.status`.
 *
 *  Two-phase machine. Phase 1 is fs-only — we deliberately do NOT call
 *  the daemon yet. That matters because daemon-side `cfg : Config` is a
 *  value, not a ref: whatever it reads at startup is what it uses for
 *  the lifetime of the process, with no hot reload. If we let the
 *  daemon auto-spawn before daemon.json is fully populated, its
 *  in-memory cfg would be stale (empty rpc, default-strict policy) and
 *  the user would see denials/empties for the rest of the session.
 *
 *  So phase 1 writes daemon.json fully via Node, THEN phase 2 talks to
 *  the daemon — at which point its first `wallet.master.status` call
 *  is also the first call that triggers `ensureDaemon` in daemon.ts,
 *  spawning a daemon that reads the completed config.
 *
 *  Order surfaced to the user:
 *      RPC → policy → master init → master unlock → main.
 *
 *  Master setup deliberately runs AFTER network config. That's the
 *  inverse of what intuition suggests ("security first"), but a daemon
 *  with wrong network config can't be fixed without restarting it and
 *  losing master state, so we want the config solid before binding
 *  identity. Esc at any gate bails to MainMenu unblocked; per-slot
 *  unlocks still work as the fallback. */
function BootGate({ onDone }: { onDone: () => void }) {
  type Status =
    | { kind: "fs-probe" }
    | { kind: "needs-rpc" }
    | { kind: "needs-policy" }
    | { kind: "daemon-probe" }
    | { kind: "needs-init" }
    | { kind: "needs-unlock" }
    // Marker file is present and the daemon is not reachable. We render
    // an actionable "start the systemd unit" notice instead of falling
    // through to MainMenu, where every screen would just show the
    // raw "daemon transport error" banner.
    | { kind: "systemd-not-running" }
    | { kind: "pass-through" };

  const [status, setStatus] = React.useState<Status>({ kind: "fs-probe" });
  // `wroteConfigThisSession` flips true whenever RpcSetupGate or
  // NetworkPolicyGate completes. When true, the transition from fs-probe
  // to daemon-probe sends `daemon.shutdown` first — that kills any stale
  // daemon that came up before daemon.json was complete (e.g. spawned by
  // a stray RPC call earlier in the React tree) so phase 2's autospawn
  // launches a fresh daemon reading the now-up-to-date config. Without
  // this, a daemon that started with empty rpc_urls would route every
  // chain read through its auto-started Colibri sidecar (Server.lean
  // #5104 default-on), Colibri couldn't reach any upstream, and the
  // user would see `colibri transport: write: Broken pipe` on every
  // balance fetch.
  const [wroteConfigThisSession, setWroteConfigThisSession] =
    React.useState(false);

  // Phase 1: synchronous fs checks on daemon.json. No daemon call.
  React.useEffect(() => {
    if (status.kind !== "fs-probe") return;
    if (!hasRpcConfigured()) {
      setStatus({ kind: "needs-rpc" });
      return;
    }
    if (!hasNetworkPolicy()) {
      setStatus({ kind: "needs-policy" });
      return;
    }
    // fs is complete. If we just wrote config in this session, force a
    // daemon restart so phase 2 talks to a fresh daemon reading the new
    // config. The shutdown is fire-and-forget — autospawn re-launches
    // automatically; the 300ms sleep covers Server.lean#exitSoon (50ms
    // grace + socket unlink) plus a small buffer for the OS to actually
    // release the path. If no daemon is running, the call errors and
    // we just proceed (the sleep is harmless on the no-daemon path).
    if (wroteConfigThisSession) {
      (async () => {
        try {
          await call("daemon.shutdown", []);
        } catch {
          // best-effort
        }
        await new Promise((r) => setTimeout(r, 300));
        setWroteConfigThisSession(false);
        setStatus({ kind: "daemon-probe" });
      })();
      return;
    }
    setStatus({ kind: "daemon-probe" });
  }, [status.kind, wroteConfigThisSession]);

  // Phase 2: daemon-side master status. Triggers auto-spawn — by now
  // daemon.json is complete, so the spawned daemon reads good config.
  React.useEffect(() => {
    if (status.kind !== "daemon-probe") return;
    let cancelled = false;
    (async () => {
      const r = await call<{
        initialized: boolean;
        masterUnlocked: boolean;
      }>("wallet.master.status");
      if (cancelled) return;
      if (!r.ok) {
        // Phase 1 finished, daemon still unreachable. If the systemd
        // marker is present, the daemon is intentionally not autospawned
        // — render the "start the unit" gate so the user sees the exact
        // command instead of a stream of per-screen transport errors.
        if (isSystemdManaged()) {
          setStatus({ kind: "systemd-not-running" });
          return;
        }
        // Otherwise something is actually broken (binary missing,
        // permissions). Surface to MainMenu where per-screen error
        // banners can render the underlying message.
        setStatus({ kind: "pass-through" });
        return;
      }
      if (!r.result!.initialized) {
        setStatus({ kind: "needs-init" });
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

  if (status.kind === "needs-rpc") {
    // After RPC save, re-enter fs-probe so the next missing piece
    // (likely policy) gets picked up without skipping past it. Set
    // wroteConfigThisSession so the fs→daemon transition restarts any
    // stale daemon that might already be running.
    return (
      <RpcSetupGate
        onDone={() => {
          setWroteConfigThisSession(true);
          setStatus({ kind: "fs-probe" });
        }}
      />
    );
  }

  if (status.kind === "needs-policy") {
    return (
      <NetworkPolicyGate
        onDone={() => {
          setWroteConfigThisSession(true);
          setStatus({ kind: "fs-probe" });
        }}
      />
    );
  }

  if (status.kind === "needs-init") {
    // After init, daemon already holds the KEK in memory, so jump
    // straight to MainMenu (skip the unlock prompt that would otherwise
    // ask for the passphrase the user literally just set).
    return <MasterInitGate onDone={() => setStatus({ kind: "pass-through" })} />;
  }

  if (status.kind === "needs-unlock") {
    return <MasterUnlockGate onDone={onDone} />;
  }

  if (status.kind === "systemd-not-running") {
    // Static notice — we deliberately don't auto-poll the socket from
    // here. The user starts the unit in another terminal, then
    // re-launches `kohaku tui`. Auto-polling would risk autospawn races
    // if they removed the marker concurrently, and would also chew CPU
    // for the typical "user wandered off to coffee" gap.
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text bold color="yellow">
          kohaku-daemon is not running.
        </Text>
        <Text>
          This machine is configured to manage the daemon via systemd
          (marker present at <Text dimColor>{systemdMarkerPath()}</Text>).
        </Text>
        <Text> </Text>
        <Text>Start the daemon in another terminal:</Text>
        <Text color="cyan">  systemctl --user start kohaku-daemon</Text>
        <Text>Tail its logs:</Text>
        <Text color="cyan">  journalctl --user -u kohaku-daemon -f</Text>
        <Text> </Text>
        <Text dimColor>
          Then re-run `kohaku tui`. To restore autospawn instead, delete
          the marker file above.
        </Text>
      </Box>
    );
  }

  return null;
}

/** True iff daemon.json contains a `network_policy` string. We don't
 *  validate the value here — `parsePolicy` on the daemon side does that
 *  and falls back to `mainnetSafeDaemonPolicy` for unknown strings. */
function hasNetworkPolicy(): boolean {
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
    const v = json.network_policy ?? json.networkPolicy;
    return typeof v === "string" && v.length > 0;
  } catch {
    return false;
  }
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
