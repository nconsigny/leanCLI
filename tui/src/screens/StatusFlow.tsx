import React, { useEffect, useState, useRef } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { Layout, Banner } from "../widgets/Layout.js";
import Select from "../widgets/Select.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

/** One sidecar row in the snapshot. Mirrors `Daemon/Status.lean`'s
 *  `sidecarJson` output. */
type Sidecar = {
  name: string;
  envVar: string;
  envOverride: boolean;
  resolverPath: string;
  depsInstalled: boolean;
  pingOk: boolean;
  pingMs: number;
  pingError: string;
};

type Snapshot = {
  daemon: { pid: number; uptimeMs: number; version: string };
  /** Active read provider + per-light-client run state (from the persistent
   *  clients, mirrors `Daemon/Status.lean`'s `providerJson`). Single-select:
   *  exactly one of helios/colibri should be running, matching `provider`.
   *  `oram` is the SafeNode TDX proxy layer over the active provider. */
  provider?: {
    provider: string;
    helios: { running: boolean };
    colibri: { running: boolean };
    oram: { running: boolean };
  };
  sidecars: Sidecar[];
  sandbox: {
    mode: string;
    unshareUsable: boolean;
    unsharePath: string;
    hint: string;
  };
  versions: {
    checkoutRoot: string | null;
    daemonBinMtimeMs: number | null;
    tuiBundleMtimeMs: number | null;
    gitHead: string;
  };
  wallet: {
    masterUnlocked: boolean;
    unlockedSlotCount: number;
    unlockedSlots: string[];
  };
  network: {
    chainId: number;
    policy: string;
    socketPath: string;
    rpc: EndpointInfo;
    ens: EndpointInfo | null;
    chains: ChainEndpoint[];
  };
};

type EndpointInfo = {
  url: string;
  transport: string;
  backend: string;
  host: string;
  ip: string;
  egressSrc: string;
  egressDev: string;
  egressError: string;
  chainId: number | null;
};

type ChainEndpoint = {
  name: string;
  chainId: number | null;
  url: string;
  transport: string;
  backend: string;
  host: string;
  ip: string;
  egressSrc: string;
  egressDev: string;
  egressError: string;
  isCurrent: boolean;
};

type Props = {
  onLiveMonitor: () => void;
  onTrustedRegistry: () => void;
  onBack: () => void;
  /** When false, the page-level shortcuts (r/m/t/esc/q) go quiet — set by
   *  the dashboard when Status is embedded as a pane but not focused.
   *  Defaults to true so the standalone full-screen mount is unaffected. */
  isActive?: boolean;
};

/** Status page — cypherpunk-styled debugging surface. Single
 *  `status.snapshot` RPC fans out sidecar pings + sandbox probe
 *  daemon-side; the TUI just renders. R refreshes, M opens the live
 *  network monitor (preserves the existing trace tool), ESC/q backs out. */
