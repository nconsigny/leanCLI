#!/usr/bin/env node
// leankohaku-colibri-bridge — JSON-RPC sidecar exposing the Colibri
// stateless light client. Two modes:
//
//   --rpc '<json>'        one-shot: dispatch one request, write response,
//                         exit. Used for the original `tx.simulateColibri`
//                         path before persistent transport landed.
//
//   --listen <socket>     long-running: bind a Unix-domain socket, accept
//                         a single peer, read newline-delimited JSON-RPC
//                         requests, write newline-delimited responses.
//                         Maintains one C4Client per chainId so the sync-
//                         committee bootstrap is paid once per chain per
//                         lifetime — fixes the cold-start problem the
//                         one-shot mode hits on every call.
//
// Methods (both modes):
//   ping
//   eth.proxy   { chainId, method, params } -> raw RPC result
//   tx.simulate { chainId, from, to, value, data, block? } -> SimulationResult
//
// SECURITY: This process executes EVM locally with state pulled via
// committee-signed proofs. The Lean side treats the output as UNTRUSTED
// for signing decisions — it is rendered as confirmation UI only; the
// transaction structure is re-decoded in Lean before signing.

import C4Client from "@corpus-core/colibri-stateless";
import net from "node:net";
import fs from "node:fs";

const PROTOCOL_VERSION = "0.0.1";

function jsonReplacer(_k, v) {
  if (typeof v === "bigint") return "0x" + v.toString(16);
  if (v instanceof Uint8Array) return "0x" + Buffer.from(v).toString("hex");
  return v;
}

function ok(id, result) {
  return JSON.stringify({ jsonrpc: "2.0", id: id ?? null, result }, jsonReplacer);
}

function err(id, code, message, data) {
  const e = { code, message };
  if (data !== undefined) e.data = data;
  return JSON.stringify({ jsonrpc: "2.0", id: id ?? null, error: e });
}

// One C4Client per chainId. Persistent for the lifetime of --listen mode.
// In --rpc mode each invocation has its own clients map (and pays cold
// start), since the process exits after the response.
const clients = new Map();

function getClient(chainId) {
  let c = clients.get(chainId);
  if (!c) {
    c = new C4Client({ chainId });
    clients.set(chainId, c);
  }
  return c;
}

// Drop log entries that cannot have been emitted by EVM execution. The
// colibri stateless client surfaces native ETH movements as synthetic
// "Transfer"-shaped rows alongside real ABI-decoded logs, which the TUI
// renders indistinguishably from real events. Real EVM logs always carry
// the emitting contract's `address`; synthesized rows lack it. Also: a tx
// that consumed exactly 21000 gas (intrinsic floor) ran no contract code
// and therefore cannot have any real logs at all.
function stripSyntheticLogs(result) {
  if (!result || typeof result !== "object" || !Array.isArray(result.logs)) {
    return result;
  }
  let gasUsed;
  try { gasUsed = BigInt(result.gasUsed ?? "0x0"); } catch { gasUsed = -1n; }
  const noEvmCodeRan = gasUsed === 21000n;
  const logs = noEvmCodeRan
    ? []
    : result.logs.filter((l) => l && typeof l === "object"
        && typeof l.address === "string"
        && l.address.startsWith("0x"));
  return { ...result, logs };
}

async function dispatch(method, params, id) {
  switch (method) {
    case "ping":
      return ok(id, {
        ok: true,
        protocol: PROTOCOL_VERSION,
        warmChains: Array.from(clients.keys()),
      });

    case "eth.proxy": {
      if (!params || typeof params !== "object") {
        return err(id, -32602, "params must be an object");
      }
      const chainId = Number(params.chainId);
      if (!Number.isFinite(chainId) || chainId <= 0) {
        return err(id, -32602, "params.chainId must be a positive integer");
      }
      if (typeof params.method !== "string") {
        return err(id, -32602, "params.method must be a string");
      }
      const inner = Array.isArray(params.params) ? params.params : [];
      try {
        const result = await getClient(chainId).request({
          method: params.method,
          params: inner,
        });
        return ok(id, result);
      } catch (e) {
        return err(id, -32603, `eth.proxy ${params.method} failed: ${e?.message ?? e}`, {
          method: params.method,
          stack: String(e?.stack ?? ""),
        });
      }
    }

    case "tx.simulate": {
      if (!params || typeof params !== "object") {
        return err(id, -32602, "params must be an object");
      }
      const chainId = Number(params.chainId);
      if (!Number.isFinite(chainId) || chainId <= 0) {
        return err(id, -32602, "params.chainId must be a positive integer");
      }
      if (typeof params.to !== "string" || !params.to.startsWith("0x")) {
        return err(id, -32602, "params.to must be a 0x-prefixed address");
      }
      const txObj = {
        from: params.from,
        to: params.to,
        value: params.value ?? "0x0",
        data: params.data ?? "0x",
      };
      for (const k of Object.keys(txObj)) {
        if (txObj[k] === undefined) delete txObj[k];
      }
      const block = params.block ?? "latest";
      try {
        const result = await getClient(chainId).request({
          method: "colibri_simulateTransaction",
          params: [txObj, block],
        });
        return ok(id, stripSyntheticLogs(result));
      } catch (e) {
        return err(id, -32603, `simulate failed: ${e?.message ?? e}`, {
          stack: String(e?.stack ?? ""),
        });
      }
    }

    default:
      return err(id, -32601, `method not found: ${method}`);
  }
}

