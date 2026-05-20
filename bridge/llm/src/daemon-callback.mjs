// Daemon callback — UDS JSON-RPC client for the LLM sidecar.
//
// Resolves the daemon socket using the same convention as the Lean CLI
// (`LeanKohaku.Cli.DaemonClient`):
//   1. LEANKOHAKU_SOCKET env (explicit override)
//   2. ${XDG_RUNTIME_DIR:-/tmp}/leankohaku/leankohaku.sock (default)
//
// Trust model: the sidecar is treated as malicious. Every call this
// module makes goes through the daemon's normal RPC surface — the same
// `Privacy.NetworkPolicy` gate that fires for CLI/TUI requests. The
// daemon authenticates clients by UDS file permissions (mode 0600,
// owned by the user that started the daemon); no extra auth needed at
// this layer.

import net from "node:net";
import path from "node:path";

const DEFAULT_TIMEOUT_MS = 5_000;
const MAX_RESPONSE_BYTES = 32_768;

function resolveSocketPath() {
  if (process.env.LEANKOHAKU_SOCKET) return process.env.LEANKOHAKU_SOCKET;
  const runtimeDir = process.env.XDG_RUNTIME_DIR ?? "/tmp";
  return path.join(runtimeDir, "leankohaku", "leankohaku.sock");
}

let nextId = 1;

/** Open a fresh UDS connection per call. The daemon's RPC handlers
 *  expect one request → one response and close; pooling would require
 *  framing changes on the daemon side. Per-call cost on UDS is
 *  negligible (<1ms locally). */
export function dispatch(method, params, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const socketPath = opts.socketPath ?? resolveSocketPath();
  const id = nextId++;
  const payload = JSON.stringify({ jsonrpc: "2.0", method, params, id }) + "\n";

  return new Promise((resolve, reject) => {
    const sock = net.createConnection(socketPath);
    let buf = Buffer.alloc(0);
    let settled = false;
    const finish = (fn, arg) => {
      if (settled) return;
      settled = true;
      sock.destroy();
      fn(arg);
    };
    const timer = setTimeout(() => {
      finish(reject, new Error(`daemon callback ${method} timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    sock.on("connect", () => sock.write(payload));
    sock.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (buf.length > MAX_RESPONSE_BYTES) {
        clearTimeout(timer);
        finish(reject, new Error(`daemon callback ${method} response exceeded ${MAX_RESPONSE_BYTES} bytes`));
        return;
      }
      // Daemon writes one JSON object then closes — wait for end.
    });
    sock.on("end", () => {
      clearTimeout(timer);
      try {
        const text = buf.toString("utf8").trim();
        const lastNewline = text.lastIndexOf("\n");
        const last = lastNewline >= 0 ? text.slice(lastNewline + 1) : text;
        const resp = JSON.parse(last);
        if (resp.error) {
          finish(reject, new Error(`daemon ${method} error ${resp.error.code}: ${resp.error.message}`));
        } else {
          finish(resolve, resp.result);
        }
      } catch (e) {
        finish(reject, new Error(`daemon ${method} response was not JSON: ${e.message}`));
      }
    });
    sock.on("error", (e) => {
      clearTimeout(timer);
      finish(reject, e);
    });
  });
}

/** Helper for callers that want a "best-effort, never throws" wrapper.
 *  Returns `{ ok: true, result }` or `{ ok: false, error }`. Used by
 *  tool implementations so a single tool failure surfaces as a tool
 *  result the model can reason about, not an exception that kills the
 *  loop. */
export async function tryDispatch(method, params, opts) {
  try {
    const result = await dispatch(method, params, opts);
    return { ok: true, result };
  } catch (e) {
    return { ok: false, error: e?.message ?? String(e) };
  }
}
