import net from "node:net";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import { spawn } from "node:child_process";

/**
 * Minimal JSON-RPC client over the leanCLI daemon's UDS socket. Mirrors
 * the framing used by `LeanCli/Cli/DaemonClient.lean`: newline-delimited
 * JSON, requests carry an integer `id`, the daemon may emit notification
 * frames (no `result`/`error` field) interleaved with the response.
 *
 * This module holds no secrets in steady state — passphrases and PINs
 * are captured by per-flow form widgets, included once in the request
 * params, and the TUI only renders whatever notifications/responses the
 * daemon sends back.
 */

export type RpcError = { code: number; message: string };
export type RpcResult<T = unknown> =
  | { ok: true; result: T }
  | { ok: false; error: RpcError };

export type Notification = {
  event?: string;
  data?: Record<string, unknown>;
  raw: unknown;
};

export type NotificationHandler = (n: Notification) => void;

// JSON.stringify throws on BigInt. The daemon's `asNat` accepts arbitrary-precision
// JSON integers, so we emit BigInt as a bare numeric literal — needed for wei
// values above 2^53 (e.g. ≥0.01 ETH).
function stringifyWithBigInt(v: unknown): string {
  if (typeof v === "bigint") return v.toString();
  if (v === null || v === undefined) return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(stringifyWithBigInt).join(",") + "]";
  if (typeof v === "object") {
    const parts: string[] = [];
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      if (val === undefined) continue;
      parts.push(JSON.stringify(k) + ":" + stringifyWithBigInt(val));
    }
    return "{" + parts.join(",") + "}";
  }
  return JSON.stringify(v);
}

export function socketPath(): string {
  const env = process.env.LEANCLI_SOCKET;
  if (env && env.length > 0) return env;
  const runtimeDir = process.env.XDG_RUNTIME_DIR || "/tmp";
  return path.join(runtimeDir, "leancli", "leancli.sock");
}

/** Resolve the daemon binary the TUI should spawn when the socket is
 *  missing. Mirrors `LeanCli.Cli.DaemonClient.daemonBin`: env override
 *  first, then the standard install path under $HOME/.leancli/bin, then
 *  PATH lookup. The TUI runs as `node dist/index.mjs`, so unlike the
 *  Lean CLI we can't lean on IO.appDir — the install path is the
 *  closest equivalent. */
function daemonBinPath(): string {
  const env = process.env.LEANCLI_DAEMON_BIN;
  if (env && env.length > 0) return env;
  const installed = path.join(
    process.env.LEANCLI_HOME || path.join(os.homedir(), ".leancli"),
    "bin",
    "leancli-daemon",
  );
  if (fs.existsSync(installed)) return installed;
  return "leancli-daemon";
}

/** Match `DaemonClient.lean.noAutoSpawnMethod` — never auto-spawn for
 *  shutdown, otherwise stop-then-start loops would resurrect the daemon
 *  the user just asked to die. */
function noAutoSpawnMethod(method: string): boolean {
  return method === "daemon.shutdown";
}

function autoSpawnDisabled(): boolean {
  const v = process.env.LEANCLI_NO_AUTOSPAWN;
  if (!v) return false;
  const lc = v.toLowerCase();
  return lc !== "" && lc !== "0" && lc !== "false";
}

/** Path of the "this machine is managed by systemd" marker dropped by
 *  `leanclispawn`. Mirrors `DaemonClient.lean.systemdMarkerPath`: honors
 *  $XDG_CONFIG_HOME, falls back to $HOME/.config. Returns the path
 *  regardless of whether the file exists — callers stat it themselves. */
export function systemdMarkerPath(): string {
  const cfgRoot =
    process.env.XDG_CONFIG_HOME ||
    path.join(process.env.HOME || os.homedir(), ".config");
  return path.join(cfgRoot, "leancli", "managed-by-systemd");
}

/** True iff the systemd-handoff marker exists. Stat'd on every spawn
 *  attempt so removing the marker takes effect without restarting the
 *  TUI. Exported so BootGate can render an actionable notice instead
 *  of the bare ENOENT error. */
export function isSystemdManaged(): boolean {
  try {
    return fs.existsSync(systemdMarkerPath());
  } catch {
    return false;
  }
}

/** Try to connect once to the UDS to confirm the daemon is accepting
 *  connections. Used both as the post-spawn readiness check and as the
 *  failure trigger (ENOENT → spawn). */
function probeSocket(p: string, timeoutMs = 200): Promise<boolean> {
  return new Promise((resolve) => {
    const test = net.createConnection(p);
    const done = (ok: boolean) => {
      try { test.destroy(); } catch {}
      resolve(ok);
    };
    test.once("connect", () => done(true));
    test.once("error", () => done(false));
    setTimeout(() => done(false), timeoutMs);
  });
}

