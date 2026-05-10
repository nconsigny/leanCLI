import React, { useEffect, useMemo, useRef, useState } from "react";
import { Box, Text, useInput, useStdout } from "ink";
import Spinner from "ink-spinner";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { Layout, Banner } from "../widgets/Layout.js";
import { call } from "../daemon.js";
import { theme } from "../theme.js";

/** Hook into Ink's stdout to recompute layout on terminal resize. We pin
 *  per-column proportions to the visible width so panels/rows never spill
 *  into a second line. */
function useTerminalColumns(): number {
  const { stdout } = useStdout();
  const [cols, setCols] = useState<number>(stdout?.columns ?? 100);
  useEffect(() => {
    if (!stdout) return;
    const onResize = () => setCols(stdout.columns ?? 100);
    stdout.on("resize", onResize);
    return () => {
      stdout.off("resize", onResize);
    };
  }, [stdout]);
  return cols;
}

/** One JSONL line emitted by the daemon's network logger. The daemon
 *  writes objects keyed by `kind` and `method`; everything else is opaque
 *  metadata we render best-effort. */
type LogEvent = {
  ts_ms: number;
  kind: string;
  method: string;
  url?: string;
  host?: string;
  backend?: string;
  transport?: string;
  ms?: number;
  httpStatus?: number;
  bytes?: number;
  remoteIp?: string;
  error?: string | Record<string, unknown>;
  params?: unknown;
  result?: unknown;
  chainId?: number;
};

type Stats = {
  total: number;
  byKind: Record<string, number>;
  byMethod: Record<string, number>;
  byHost: Record<string, number>;
  byBackend: Record<string, number>;
  totalMs: number;
  totalSamples: number;
  totalBytes: number;
  lastErr?: string;
  lastIp?: string;
};

const MAX_ROWS = 200;

type NetSnapshot = { logPath: string | null };

type Props = { onDone: () => void };

/** Live cypherpunk-style monitor. Spawns `tail -F` on the daemon's network
 *  log JSONL file, parses each line, and renders a colour-coded scroll
 *  with a stats bar and the most recent N events. ESC quits and kills the
 *  child process. */
export default function NetworkMonitor({ onDone }: Props) {
  const cols = useTerminalColumns();
  const [logPath, setLogPath] = useState<string | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [events, setEvents] = useState<LogEvent[]>([]);
  const [stats, setStats] = useState<Stats>({
    total: 0,
    byKind: {},
    byMethod: {},
    byHost: {},
    byBackend: {},
    totalMs: 0,
    totalSamples: 0,
    totalBytes: 0,
  });
  const [paused, setPaused] = useState(false);
  const pausedRef = useRef(paused);
  pausedRef.current = paused;
  const tailRef = useRef<ChildProcessByStdio<null, Readable, Readable> | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await call<NetSnapshot>("network.show", []);
      if (cancelled) return;
      if (!r.ok) {
        setError(`network.show failed: ${r.error.message}`);
        setLogPath(null);
        return;
      }
      setLogPath(r.result?.logPath ?? null);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!logPath) return;
    let buffer = "";
    let child: ChildProcessByStdio<null, Readable, Readable>;
    try {
      child = spawn("tail", ["-n", "200", "-F", logPath], {
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (e) {
      setError(`failed to spawn tail: ${(e as Error).message}`);
      return;
    }
    tailRef.current = child;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (pausedRef.current) {
        // Drop incoming frames while paused so the "frozen" view stays
        // exactly what the user wanted to inspect. Stats reflect the
        // actual stream so they keep counting.
      }
      buffer += chunk;
      let nl;
      const fresh: LogEvent[] = [];
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        let parsed: any;
        try {
          parsed = JSON.parse(line);
        } catch {
          continue;
        }
        if (!parsed || typeof parsed !== "object") continue;
        fresh.push(parsed as LogEvent);
      }
      if (fresh.length === 0) return;
      setStats((s) => updateStats(s, fresh));
      if (!pausedRef.current) {
        setEvents((prev) => {
          const merged = prev.concat(fresh);
          if (merged.length > MAX_ROWS) {
            return merged.slice(merged.length - MAX_ROWS);
          }
          return merged;
        });
      }
    });
    child.on("error", (err) => {
      setError(`tail error: ${err.message}`);
    });
    child.on("exit", (code) => {
      if (code !== 0 && code !== null) {
        setError(`tail exited with code ${code}`);
      }
    });
    return () => {
      try {
        child.kill("SIGTERM");
      } catch {}
      tailRef.current = null;
    };
  }, [logPath]);

  useInput((input, key) => {
    if (key.escape || key.leftArrow || input === "q") {
      onDone();
      return;
    }
    if (input === "p" || input === " ") {
      setPaused((p) => !p);
      return;
    }
    if (input === "c") {
      setEvents([]);
      setStats({
        total: 0,
        byKind: {},
        byMethod: {},
        byHost: {},
        byBackend: {},
        totalMs: 0,
        totalSamples: 0,
        totalBytes: 0,
      });
    }
  });

  const recent = useMemo(() => events.slice(-30), [events]);

  return (
    <Layout
      title="◉ Network monitor — live RPC trace"
      subtitle={
        logPath
          ? `tailing ${logPath}`
          : logPath === null && error === null
            ? "log disabled (LEANKOHAKU_NETWORK_LOG=0)"
            : "starting…"
      }
      hint="space/p pause · c clear · ← / esc back"
    >
      {error && <Banner kind="err" text={error} />}
      {logPath === undefined && (
        <Text>
          <Text color={theme.primary}>
            <Spinner type="dots" />
          </Text>{" "}
          <Text color={theme.dim}>resolving log path…</Text>
        </Text>
      )}
      {logPath === null && !error && (
        <Banner
          kind="warn"
          text="network log disabled — set LEANKOHAKU_NETWORK_LOG=1 (or unset) and restart the daemon"
        />
      )}
      {logPath && (
        <>
          <StatsBar stats={stats} paused={paused} cols={cols} />
          <BreakdownPanels stats={stats} cols={cols} />
          <Box flexDirection="column" marginTop={1}>
            <HeaderRow cols={cols} />
            {recent.length === 0 && (
              <Text color={theme.dim}>
                waiting for traffic on {logPath}…
              </Text>
            )}
            {recent.map((e, i) => (
              <EventRow key={`${e.ts_ms}-${i}`} e={e} cols={cols} />
            ))}
          </Box>
        </>
      )}
    </Layout>
  );
}

