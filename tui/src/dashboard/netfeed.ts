import { useEffect, useRef, useState } from "react";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { call } from "../daemon.js";
import { usePoll } from "./poll.js";

/**
 * Networking-box data for the dashboard. Two sources, mirroring the
 * standalone NetworkMonitor screen:
 *
 *  1. The daemon's JSONL network log, tailed with one long-lived
 *     `tail -n 100 -F` child (the daemon emits raw events; ALL
 *     aggregation is client-side). One child per dashboard lifetime,
 *     SIGTERM'd on unmount — the pane itself never remounts, so no
 *     leak-per-cycle hazard.
 *  2. `status.snapshot` for the egress source IP / device per endpoint
 *     ("which local address does the wallet dial FROM" — VPN/split-tunnel
 *     awareness). That RPC fans out sidecar pings + `ip route get`
 *     subprocesses daemon-side, so it polls on a SLOW cadence (30s),
 *     never the tail's event rate.
 */

/** One JSONL line from the daemon's network logger — same shape as
 *  NetworkMonitor.tsx's LogEvent. ts_ms is IO.monoMsNow (monotonic, NOT
 *  wall-clock): only useful for ordering, never format as a timestamp. */
export type NetLogEvent = {
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
  chainId?: number;
};

export type NetStats = {
  total: number;
  requests: number;
  ok: number;
  errors: number;
  denied: number;
  totalMs: number;
  totalSamples: number;
  /** curl %{size_download} sum — DOWNSTREAM bytes only; there is no
   *  upstream byte counter anywhere in the daemon. Label accordingly. */
  totalBytes: number;
  lastErr?: string;
  /** Most recent server IP actually dialed (curl %{remote_ip}). */
  lastIp?: string;
};

const EMPTY_STATS: NetStats = {
  total: 0,
  requests: 0,
  ok: 0,
  errors: 0,
  denied: 0,
  totalMs: 0,
  totalSamples: 0,
  totalBytes: 0,
};

const ERROR_KINDS = new Set([
  "rpc-error",
  "exception",
  "parse-error",
  "malformed",
]);

function foldEvents(s: NetStats, fresh: NetLogEvent[]): NetStats {
  let { requests, ok, errors, denied, totalMs, totalSamples, totalBytes, lastErr, lastIp } = s;
  for (const e of fresh) {
    if (e.kind === "request") requests++;
    else if (e.kind === "response") ok++;
    else if (e.kind === "denied") denied++;
    if (ERROR_KINDS.has(e.kind)) {
      errors++;
      const msg = typeof e.error === "string" ? e.error : e.error ? JSON.stringify(e.error) : e.kind;
      lastErr = `${e.kind} ${e.method}: ${msg}`.slice(0, 120);
    }
    if (typeof e.ms === "number") {
      totalMs += e.ms;
      totalSamples++;
    }
    if (typeof e.bytes === "number") totalBytes += e.bytes;
    if (e.remoteIp) lastIp = e.remoteIp;
  }
  return {
    total: s.total + fresh.length,
    requests,
    ok,
    errors,
    denied,
    totalMs,
    totalSamples,
    totalBytes,
    lastErr,
    lastIp,
  };
}

export type NetFeed = {
  stats: NetStats;
  recent: NetLogEvent[];
  /** Tail-spawn / parse trouble — distinct from logPath===null (disabled). */
  error: string | null;
  clear: () => void;
};

/** Ring size for the dashboard's request tail. The network pane grows to
 *  ~30 rows in full screen and fills its spare height with events, so keep
 *  enough history to paint the tallest tail (the full monitor keeps more). */
const RECENT_CAP = 40;

/** Tail the daemon's network log. `logPath` comes from network.show
 *  (undefined = still resolving, null = LEANCLI_NETWORK_LOG=0). */