export default function StatusFlow({
  onLiveMonitor,
  onTrustedRegistry,
  onBack,
  isActive = true,
}: Props) {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  // While an action is mid-confirm or mid-run, the ActionsPanel owns
  // useInput — page-level shortcuts (r/m/q) would steal keys otherwise.
  // Boolean is fine because we don't need to know which phase, only
  // "is something else listening?".
  const [actionBusy, setActionBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setRefreshing(true);
    setError(null);
    (async () => {
      const r = await call<Snapshot>("status.snapshot", {});
      if (cancelled) return;
      setRefreshing(false);
      if (!r.ok) {
        setError(`${r.error.code}: ${r.error.message}`);
        return;
      }
      setSnap(r.result);
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshKey]);

  useInput(
    (input, key) => {
      if (actionBusy) return;
      if (key.escape || key.leftArrow || input === "q") {
        onBack();
        return;
      }
      if (input === "r" || input === "R") setRefreshKey((k) => k + 1);
      if (input === "m" || input === "M") onLiveMonitor();
      if (input === "t" || input === "T") onTrustedRegistry();
    },
    { isActive },
  );

  return (
    <Layout
      title="◉ Status — daemon · sidecars · sandbox · network"
      subtitle={
        snap
          ? `daemon pid ${snap.daemon.pid} · uptime ${fmtUptime(snap.daemon.uptimeMs)} · v${snap.daemon.version}`
          : "querying daemon…"
      }
      hint="r refresh · m live monitor · t trusted registry · ← / esc back · q quit"
    >
      {error && <Banner kind="err" text={error} />}
      {!snap && !error && (
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>asking daemon for snapshot…</Text>
        </Text>
      )}
      {snap && (
        <Box flexDirection="column">
          {refreshing && (
            <Box marginBottom={1}>
              <Text color={theme.dim}>
                <Spinner type="dots" /> re-probing…
              </Text>
            </Box>
          )}
          <HealthBar snap={snap} />
          <ProviderPanel provider={snap.provider} />
          <SidecarsPanel sidecars={snap.sidecars} />
          <SandboxPanel sandbox={snap.sandbox} />
          <NetworkPanel network={snap.network} />
          <VersionsPanel versions={snap.versions} />
          <WalletPanel wallet={snap.wallet} />
          <ActionsHost
            snap={snap}
            onActionDone={() => setRefreshKey((k) => k + 1)}
            setActionBusy={setActionBusy}
          />
        </Box>
      )}
    </Layout>
  );
}

/** Thin wrapper that signals to the parent whenever ActionsPanel
 *  transitions between idle and non-idle, so the parent can suspend
 *  its own useInput handlers. The signal is keyed off a render-side
 *  prop (`actionBusy` boolean held by parent), which is enough because
 *  ActionsPanel mounts only when the snapshot is loaded. */
function ActionsHost({
  snap,
  onActionDone,
  setActionBusy,
}: {
  snap: Snapshot;
  onActionDone: () => void;
  setActionBusy: (busy: boolean) => void;
}) {
  // ActionsPanel's `phase` lives inside its own state; we observe it
  // through a ref by re-rendering. Simpler approach: lift the busy
  // signal into a callback prop ActionsPanel can call when phase
  // transitions. Doing that without a major refactor: pass a setter
  // that ActionsPanel invokes at the start of confirm/run/done.
  return (
    <ActionsPanel
      snap={snap}
      onActionDone={onActionDone}
      onPhaseChange={(busy) => setActionBusy(busy)}
    />
  );
}

/** Top-of-page summary strip — one glance tells you "all green" or
 *  "fix this first". Modelled after NetworkMonitor's StatsBar so the two
 *  feel like cousins. */
function HealthBar({ snap }: { snap: Snapshot }) {
  const okSidecars = snap.sidecars.filter((s) => s.pingOk).length;
  const total = snap.sidecars.length;
  const sidecarColor =
    okSidecars === total ? theme.ok : okSidecars > 0 ? theme.warn : theme.err;
  const sandboxColor = snap.sandbox.unshareUsable ? theme.ok : theme.warn;
  const masterColor = snap.wallet.masterUnlocked ? theme.ok : theme.dim;
  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={theme.koiRed}
      paddingX={1}
      marginBottom={1}
      alignSelf="flex-start"
    >
      <Text wrap="truncate-end">
        <Text color={theme.koiCream} bold>{"▶ READY    "}</Text>
        <Text color={theme.dim}>sidecars </Text>
        <Text color={sidecarColor} bold>
          {okSidecars}/{total}
        </Text>
        <Text color={theme.dim}>   sandbox </Text>
        <Text color={sandboxColor}>
          {snap.sandbox.unshareUsable ? "ON" : "off"}
        </Text>
        <Text color={theme.dim}>   master </Text>
        <Text color={masterColor}>
          {snap.wallet.masterUnlocked ? "unlocked" : "locked"}
        </Text>
        <Text color={theme.dim}>   slots </Text>
        <Text color={theme.highlight}>{snap.wallet.unlockedSlotCount}</Text>
        <Text color={theme.dim}>   chain </Text>
        <Text color={theme.accent}>{chainLabel(snap.network.chainId)}</Text>
        <Text color={theme.dim}>   policy </Text>
        <Text color={theme.accent}>{snap.network.policy}</Text>
      </Text>
    </Box>
  );
}

function SidecarsPanel({ sidecars }: { sidecars: Sidecar[] }) {
  return (
    <Section title="Sidecars / bridges">
      <HeaderRow />
      {sidecars.map((s) => (
        <SidecarRow key={s.name} s={s} />
      ))}
    </Section>
  );
}

function HeaderRow() {
  const cell = (s: string, n: number) =>
    s.length >= n ? s.slice(0, n) : s + " ".repeat(n - s.length);
  return (
    <Text color={theme.dim} bold wrap="truncate-end">
      {"  "}
      {cell("name", 11)} {cell("status", 7)} {cell("ms", 5)}{" "}
      {cell("deps", 5)} {cell("via", 10)} {cell("resolver path", 60)}
    </Text>
  );
}