async function waitForSocket(p: string, attempts = 20): Promise<boolean> {
  for (let i = 0; i < attempts; i++) {
    if (await probeSocket(p)) return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

/** Spawn `leancli-daemon`, wait up to ~2s for the socket to bind, and
 *  return either ok or the daemon's stderr (the actionable failure
 *  reason — typically "no rpc_url configured" or a build/permissions
 *  issue). Mirrors `DaemonClient.lean.ensureDaemon`. */
async function ensureDaemon(
  p: string,
): Promise<{ ok: true } | { ok: false; reason: string }> {
  const bin = daemonBinPath();
  const stderrChunks: Buffer[] = [];
  let spawnErr: Error | null = null;
  let child;
  try {
    child = spawn(bin, [], {
      detached: true,
      // ignore stdin/stdout but pipe stderr so we can surface the daemon's
      // startup error message (e.g. "no rpc_url configured") if it dies
      // before binding the socket.
      stdio: ["ignore", "ignore", "pipe"],
      env: { ...process.env, LEANCLI_SOCKET: p },
    });
  } catch (e: any) {
    spawnErr = e;
  }
  if (spawnErr || !child) {
    return {
      ok: false,
      reason: `could not exec ${bin}: ${spawnErr?.message ?? "unknown error"}`,
    };
  }
  child.stderr?.on("data", (c: Buffer) => stderrChunks.push(c));
  if (await waitForSocket(p)) {
    // Detach so the daemon outlives this Node process.
    child.unref();
    return { ok: true };
  }
  // Socket never appeared. Give the child a moment to flush stderr,
  // then surface whatever it printed.
  await new Promise((r) => setTimeout(r, 200));
  const stderr = Buffer.concat(stderrChunks).toString("utf8").trim();
  return {
    ok: false,
    reason: stderr || "daemon spawned but socket did not appear within 2s",
  };
}

/** One-shot RPC call. Opens a fresh connection per request — this matches
 *  the Lean CLI's pattern (`callOnce` in DaemonClient.lean) so we never
 *  hold the socket exclusively while the user is idle in a menu. */
function callOnce<T = unknown>(
  method: string,
  params: unknown = [],
  opts: { onNotification?: NotificationHandler; timeoutMs?: number } = {},
): Promise<RpcResult<T>> {
  const { onNotification, timeoutMs = 60_000 } = opts;
  return new Promise((resolve) => {
    const sock = net.createConnection(socketPath());
    let buffer = "";
    let settled = false;

    const settle = (r: RpcResult<T>) => {
      if (settled) return;
      settled = true;
      try {
        sock.end();
      } catch {}
      resolve(r);
    };

    const timer = setTimeout(() => {
      settle({
        ok: false,
        error: { code: -32603, message: `daemon request timed out after ${timeoutMs}ms` },
      });
    }, timeoutMs);

    sock.on("connect", () => {
      const req = { jsonrpc: "2.0", method, params, id: 1 };
      sock.write(stringifyWithBigInt(req) + "\n");
    });

    sock.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const frame = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!frame) continue;
        let parsed: any;
        try {
          parsed = JSON.parse(frame);
        } catch (e) {
          settle({ ok: false, error: { code: -32700, message: `daemon emitted invalid JSON: ${frame}` } });
          return;
        }
        const hasResult = Object.prototype.hasOwnProperty.call(parsed, "result");
        const hasError = Object.prototype.hasOwnProperty.call(parsed, "error");
        if (!hasResult && !hasError) {
          // Notification frame.
          const params = parsed.params ?? parsed;
          onNotification?.({
            event: typeof params?.event === "string" ? params.event : undefined,
            data: typeof params?.data === "object" ? params.data : undefined,
            raw: parsed,
          });
          continue;
        }
        clearTimeout(timer);
        if (hasError) {
          const err = parsed.error ?? {};
          let message = typeof err.message === "string" ? err.message : "daemon error";
          if (err.data !== undefined) {
            try {
              message += ": " + JSON.stringify(err.data);
            } catch {}
          }
          settle({
            ok: false,
            error: { code: typeof err.code === "number" ? err.code : -32000, message },
          });
        } else {
          settle({ ok: true, result: parsed.result as T });
        }
        return;
      }
    });

    sock.on("error", (err) => {
      clearTimeout(timer);
      settle({
        ok: false,
        error: { code: -32603, message: `daemon transport error: ${err.message}` },
      });
    });

    sock.on("close", () => {
      clearTimeout(timer);
      if (!settled) {
        settle({
          ok: false,
          error: { code: -32603, message: "daemon closed connection before responding" },
        });
      }
    });
  });
}

/** Detect the "daemon isn't running" failure mode (ENOENT on UDS connect)
 *  so we know when to attempt auto-spawn. Other transport errors —
 *  permission denied, framing errors, timeouts — are not retryable here. */
function isSocketMissingError(err: RpcError): boolean {
  return err.code === -32603 && err.message.includes("ENOENT");
}