function updateStats(s: Stats, fresh: LogEvent[]): Stats {
  const byKind = { ...s.byKind };
  const byMethod = { ...s.byMethod };
  const byHost = { ...s.byHost };
  const byBackend = { ...s.byBackend };
  let totalMs = s.totalMs;
  let totalSamples = s.totalSamples;
  let totalBytes = s.totalBytes;
  let lastErr = s.lastErr;
  let lastIp = s.lastIp;
  for (const e of fresh) {
    byKind[e.kind] = (byKind[e.kind] ?? 0) + 1;
    // Count one row per request so the `byMethod` panel reflects how
    // often a verb is actually called (not 2× for each request+response).
    if (e.kind === "request" && e.method) {
      byMethod[e.method] = (byMethod[e.method] ?? 0) + 1;
    }
    if (e.host) byHost[e.host] = (byHost[e.host] ?? 0) + 1;
    if (e.backend) byBackend[e.backend] = (byBackend[e.backend] ?? 0) + 1;
    if (typeof e.ms === "number") {
      totalMs += e.ms;
      totalSamples += 1;
    }
    if (typeof e.bytes === "number") totalBytes += e.bytes;
    if (e.remoteIp) lastIp = e.remoteIp;
    if (
      e.kind === "rpc-error" ||
      e.kind === "exception" ||
      e.kind === "parse-error" ||
      e.kind === "denied" ||
      e.kind === "malformed"
    ) {
      const errStr =
        typeof e.error === "string"
          ? e.error
          : e.error
            ? safeJson(e.error)
            : e.kind;
      lastErr = `${e.kind} ${e.method}: ${truncate(errStr, 80)}`;
    }
  }
  return {
    total: s.total + fresh.length,
    byKind,
    byMethod,
    byHost,
    byBackend,
    totalMs,
    totalSamples,
    totalBytes,
    lastErr,
    lastIp,
  };
}