function SidecarRow({ s }: { s: Sidecar }) {
  const cell = (str: string, n: number) =>
    str.length >= n
      ? str.slice(0, Math.max(0, n - 1)) + "…"
      : str + " ".repeat(n - str.length);
  const glyph = s.pingOk ? "✓" : "✗";
  const glyphColor = s.pingOk ? theme.ok : theme.err;
  const status = s.pingOk ? "OK" : "DOWN";
  const statusColor = s.pingOk ? theme.ok : theme.err;
  const ms = s.pingOk ? String(s.pingMs).padStart(4) : "  —";
  const depsGlyph = s.depsInstalled ? "✓" : "✗";
  const depsColor = s.depsInstalled ? theme.ok : theme.err;
  const via = s.envOverride ? "env" : "checkout";
  const viaColor = s.envOverride ? theme.accent : theme.primary;
  const truncatedPath = truncateLeft(s.resolverPath, 60);
  return (
    <Box flexDirection="column">
      <Text wrap="truncate-end">
        <Text color={glyphColor}>{glyph} </Text>
        <Text color={theme.primary}>{cell(s.name, 11)} </Text>
        <Text color={statusColor}>{cell(status, 7)} </Text>
        <Text color={theme.dim}>{ms}  </Text>
        <Text color={depsColor}>{depsGlyph}    </Text>
        <Text color={viaColor}>{cell(via, 10)} </Text>
        <Text color={theme.dim}>{cell(truncatedPath, 60)}</Text>
      </Text>
      {!s.pingOk && s.pingError && (
        <Text color={theme.err} wrap="truncate-end">
          {"    └─ "}
          {s.pingError.length > 100 ? s.pingError.slice(0, 100) + "…" : s.pingError}
        </Text>
      )}
    </Box>
  );
}

function SandboxPanel({ sandbox }: { sandbox: Snapshot["sandbox"] }) {
  const modeColor =
    sandbox.mode === "off"
      ? theme.warn
      : sandbox.mode === "require"
        ? theme.err
        : theme.primary;
  const usableGlyph = sandbox.unshareUsable ? "✓" : "✗";
  const usableColor = sandbox.unshareUsable ? theme.ok : theme.warn;
  return (
    <Section title="Sandbox (sidecar isolation via unshare(1))">
      <KV k="mode" v={sandbox.mode} color={modeColor} />
      <Box>
        <Text color={theme.dim}>{"unshare    "}</Text>
        <Text color={usableColor}>
          {usableGlyph} {sandbox.unshareUsable ? "usable" : "blocked"}
        </Text>
        {sandbox.unsharePath && (
          <Text color={theme.dim}> · {sandbox.unsharePath}</Text>
        )}
      </Box>
      {sandbox.hint && (
        <Box marginTop={0}>
          <Text color={theme.warn}>{"⚠ "}</Text>
          <Text color={theme.dim}>{sandbox.hint}</Text>
        </Box>
      )}
      {sandbox.unshareUsable && (
        <Text color={theme.ok}>
          OK · sidecars run in PID/UTS/IPC/net namespaces
        </Text>
      )}
    </Section>
  );
}

function NetworkPanel({ network }: { network: Snapshot["network"] }) {
  return (
    <Section title="Network">
      <KV k="chainId" v={`${network.chainId} (${chainLabel(network.chainId)})`} />
      <KV k="policy" v={network.policy} color={theme.ok} />
      <KV k="socket" v={network.socketPath} mono />
      <Box marginTop={1} flexDirection="column">
        <Text color={theme.primary} bold>active RPC</Text>
        <Box marginLeft={2} flexDirection="column">
          <EndpointLines ep={network.rpc} />
        </Box>
      </Box>
      {network.ens && (
        <Box marginTop={1} flexDirection="column">
          <Text color={theme.primary} bold>ENS RPC</Text>
          <Box marginLeft={2} flexDirection="column">
            <EndpointLines ep={network.ens} />
          </Box>
        </Box>
      )}
      {network.chains.length > 0 && (
        <Box marginTop={1} flexDirection="column">
          <Text color={theme.primary} bold>configured chains ({network.chains.length})</Text>
          <Box marginLeft={2} flexDirection="column">
            <ChainsTable chains={network.chains} />
          </Box>
        </Box>
      )}
      <Box marginTop={1}>
        <Text color={theme.accent}>{"→ "}</Text>
        <Text color={theme.dim}>press </Text>
        <Text color={theme.highlight} bold>m</Text>
        <Text color={theme.dim}> for live monitor</Text>
      </Box>
    </Section>
  );
}