/** Public RPC entrypoint. Tries the call once; if the failure looks like
 *  "daemon not running" (UDS connect ENOENT) and autospawn isn't disabled
 *  for this method, spawns `leancli-daemon` in the background and retries
 *  once. This makes first-run flows (RpcSetupGate writes daemon.json,
 *  then the TUI moves on) and crash-recovery flows work without forcing
 *  the user to drop out of the TUI to run `leancli daemon ping`.
 *
 *  Mirrors LeanCli.Cli.DaemonClient.call: on auto-spawn failure we
 *  surface the daemon's own stderr (e.g. "no rpc_url configured") so the
 *  user sees what to fix instead of the bare ENOENT. */
export async function call<T = unknown>(
  method: string,
  params: unknown = [],
  opts: { onNotification?: NotificationHandler; timeoutMs?: number } = {},
): Promise<RpcResult<T>> {
  const first = await callOnce<T>(method, params, opts);
  if (first.ok) return first;
  if (
    noAutoSpawnMethod(method) ||
    autoSpawnDisabled() ||
    !isSocketMissingError(first.error)
  ) {
    return first;
  }
  if (isSystemdManaged()) {
    // leanclispawn dropped the marker — the daemon's lifecycle now lives
    // under the systemd user unit, and racing it with an autospawn would
    // recreate the multi-zombie state we just cleaned up. Surface a
    // structured error with the exact start command so the user sees
    // what to do without dropping out of the TUI.
    return {
      ok: false,
      error: {
        code: -32000,
        message:
          `leancli-daemon is managed by systemd on this machine ` +
          `(${systemdMarkerPath()} present). ` +
          `Start it with: systemctl --user start leancli-daemon`,
      },
    };
  }
  const spawnResult = await ensureDaemon(socketPath());
  if (!spawnResult.ok) {
    return {
      ok: false,
      error: {
        code: -32000,
        message: `daemon auto-spawn failed: ${spawnResult.reason}`,
      },
    };
  }
  return callOnce<T>(method, params, opts);
}

/* -------------------------------------------------------------------------- *
 * Read-only chat-history surface.
 *
 * These three stubs proxy to the agent daemon's `list_sessions` /
 * `get_session` / `list_proposed_txs` ops. All three are READ-ONLY — they
 * never produce calldata and never gate a signing decision. The wallet
 * daemon's handlers are pure proxies; the agentd applies the chainId /
 * sessionKey filters and the incognito mask.
 *
 * Persistent agent mode is required. On `leancli-agent` one-shot or the
 * legacy Node bridge these calls return -32601 ("history available only in
 * persistent mode") — the TUI surfaces a clear message in that case.
 * -------------------------------------------------------------------------- */

/** One session as returned by `chat.listSessions`. `chainId` and
 *  `sessionKey` are omitted when the on-disk metadata did not carry them
 *  (older rows). `firstUserPrompt` is truncated to 140 chars + ellipsis. */
export type SessionListEntry = {
  sessionId: number;
  createdAt: number;
  turnCount: number;
  chainId?: number;
  sessionKey?: string;
  firstUserPrompt?: string;
  lastTurnAt?: number;
};

/** One message row inside a `chat.getSession` reply. `toolCallsJson` is
 *  the raw JSON-encoded array as stored on disk; the renderer parses it
 *  the same way the live-turn trace renderer does. */
export type SessionTurn = {
  seq: number;
  appendedAt: number;
  role: "system" | "user" | "assistant" | "tool" | string;
  content: string;
  toolCallsJson?: string;
  toolCallId?: string;
};

/** One propose_send extracted from a session's tool-call log. */
export type ProposedTxEntry = {
  sessionId: number;
  sessionCreatedAt: number;
  turnIndex: number;
  ts: number;
  chainId: number;
  to: string;
  value: string;
  data: string;
  sender?: string;
  summaryFromTool?: string;
};

/** Read-only listing of recent sessions. Filters apply only when provided. */
export function chatListSessions(params: {
  limit?: number;
  chainId?: number;
  sessionKey?: string;
}): Promise<RpcResult<{ sessions: SessionListEntry[] }>> {
  return call<{ sessions: SessionListEntry[] }>("chat.listSessions", params, {
    timeoutMs: 15_000,
  });
}

/** Read-only fetch of one session's full transcript. The wallet daemon
 *  surfaces incognito sessions as a structured error with `data.kind ===
 *  "incognito"`; callers should branch on that. */
export function chatGetSession(
  sessionId: number,
): Promise<RpcResult<{ sessionId: number; createdAt: number; turns: SessionTurn[]; chainId?: number; sessionKey?: string }>> {
  return call("chat.getSession", { session_id: sessionId }, { timeoutMs: 15_000 });
}

/** Read-only walk of every non-incognito session's tool-call log to
 *  surface propose_send invocations newest-first. */
export function chatListProposedTxs(params: {
  limit?: number;
  chainId?: number;
}): Promise<RpcResult<{ txs: ProposedTxEntry[] }>> {
  return call<{ txs: ProposedTxEntry[] }>("chat.listProposedTxs", params, {
    timeoutMs: 30_000,
  });
}