export function useNetFeed(logPath: string | null | undefined): NetFeed {
  const [stats, setStats] = useState<NetStats>(EMPTY_STATS);
  const [recent, setRecent] = useState<NetLogEvent[]>([]);
  const [error, setError] = useState<string | null>(null);
  const childRef = useRef<ChildProcessByStdio<null, Readable, Readable> | null>(null);

  useEffect(() => {
    if (!logPath) return;
    let buffer = "";
    let child: ChildProcessByStdio<null, Readable, Readable>;
    try {
      child = spawn("tail", ["-n", "100", "-F", logPath], {
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (e) {
      setError(`failed to spawn tail: ${(e as Error).message}`);
      return;
    }
    childRef.current = child;
    child.stdout.setEncoding("utf8");
    // Debounced flush: a chatty egress stream (helios light-client sync
    // emits many lines per second) must not repaint the dashboard once
    // per tail chunk — every setState here re-renders the WHOLE Ink
    // frame. Buffer parsed events and flush at most every FLUSH_MS; a
    // sub-half-second delay is invisible on a log feed, while the
    // repaint rate drops from per-event to a bounded cadence.
    const FLUSH_MS = 400;
    let pending: NetLogEvent[] = [];
    let flushTimer: NodeJS.Timeout | null = null;
    const flush = () => {
      flushTimer = null;
      if (pending.length === 0) return;
      const fresh = pending;
      pending = [];
      setStats((s) => foldEvents(s, fresh));
      setRecent((prev) => {
        const merged = prev.concat(fresh);
        return merged.length > RECENT_CAP ? merged.slice(merged.length - RECENT_CAP) : merged;
      });
    };
    child.stdout.on("data", (chunk: string) => {
      buffer += chunk;
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        try {
          const parsed = JSON.parse(line);
          if (parsed && typeof parsed === "object") pending.push(parsed as NetLogEvent);
        } catch {
          // partial/garbled line — skip
        }
      }
      if (pending.length > 0 && flushTimer === null) {
        flushTimer = setTimeout(flush, FLUSH_MS);
      }
    });
    child.on("error", (err) => setError(`tail error: ${err.message}`));
    return () => {
      if (flushTimer !== null) clearTimeout(flushTimer);
      try {
        child.kill("SIGTERM");
      } catch {}
      childRef.current = null;
    };
  }, [logPath]);

  return {
    stats,
    recent,
    error,
    clear: () => {
      setStats(EMPTY_STATS);
      setRecent([]);
    },
  };
}

/* ---------- status.snapshot (egress + wallet posture) ---------- */

export type EndpointInfo = {
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

export type StatusSnapshot = {
  daemon: { pid: number; uptimeMs: number; version: string };
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
  };
  /** Build provenance for the running daemon. `stale` is true when a
   *  newer daemon binary exists on disk than the process is running —
   *  i.e. you rebuilt but never bounced the daemon. Optional because
   *  older daemons don't emit it. */
  versions?: {
    checkoutRoot: string | null;
    /** `{semver}+{commit-count}`, e.g. "0.1.0+1487" — increases per commit. */
    buildVersion: string;
    /** Short HEAD sha (with `*` if the tree was dirty at build). */
    buildSha: string;
    daemonBinMtimeMs: number | null;
    daemonBinOnDiskMtimeMs: number | null;
    runningBinMtimeMs: number | null;
    stale: boolean;
    tuiBundleMtimeMs: number | null;
    gitHead: string;
  };
};

/** Slow-cadence poll of the heavy status.snapshot RPC. 30s default —
 *  it spawns sidecar pings + per-endpoint `ip route get`/`getent`
 *  subprocesses daemon-side on every call. */
export function useStatusSnapshot(intervalMs: number): {
  snap: StatusSnapshot | null;
  error: string | null;
} {
  const [snap, setSnap] = useState<StatusSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);

  usePoll(
    async (isCancelled) => {
      const r = await call<StatusSnapshot>("status.snapshot", {}, { timeoutMs: 20_000 });
      if (isCancelled()) return;
      if (r.ok) {
        setSnap(r.result);
        setError(null);
      } else {
        setError(r.error.message);
      }
    },
    intervalMs,
    [],
  );

  return { snap, error };
}