function EndpointLines({ ep }: { ep: EndpointInfo }) {
  return (
    <Box flexDirection="column">
      <Box>
        <Text color={theme.dim}>{"url       "}</Text>
        <Text wrap="truncate-end">{ep.url || "<unset>"}</Text>
      </Box>
      <Box>
        <Text color={theme.dim}>{"host / ip "}</Text>
        <Text color={theme.accent}>{ep.host || "<unknown>"}</Text>
        {ep.ip && ep.ip !== ep.host && (
          <>
            <Text color={theme.dim}>{" → "}</Text>
            <Text color={theme.highlight}>{ep.ip}</Text>
          </>
        )}
        {!ep.ip && (
          <Text color={theme.dim}>{"  (DNS not resolved)"}</Text>
        )}
      </Box>
      <Box>
        <Text color={theme.dim}>{"transport "}</Text>
        <Text color={theme.accent}>{ep.transport}</Text>
        <Text color={theme.dim}>{"   backend "}</Text>
        <Text color={theme.accent}>{ep.backend}</Text>
        {ep.chainId !== null && (
          <>
            <Text color={theme.dim}>{"   chainId "}</Text>
            <Text color={theme.accent}>{ep.chainId}</Text>
          </>
        )}
      </Box>
      <Box>
        <Text color={theme.dim}>{"egress    "}</Text>
        {ep.egressSrc ? (
          <>
            <Text color={theme.highlight}>{ep.egressSrc}</Text>
            {ep.egressDev && (
              <>
                <Text color={theme.dim}>{" on "}</Text>
                <Text color={theme.accent}>{ep.egressDev}</Text>
              </>
            )}
            <Text color={theme.dim}>{"  (local src · ip route get)"}</Text>
          </>
        ) : (
          <Text color={theme.warn} wrap="truncate-end">
            {ep.egressError || "<no route>"}
          </Text>
        )}
      </Box>
    </Box>
  );
}

function ChainsTable({ chains }: { chains: ChainEndpoint[] }) {
  const cell = (s: string, n: number) =>
    s.length >= n
      ? s.slice(0, Math.max(0, n - 1)) + "…"
      : s + " ".repeat(n - s.length);
  return (
    <Box flexDirection="column">
      <Text color={theme.dim} bold wrap="truncate-end">
        {"  "}
        {cell("name", 10)} {cell("chainId", 9)} {cell("transport", 10)}{" "}
        {cell("ip", 16)} {cell("url", 60)}
      </Text>
      {chains.map((c) => {
        const marker = c.isCurrent ? "▶" : " ";
        const markerColor = c.isCurrent ? theme.ok : theme.dim;
        const nameColor = c.isCurrent ? theme.highlight : theme.primary;
        const chainIdStr = c.chainId === null ? "?" : String(c.chainId);
        const ipStr = c.ip || "—";
        return (
          <Text key={c.name} wrap="truncate-end">
            <Text color={markerColor}>{marker} </Text>
            <Text color={nameColor}>{cell(c.name, 10)} </Text>
            <Text color={theme.dim}>{cell(chainIdStr, 9)} </Text>
            <Text color={theme.accent}>{cell(c.transport, 10)} </Text>
            <Text color={theme.dim}>{cell(ipStr, 16)} </Text>
            <Text>{cell(c.url, 60)}</Text>
          </Text>
        );
      })}
    </Box>
  );
}

function VersionsPanel({ versions }: { versions: Snapshot["versions"] }) {
  return (
    <Section title="Versions / build">
      <KV
        k="checkout"
        v={versions.checkoutRoot ?? "<unknown — no $LEANCLI_HOME/checkout marker>"}
        mono={!!versions.checkoutRoot}
        color={versions.checkoutRoot ? undefined : theme.warn}
      />
      <KV k="git HEAD" v={versions.gitHead ? versions.gitHead.slice(0, 12) : "<unknown>"} />
      <KV k="daemon bin" v={fmtMtime(versions.daemonBinMtimeMs)} />
      <KV k="tui bundle" v={fmtMtime(versions.tuiBundleMtimeMs)} />
    </Section>
  );
}

function WalletPanel({ wallet }: { wallet: Snapshot["wallet"] }) {
  const lockColor = wallet.masterUnlocked ? theme.ok : theme.warn;
  return (
    <Section title="Wallet">
      <Box>
        <Text color={theme.dim}>{"master     "}</Text>
        <Text color={lockColor}>
          {wallet.masterUnlocked ? "✓ unlocked" : "⊘ locked"}
        </Text>
      </Box>
      <KV k="slots" v={String(wallet.unlockedSlotCount) + " currently unlocked"} />
      {wallet.unlockedSlots.length > 0 && (
        <Box marginLeft={11}>
          <Text color={theme.dim}>{wallet.unlockedSlots.join(", ")}</Text>
        </Box>
      )}
    </Section>
  );
}

