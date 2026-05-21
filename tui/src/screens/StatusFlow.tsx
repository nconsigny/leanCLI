import React, { useEffect, useState } from "react";
import { Box, Text, useInput } from "ink";
import Spinner from "ink-spinner";
import { Layout, Banner } from "../widgets/Layout.js";
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
  onBack: () => void;
};

/** Status page — cypherpunk-styled debugging surface. Single
 *  `status.snapshot` RPC fans out sidecar pings + sandbox probe
 *  daemon-side; the TUI just renders. R refreshes, M opens the live
 *  network monitor (preserves the existing trace tool), ESC/q backs out. */
export default function StatusFlow({ onLiveMonitor, onBack }: Props) {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [refreshing, setRefreshing] = useState(false);

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

  useInput((input, key) => {
    if (key.escape || key.leftArrow || input === "q") {
      onBack();
      return;
    }
    if (input === "r" || input === "R") setRefreshKey((k) => k + 1);
    if (input === "m" || input === "M") onLiveMonitor();
  });

  return (
    <Layout
      title="◉ Status — daemon · sidecars · sandbox · network"
      subtitle={
        snap
          ? `daemon pid ${snap.daemon.pid} · uptime ${fmtUptime(snap.daemon.uptimeMs)} · v${snap.daemon.version}`
          : "querying daemon…"
      }
      hint="r refresh · m live network monitor · ← / esc back · q quit"
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
          <SidecarsPanel sidecars={snap.sidecars} />
          <SandboxPanel sandbox={snap.sandbox} />
          <NetworkPanel network={snap.network} />
          <VersionsPanel versions={snap.versions} />
          <WalletPanel wallet={snap.wallet} />
        </Box>
      )}
    </Layout>
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
        <Text color={theme.dim}> for live RPC monitor (cypherpunk trace)</Text>
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
        v={versions.checkoutRoot ?? "<unknown — no $KOHAKU_HOME/checkout marker>"}
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