// ---------- mode dispatch ----------

const argv = process.argv.slice(2);
const listenIdx = argv.indexOf("--listen");
const rpcIdx = argv.indexOf("--rpc");

if (listenIdx !== -1 && argv[listenIdx + 1]) {
  // --listen <socket-path>: long-running daemon-managed mode.
  const socketPath = argv[listenIdx + 1];
  // Clean up stale socket from a previous crashed run. The daemon owns
  // this path; if a live process is already bound, listen() will fail
  // and we abort cleanly.
  try {
    fs.unlinkSync(socketPath);
  } catch (e) {
    if (e?.code !== "ENOENT") {
      process.stderr.write(`[colibri] could not remove stale socket ${socketPath}: ${e.message}\n`);
    }
  }

  const server = net.createServer((conn) => {
    let buf = "";
    conn.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      // Newline-delimited JSON. Each complete line is one request.
      let idx;
      while ((idx = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (!line.trim()) continue;
        let req;
        try {
          req = JSON.parse(line);
        } catch (e) {
          conn.write(err(null, -32700, `parse error: ${e?.message ?? e}`) + "\n");
          continue;
        }
        // Dispatch is async; serialize on this conn by chaining off a per-
        // conn promise so responses go out in arrival order.
        Promise.resolve()
          .then(() => dispatch(req?.method, req?.params, req?.id))
          .then((out) => {
            try { conn.write(out + "\n"); } catch { /* peer gone */ }
          })
          .catch((e) => {
            try {
              conn.write(err(req?.id ?? null, -32603, `dispatch crash: ${e?.message ?? e}`) + "\n");
            } catch { /* peer gone */ }
          });
      }
    });
    conn.on("error", (e) => {
      process.stderr.write(`[colibri] conn error: ${e?.message ?? e}\n`);
    });
  });

  server.on("error", (e) => {
    process.stderr.write(`[colibri] server error: ${e?.message ?? e}\n`);
    process.exit(1);
  });

  server.listen(socketPath, () => {
    try {
      fs.chmodSync(socketPath, 0o600);
    } catch { /* best-effort */ }
    process.stderr.write(`[colibri] listening on ${socketPath}\n`);
  });

  const shutdown = () => {
    try { server.close(); } catch {}
    for (const c of clients.values()) { try { c.destroy?.(); } catch {} }
    try { fs.unlinkSync(socketPath); } catch {}
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
} else if (rpcIdx !== -1 && argv[rpcIdx + 1]) {
  // --rpc '<json>': legacy one-shot mode. Pays cold-start every invocation;
  // kept for backward compat with the original tx.simulateColibri handler
  // before persistent transport landed.
  let req;
  try {
    req = JSON.parse(argv[rpcIdx + 1]);
  } catch (e) {
    process.stdout.write(err(null, -32700, `parse error: ${e?.message ?? e}`));
    process.stdout.write("\n");
    process.exit(0);
  }
  try {
    const out = await dispatch(req?.method, req?.params, req?.id);
    process.stdout.write(out);
    process.stdout.write("\n");
    for (const c of clients.values()) { try { c.destroy?.(); } catch {} }
  } catch (e) {
    process.stdout.write(
      err(req?.id ?? null, -32603, `dispatch crash: ${e?.message ?? e}`),
    );
    process.stdout.write("\n");
    process.exit(1);
  }
} else {
  process.stderr.write(
    "usage: leankohaku-colibri-bridge --listen <socket-path>\n" +
    "       leankohaku-colibri-bridge --rpc '<json-rpc-request>'\n",
  );
  process.exit(2);
}
