import net from "node:net";
import path from "node:path";
import os from "node:os";

/**
 * Minimal JSON-RPC client over the leanKohaku daemon's UDS socket. Mirrors
 * the framing used by `LeanKohaku/Cli/DaemonClient.lean`: newline-delimited
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
  const env = process.env.LEANKOHAKU_SOCKET;
  if (env && env.length > 0) return env;
  const runtimeDir = process.env.XDG_RUNTIME_DIR || "/tmp";
  return path.join(runtimeDir, "leankohaku", "leankohaku.sock");
}

/** One-shot RPC call. Opens a fresh connection per request — this matches
 *  the Lean CLI's pattern (`callOnce` in DaemonClient.lean) so we never
 *  hold the socket exclusively while the user is idle in a menu. */
export function call<T = unknown>(
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