/* ------------------------------------------------------------------ *
 * Layout primitives mirrored from NetworkScreen so the two pages share
 * the same visual rhythm without coupling the components.
 * ------------------------------------------------------------------ */

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text color={theme.primary} bold>
        {title}
      </Text>
      <Box flexDirection="column" marginLeft={2}>
        {children}
      </Box>
    </Box>
  );
}

/** Active read provider + light-client / ORAM state. Sourced from the
 *  snapshot's persistent-client view (`Daemon/Status.lean#providerJson`),
 *  NOT the `--rpc ping` sidecar loop — so helios appears here even though a
 *  one-shot helios spawn is too heavy to ping. Single-select: exactly one
 *  light client should be on, matching `provider`. The verified line is the
 *  same trust statement the dashboard shows: simulate is consensus-verified
 *  only when the matching light client is actually running. */
function ProviderPanel({ provider }: { provider: Snapshot["provider"] }) {
  if (!provider) return null;
  const dot = (on: boolean) =>
    on ? <Text color={theme.ok}>● on</Text> : <Text color={theme.dim}>○ off</Text>;
  const p = provider.provider;
  const lcRunning =
    p === "helios" ? provider.helios.running
      : p === "colibri" ? provider.colibri.running
        : null;
  const verified =
    lcRunning === true ? (
      <Text color={theme.ok}>✓ verified: tx simulate via {p} · balances direct</Text>
    ) : lcRunning === false ? (
      <Text color={theme.warn}>⚠ provider {p} but light client OFF — simulate NOT verified</Text>
    ) : (
      <Text color={theme.dim}>simulate uses raw RPC — not consensus-verified</Text>
    );
  return (
    <Section title="Provider / light clients">
      <Text>
        <Text color={theme.dim}>provider </Text>
        <Text color={theme.highlight} bold>
          {p}
        </Text>
        <Text color={theme.dim}>{"  ·  light-client "}</Text>
        {p === "helios" ? (
          dot(provider.helios.running)
        ) : p === "colibri" ? (
          dot(provider.colibri.running)
        ) : (
          <Text color={theme.dim}>○ none (rpc)</Text>
        )}
        <Text color={theme.dim}>{"  ·  oram-tee "}</Text>
        {dot(provider.oram.running)}
      </Text>
      <Text>{verified}</Text>
    </Section>
  );
}

function KV({
  k,
  v,
  mono = false,
  color,
}: {
  k: string;
  v: string;
  mono?: boolean;
  color?: string;
}) {
  return (
    <Box>
      <Text color={theme.dim}>{k.padEnd(11)}</Text>
      <Text color={color}>{mono ? v : v}</Text>
    </Box>
  );
}

/* ------------------------------------------------------------------ *
 * Pure formatters
 * ------------------------------------------------------------------ */

function fmtUptime(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m${s % 60}s`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h${m % 60}m`;
  const d = Math.floor(h / 24);
  return `${d}d${h % 24}h`;
}

function fmtMtime(ms: number | null): string {
  if (ms === null || ms === undefined) return "<missing>";
  const ageMs = Date.now() - ms;
  const ageStr = ageMs >= 0 ? fmtUptime(ageMs) + " ago" : "in the future?";
  const iso = new Date(ms).toISOString().replace("T", " ").slice(0, 19);
  return `${iso} (${ageStr})`;
}

function chainLabel(chainId: number): string {
  switch (chainId) {
    case 1: return "mainnet";
    case 11155111: return "sepolia";
    case 17000: return "holesky";
    default: return "chain-" + chainId;
  }
}

/** Truncate from the LEFT so the tail (filename) stays visible — useful
 *  for the resolver path column where the interesting bit is the
 *  bridge.mjs at the end, not the home dir at the start. */
function truncateLeft(s: string, n: number): string {
  if (s.length <= n) return s;
  return "…" + s.slice(s.length - n + 1);
}

/* ================================================================== *
 * Actions
 *
 * Write-side surface for the Status page. Each action ships a confirm
 * prompt with the exact shell command we'll run, then streams stdout +
 * stderr live as the runner executes. No daemon-side RPC for these —
 * shelling out from the TUI keeps the action observable (you can see
 * the literal command) and works even when the daemon is in a degraded
 * state (e.g. the entire point of "restart daemon" is that the daemon
 * itself is broken). The trade-off is the TUI process needs file +
 * process permissions; in practice we're already the same UID as the
 * daemon, so this doesn't widen the trust surface.
 * ================================================================== */

type ActionId = "restart-daemon" | "toggle-sandbox" | "pull-updates";