function StatsBar({ stats, paused, cols }: { stats: Stats; paused: boolean; cols: number }) {
  const avgMs =
    stats.totalSamples === 0 ? 0 : Math.round(stats.totalMs / stats.totalSamples);
  const ok = stats.byKind["response"] ?? 0;
  const err =
    (stats.byKind["rpc-error"] ?? 0) +
    (stats.byKind["exception"] ?? 0) +
    (stats.byKind["parse-error"] ?? 0) +
    (stats.byKind["malformed"] ?? 0);
  const denied = stats.byKind["denied"] ?? 0;
  const reqs = stats.byKind["request"] ?? 0;
  // Reserve room for round-corner border (2) + horizontal padding (2).
  const inner = Math.max(20, cols - 6);
  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={theme.koiRed}
      paddingX={1}
    >
      <Text wrap="truncate-end">
        <Text color={theme.koiCream} bold>
          {paused ? "❚❚ PAUSED " : "▶ LIVE    "}
        </Text>
        <Text color={theme.dim}>events </Text>
        <Text color={theme.highlight} bold>
          {String(stats.total).padStart(5)}
        </Text>
        <Text color={theme.dim}>   req </Text>
        <Text color={theme.primary}>{reqs}</Text>
        <Text color={theme.dim}>   ok </Text>
        <Text color={theme.ok}>{ok}</Text>
        <Text color={theme.dim}>   err </Text>
        <Text color={theme.err}>{err}</Text>
        <Text color={theme.dim}>   denied </Text>
        <Text color={theme.warn}>{denied}</Text>
        <Text color={theme.dim}>   avg </Text>
        <Text color={theme.accent}>{avgMs}ms</Text>
        <Text color={theme.dim}>   ↓ </Text>
        <Text color={theme.accent}>{formatBytes(stats.totalBytes)}</Text>
        {stats.lastIp && (
          <>
            <Text color={theme.dim}>   ip </Text>
            <Text color={theme.koiCream}>{stats.lastIp}</Text>
          </>
        )}
      </Text>
      {stats.lastErr && (
        <Text wrap="truncate-end">
          <Text color={theme.err}>last-err </Text>
          <Text color={theme.dim}>{truncate(stats.lastErr, inner - 10)}</Text>
        </Text>
      )}
    </Box>
  );
}

/** Side-by-side breakdown of *what* the daemon hit and *where*. Top-N
 *  entries by call count so the user sees their busiest verbs/hosts at a
 *  glance — answers "is it just one method blasting away or am I really
 *  hitting that many endpoints?" */
function BreakdownPanels({ stats, cols }: { stats: Stats; cols: number }) {
  const methods = topN(stats.byMethod, 8);
  const hosts = topN(stats.byHost, 6);
  const backends = topN(stats.byBackend, 4);
  // Subtract the two `marginRight={1}` and a small safety margin so the
  // three panels never wrap onto a new row. Distribute 50% / 30% / 20%
  // with hard floors so each panel still has room for "key  N" rows.
  const usable = Math.max(40, cols - 4);
  const methodW = Math.max(28, Math.floor(usable * 0.5));
  const hostW = Math.max(20, Math.floor(usable * 0.3));
  const backendW = Math.max(14, usable - methodW - hostW - 2);
  return (
    <Box marginTop={1} flexDirection="row">
      <Panel title="by RPC method" rows={methods} valColor={theme.primary} width={methodW} />
      <Panel title="by host" rows={hosts} valColor={theme.accent} width={hostW} />
      <Panel title="by backend" rows={backends} valColor={theme.ok} width={backendW} />
    </Box>
  );
}

function Panel({
  title,
  rows,
  valColor,
  width,
}: {
  title: string;
  rows: { key: string; count: number }[];
  valColor: string;
  width: number;
}) {
  // Inner content area: subtract border (2) + paddingX(2) = 4.
  const inner = Math.max(6, width - 4);
  return (
    <Box
      flexDirection="column"
      borderStyle="single"
      borderColor={theme.dim}
      paddingX={1}
      width={width}
      marginRight={1}
    >
      <Text color={theme.dim} bold wrap="truncate-end">
        {title}
      </Text>
      {rows.length === 0 && <Text color={theme.dim}>—</Text>}
      {rows.map((r) => {
        const countStr = String(r.count);
        // Reserve room for the count + at least one separator space, then
        // truncate the key with an ellipsis so the row always fits inner
        // width on a single line.
        const keyMax = Math.max(3, inner - countStr.length - 1);
        const key =
          r.key.length > keyMax ? r.key.slice(0, keyMax - 1) + "…" : r.key;
        const pad = " ".repeat(Math.max(1, inner - key.length - countStr.length));
        return (
          <Text key={r.key} wrap="truncate-end">
            <Text color={valColor}>{key}</Text>
            <Text color={theme.dim}>
              {pad}
              {countStr}
            </Text>
          </Text>
        );
      })}
    </Box>
  );
}

function topN(map: Record<string, number>, n: number): { key: string; count: number }[] {
  return Object.entries(map)
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, n);
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

/** Distribute a row's columns across the visible terminal width so the
 *  line never wraps. Returns widths with hard floors that still keep
 *  every column readable on an 80-col terminal. */
function rowLayout(cols: number) {
  const usable = Math.max(60, cols - 2);
  // Fixed mini-columns: glyph(2) + time(7) + kind(12) + status(8) + ms(7)
  // = 36. Remaining is shared between method (60%) and host (40%), with
  // a small detail tail when the terminal is wide enough.
  const fixed = 2 + 7 + 12 + 8 + 7;
  const flex = Math.max(20, usable - fixed - 2);
  const wMethod = Math.max(14, Math.floor(flex * 0.45));
  const wHost = Math.max(10, Math.floor(flex * 0.30));
  const wDetail = Math.max(0, flex - wMethod - wHost - 2);
  return { wMethod, wHost, wDetail };
}

function HeaderRow({ cols }: { cols: number }) {
  const { wMethod, wHost, wDetail } = rowLayout(cols);
  const cell = (s: string, n: number) =>
    s.length >= n ? s.slice(0, n) : s + " ".repeat(n - s.length);
  return (
    <Text wrap="truncate-end" color={theme.dim} bold>
      {"  "}
      {cell("t", 7)} {cell("kind", 12)} {cell("method", wMethod)}{" "}
      {cell("host", wHost)} {cell("status", 8)} {cell("ms", 6)}
      {wDetail > 0 ? "  " + cell("detail", wDetail) : ""}
    </Text>
  );
}

function EventRow({ e, cols }: { e: LogEvent; cols: number }) {
  const { wMethod, wHost, wDetail } = rowLayout(cols);
  const kindColor = colorForKind(e.kind);
  const glyph = glyphForKind(e.kind);
  const t = formatRelTime(e.ts_ms);
  const cell = (s: string, n: number) =>
    s.length >= n ? s.slice(0, Math.max(0, n - 1)) + "…" : s + " ".repeat(n - s.length);
  const method = cell(e.method ?? "?", wMethod);
  const kind = cell(e.kind ?? "?", 12);
  const host = cell(e.host ?? e.backend ?? "—", wHost);
  const status =
    e.httpStatus !== undefined
      ? String(e.httpStatus).padStart(3) +
        (e.bytes !== undefined ? ` ${shortBytes(e.bytes)}` : "")
      : (e.transport ?? "").padStart(7);
  const statusPadded = cell(status, 8);
  const ms = e.ms !== undefined ? String(e.ms).padStart(4) : "    ";
  const detail = wDetail > 0 ? cell(describeDetail(e), wDetail) : "";
  const statusColor =
    e.httpStatus !== undefined
      ? e.httpStatus >= 200 && e.httpStatus < 300
        ? theme.ok
        : e.httpStatus >= 400
          ? theme.err
          : theme.warn
      : theme.dim;
  // Single <Text wrap="truncate-end"> guarantees one terminal line per
  // event no matter how narrow the window — fixes the "row wraps onto a
  // blank second line" rendering on small terminals.
  return (
    <Text wrap="truncate-end">
      <Text color={kindColor}>{glyph} </Text>
      <Text color={theme.dim}>{t} </Text>
      <Text color={kindColor}>{kind} </Text>
      <Text color={theme.primary}>{method} </Text>
      <Text color={theme.accent}>{host} </Text>
      <Text color={statusColor}>{statusPadded} </Text>
      <Text color={theme.dim}>{ms}ms</Text>
      {wDetail > 0 && (
        <>
          <Text color={theme.dim}>{"  " + detail}</Text>
        </>
      )}
    </Text>
  );
}

function shortBytes(n: number): string {
  if (n < 1024) return `${n}B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)}K`;
  return `${(n / (1024 * 1024)).toFixed(1)}M`;
}

function colorForKind(kind: string): string {
  switch (kind) {
    case "request":
      return theme.dim;
    case "response":
      return theme.ok;
    case "rpc-error":
    case "exception":
    case "parse-error":
    case "malformed":
      return theme.err;
    case "denied":
      return theme.warn;
    default:
      return theme.accent;
  }
}

function glyphForKind(kind: string): string {
  switch (kind) {
    case "request":
      return "→";
    case "response":
      return "←";
    case "rpc-error":
    case "exception":
    case "parse-error":
    case "malformed":
      return "✗";
    case "denied":
      return "⊘";
    default:
      return "·";
  }
}

function describeDetail(e: LogEvent): string {
  if (e.error) {
    const s = typeof e.error === "string" ? e.error : safeJson(e.error);
    return truncate(s, 70);
  }
  if (e.url) return truncate(e.url, 70);
  if (e.kind === "response" && e.method) return "ok";
  return "";
}

function formatRelTime(tsMs: number): string {
  // The daemon stamps `ts_ms` from `IO.monoMsNow`, which is a monotonic
  // value not aligned to wall-clock — formatting it as wall-clock would
  // be a lie. Show modulo 100s so the user can still gauge ordering and
  // bursts; use a fixed-width 6-char field so columns line up.
  const sec = Math.floor((tsMs % 100000) / 1000);
  const ms = tsMs % 1000;
  return `${String(sec).padStart(2, "0")}.${String(ms).padStart(3, "0")}`;
}

function truncate(s: string, n: number): string {
  if (s.length <= n) return s;
  return s.slice(0, n - 1) + "…";
}

function safeJson(v: unknown): string {
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}