type SandboxMode = "auto" | "off" | "require";

/** Cycle order is intentional: from a healthy host you go OFF only
 *  to confirm a degradation; from a degraded host (auto+probe failed)
 *  toggling to OFF silences the warning while accepting the risk;
 *  REQUIRE is the strict-prod stance. */
const SANDBOX_CYCLE: Record<SandboxMode, SandboxMode> = {
  auto: "off",
  off: "require",
  require: "auto",
};

type ActionPhase =
  | { kind: "idle" }
  | { kind: "confirm"; id: ActionId; preview: string }
  | { kind: "running"; id: ActionId; lines: string[]; exitCode: number | null }
  | { kind: "done"; id: ActionId; ok: boolean; lines: string[] };

/** Where the daemon reads its environment file from. Mirrors the
 *  resolution in `script/leanclispawn` so the TUI writes to the same
 *  path the systemd unit's `EnvironmentFile=` line reads. */
function daemonEnvPath(): string {
  const cfg =
    process.env.XDG_CONFIG_HOME ??
    join(homedir(), ".config");
  return join(cfg, "leancli", "daemon.env");
}

/** Read the current `LEANCLI_SANDBOX=` value, defaulting to "auto"
 *  when unset (matches `LeanCli.Util.Sandbox.parseMode`). */
function readSandboxMode(): SandboxMode {
  const path = daemonEnvPath();
  if (!existsSync(path)) return "auto";
  const raw = readFileSync(path, "utf8");
  for (const line of raw.split("\n")) {
    const m = line.match(/^LEANCLI_SANDBOX\s*=\s*(\S+)/);
    if (m && m[1]) {
      const v = m[1].toLowerCase();
      if (v === "off" || v === "require" || v === "auto") return v;
    }
  }
  return "auto";
}

/** Idempotent in-place write of `LEANCLI_SANDBOX=<mode>`. Preserves
 *  every other line; replaces the sandbox line if present, appends if
 *  not. Creates the parent dir + file with 0600 perms when missing. */
function writeSandboxMode(mode: SandboxMode): void {
  const path = daemonEnvPath();
  const parent = path.replace(/\/[^/]+$/, "");
  if (!existsSync(parent)) {
    mkdirSync(parent, { recursive: true, mode: 0o700 });
  }
  const existing = existsSync(path) ? readFileSync(path, "utf8") : "";
  const lines = existing ? existing.split("\n") : [];
  let replaced = false;
  const out = lines.map((line) => {
    if (/^LEANCLI_SANDBOX\s*=/.test(line)) {
      replaced = true;
      return `LEANCLI_SANDBOX=${mode}`;
    }
    return line;
  });
  if (!replaced) {
    // Trim trailing empty line before appending so we don't grow blank
    // lines on every write.
    while (out.length > 0 && out[out.length - 1] === "") out.pop();
    out.push(`LEANCLI_SANDBOX=${mode}`);
    out.push("");
  }
  writeFileSync(path, out.join("\n"), { mode: 0o600 });
}

/** Build the confirm-prompt preview text shown before the user commits
 *  to running an action. Includes the literal shell command so the user
 *  knows exactly what we'll execute. */
function previewFor(id: ActionId, snap: Snapshot): string {
  switch (id) {
    case "restart-daemon":
      return "systemctl --user restart leancli-daemon\n\nStops the running daemon (pid " +
        snap.daemon.pid +
        ") and re-spawns it via the systemd user unit. Any in-flight RPCs from other clients drop with a transport error. Takes 1–2 seconds.";
    case "toggle-sandbox": {
      const current = readSandboxMode();
      const next = SANDBOX_CYCLE[current];
      return (
        `Write LEANCLI_SANDBOX=${next} to ${daemonEnvPath()}\n` +
        `then: systemctl --user restart leancli-daemon\n\n` +
        `Current mode: ${current}  →  Next mode: ${next}\n\n` +
        `auto: wrap sidecars with unshare(1) when usable, degrade gracefully if not.\n` +
        `off:  no wrapping. Use only when AppArmor blocks userns and you've accepted the trade-off.\n` +
        `require: refuse to spawn sidecars if unshare is not usable. Strict-prod stance.`
      );
    }
    case "pull-updates":
      return (
        `cd ${snap.versions.checkoutRoot ?? "<unknown>"} && git pull --ff-only origin master\n` +
        `then: ./script/leanclispawn --pull --no-init  (rebuild lake + TUI)\n` +
        `then: systemctl --user restart leancli-daemon\n\n` +
        `Skips first-run wizard. Fails fast (non-ff) instead of merging — your local commits would block the pull and you'd want to handle them manually.`
      );
  }
}

/** Run a child process, stream stdout+stderr line by line into
 *  `onLine`. Resolves with the exit code (or -1 on spawn failure). */
function streamSpawn(
  cmd: string,
  args: string[],
  cwd: string | undefined,
  onLine: (line: string) => void,
): Promise<number> {
  return new Promise((resolve) => {
    let child: ChildProcessByStdio<null, Readable, Readable>;
    try {
      child = spawn(cmd, args, {
        stdio: ["ignore", "pipe", "pipe"],
        cwd,
      });
    } catch (e) {
      onLine(`spawn failed: ${(e as Error).message}`);
      resolve(-1);
      return;
    }
    let outBuf = "";
    let errBuf = "";
    const drain = (buf: string, prefix: string): string => {
      let nl;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.length > 0) onLine(prefix + line);
      }
      return buf;
    };
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (c: string) => {
      outBuf += c;
      outBuf = drain(outBuf, "");
    });
    child.stderr.on("data", (c: string) => {
      errBuf += c;
      // err prefix lets the user distinguish stderr without colour — most
      // shells flush stderr through this path for warnings (git, lake
      // build all chatter on stderr by convention).
      errBuf = drain(errBuf, "");
    });
    child.on("error", (e) => {
      onLine(`process error: ${e.message}`);
      resolve(-1);
    });
    child.on("exit", (code) => {
      // Flush any residual partial line.
      if (outBuf.length > 0) onLine(outBuf);
      if (errBuf.length > 0) onLine(errBuf);
      resolve(code ?? -1);
    });
  });
}

/** Execute an action and stream its output into `onLine`. Returns the
 *  final exit code (-1 if any setup step threw). Multi-step actions
 *  short-circuit on the first non-zero exit. */
async function runAction(
  id: ActionId,
  snap: Snapshot,
  onLine: (line: string) => void,
): Promise<number> {
  switch (id) {
    case "restart-daemon": {
      onLine("$ systemctl --user restart leancli-daemon");
      return await streamSpawn(
        "systemctl",
        ["--user", "restart", "leancli-daemon"],
        undefined,
        onLine,
      );
    }
    case "toggle-sandbox": {
      const current = readSandboxMode();
      const next = SANDBOX_CYCLE[current];
      onLine(`# writing LEANCLI_SANDBOX=${next} to ${daemonEnvPath()}`);
      try {
        writeSandboxMode(next);
        onLine(`# daemon.env updated (${current} → ${next})`);
      } catch (e) {
        onLine(`write failed: ${(e as Error).message}`);
        return -1;
      }
      onLine("$ systemctl --user restart leancli-daemon");
      return await streamSpawn(
        "systemctl",
        ["--user", "restart", "leancli-daemon"],
        undefined,
        onLine,
      );
    }
    case "pull-updates": {
      const root = snap.versions.checkoutRoot;
      if (!root) {
        onLine("checkoutRoot is unknown — cannot pull updates from here.");
        onLine("Run leanclispawn from inside your local clone manually.");
        return -1;
      }
      onLine(`$ git -C ${root} pull --ff-only origin master`);
      const gitCode = await streamSpawn(
        "git",
        ["-C", root, "pull", "--ff-only", "origin", "master"],
        undefined,
        onLine,
      );
      if (gitCode !== 0) {
        onLine(`(git exited ${gitCode}; not rebuilding)`);
        return gitCode;
      }
      const spawnScript = `${root}/script/leanclispawn`;
      onLine(`$ ${spawnScript} --pull --no-init`);
      const installCode = await streamSpawn(
        spawnScript,
        ["--pull", "--no-init"],
        root,
        onLine,
      );
      return installCode;
    }
  }
}

/** Action select panel + lifecycle overlay. Renders the available
 *  actions inline (Select) when idle; takes over the panel area when
 *  confirming / running / done. */
function ActionsPanel({
  snap,
  onActionDone,
  onPhaseChange,
}: {
  snap: Snapshot;
  /** Called after action completes (regardless of success). Triggers a
   *  status snapshot re-fetch so the page reflects the new daemon
   *  state. */
  onActionDone: () => void;
  /** Tell the parent whether we're holding the input focus. When true,
   *  the parent suspends its page-level `r` / `m` / `q` chord so we
   *  don't double-handle keys during confirm / run / done. */
  onPhaseChange?: (busy: boolean) => void;
}) {
  const [phase, setPhase] = useState<ActionPhase>({ kind: "idle" });
  // Mirror phase changes into the parent's busy flag so its
  // page-level useInput knows to step out of our way.
  useEffect(() => {
    onPhaseChange?.(phase.kind !== "idle");
  }, [phase.kind, onPhaseChange]);
  // Holds in-flight output as the action runs. We mirror into state
  // (lines) for rendering and into a ref (linesRef) so the closure
  // inside `runAction` can append without stale-state issues from React
  // batching.
  const linesRef = useRef<string[]>([]);

  const start = (id: ActionId) => {
    setPhase({ kind: "confirm", id, preview: previewFor(id, snap) });
  };

  const cancel = () => {
    setPhase({ kind: "idle" });
  };

  const proceed = async () => {
    if (phase.kind !== "confirm") return;
    const id = phase.id;
    linesRef.current = [];
    setPhase({ kind: "running", id, lines: [], exitCode: null });
    const code = await runAction(id, snap, (line) => {
      linesRef.current = [...linesRef.current, line];
      setPhase({
        kind: "running",
        id,
        lines: linesRef.current,
        exitCode: null,
      });
    });
    setPhase({
      kind: "done",
      id,
      ok: code === 0,
      lines: linesRef.current,
    });
    // Re-snap so the page reflects the post-action world. We do this
    // even on failure — the user wants to see "did it really fail?
    // what's the daemon state now?" without manually pressing R.
    onActionDone();
  };

  useInput((input, key) => {
    if (phase.kind === "confirm") {
      if (key.return) proceed();
      if (key.escape) cancel();
      return;
    }
    if (phase.kind === "done") {
      // Enter or Esc dismisses the result and returns to the action picker.
      if (key.return || key.escape) setPhase({ kind: "idle" });
      return;
    }
    // While running we intentionally ignore input so the user can't
    // half-kill an in-flight subprocess. They can still close the TUI.
  });

  if (phase.kind === "confirm") {
    return (
      <Section title="◆ Confirm action">
        <Box flexDirection="column">
          {phase.preview.split("\n").map((line, i) => (
            <Text key={i} color={i === 0 || i === 1 ? theme.highlight : theme.dim} wrap="wrap">
              {line || " "}
            </Text>
          ))}
        </Box>
        <Box marginTop={1}>
          <Text color={theme.ok} bold>[Enter]</Text>
          <Text color={theme.dim}> proceed  ·  </Text>
          <Text color={theme.warn} bold>[Esc]</Text>
          <Text color={theme.dim}> cancel</Text>
        </Box>
      </Section>
    );
  }

  if (phase.kind === "running" || phase.kind === "done") {
    const running = phase.kind === "running";
    const ok = phase.kind === "done" && phase.ok;
    const failed = phase.kind === "done" && !phase.ok;
    return (
      <Section title={`◆ ${labelFor(phase.id)}`}>
        <Box flexDirection="column">
          {phase.lines.slice(-20).map((line, i) => (
            <Text key={i} wrap="truncate-end" color={theme.dim}>
              {line.length > 200 ? line.slice(0, 200) + "…" : line}
            </Text>
          ))}
        </Box>
        <Box marginTop={1}>
          {running && (
            <Text>
              <Text color={theme.primary}>
                <Spinner type="dots" />
              </Text>{" "}
              <Text color={theme.dim}>running…</Text>
            </Text>
          )}
          {ok && (
            <>
              <Text color={theme.ok} bold>✓ done</Text>
              <Text color={theme.dim}>  ·  press Enter or Esc to dismiss</Text>
            </>
          )}
          {failed && (
            <>
              <Text color={theme.err} bold>✗ failed (exit nonzero)</Text>
              <Text color={theme.dim}>  ·  Enter / Esc to dismiss · check output above</Text>
            </>
          )}
        </Box>
      </Section>
    );
  }

  // idle
  const items = [
    { label: "↻  Restart daemon", value: "restart-daemon" as ActionId },
    { label: "⊕  Toggle sandbox mode (auto → off → require → auto)", value: "toggle-sandbox" as ActionId },
    { label: "⬇  Pull updates from origin + rebuild", value: "pull-updates" as ActionId },
  ];
  return (
    <Section title="Actions">
      <Select
        items={items}
        onSelect={(it) => start(it.value)}
      />
      <Box marginTop={1}>
        <Text color={theme.dim}>
          ↑/↓ choose · enter confirm · destructive actions show a preview before running
        </Text>
      </Box>
    </Section>
  );
}

function labelFor(id: ActionId): string {
  switch (id) {
    case "restart-daemon": return "Restart daemon";
    case "toggle-sandbox": return "Toggle sandbox";
    case "pull-updates":   return "Pull updates";
  }
}
