#!/usr/bin/env node
// leankohaku-helios-bridge — JSON-RPC sidecar exposing @a16z/helios.
//
// Helios is a trustless Ethereum light client written in Rust, exposed
// here via its NAPI binding. It validates execution payloads against
// sync-committee proofs and executes `eth_call` / `eth_estimateGas`
// locally inside an embedded REVM. The point of this sidecar: simulate
// transactions against verified state without trusting an arbitrary RPC.
//
// Two modes (same shape as bridge/colibri/bridge.mjs):
//
//   --rpc '<json>'        one-shot: dispatch one request, write response,
//                         exit. Pays cold-start every time.
//
//   --listen <socket>     long-running: bind a Unix-domain socket, accept
//                         one peer, read newline-delimited JSON-RPC
//                         requests, write newline-delimited responses.
//                         Maintains one HeliosProvider per
//                         (chainId, executionRpc) tuple so the consensus
//                         bootstrap is paid once per chain per lifetime.
//
// Methods (both modes):
//   ping
//   eth.proxy   { chainId, executionRpc, method, params } -> raw RPC result
//   tx.simulate { chainId, executionRpc, from, to, value, data, block? }
//                 -> { gasUsed, returnValue, revertReason? }
//
// SECURITY: This process executes EVM locally with state validated by the
// consensus sync committee. The Lean side treats the output as UNTRUSTED
// for signing decisions — it is rendered as confirmation UI only; the
// transaction structure is always re-decoded in Lean before signing.
//
// Network kind mapping comes from the chainId field; we explicitly enumerate
// the kinds @a16z/helios supports rather than guess, so unsupported chains
// fail loudly instead of silently degrading to "mainnet".

import { createHeliosProvider } from "@a16z/helios";
import net from "node:net";
import fs from "node:fs";

const PROTOCOL_VERSION = "0.0.1";

// chainId -> Helios NetworkKind. @a16z/helios accepts these literals.
const CHAIN_TO_KIND = new Map([
  [1, "mainnet"],
  [11155111, "sepolia"],
  [17000, "holesky"],
]);

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

// Keyed by `${chainId}|${executionRpc}` so changing either provisions a
// fresh client. In --listen mode the map persists for the process lifetime.
const clients = new Map();

async function getClient(chainId, executionRpc) {
  const key = `${chainId}|${executionRpc}`;
  let entry = clients.get(key);
  if (entry) return entry;

  const kind = CHAIN_TO_KIND.get(chainId);
  if (!kind) {
    throw new Error(`helios: unsupported chainId=${chainId} (known: ${[...CHAIN_TO_KIND.keys()].join(", ")})`);
  }
  if (typeof executionRpc !== "string" || !executionRpc.length) {
    throw new Error("helios: executionRpc is required (a16z/helios needs an execution RPC for blob/log fallback)");
  }

  const config = { executionRpc };
  const provider = await createHeliosProvider(config, kind);
  // sync() blocks until the sync committee has caught up; cold-start is
  // typically a few seconds on mainnet, faster on sepolia/holesky.
  await provider.sync();
  entry = { provider, executionRpc, chainId };
  clients.set(key, entry);
  return entry;
}

// eth_getLogs is unsupported in the verified path — fall back to a raw
// fetch against the configured executionRpc. Mirrors upstream's
// `bypassGetLogs` helper in ethereum/kohaku.
async function logsBypass(executionRpc, params) {
  const body = {
    jsonrpc: "2.0",
    id: 1,
    method: "eth_getLogs",
    params,
  };
  const res = await fetch(executionRpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`helios bypass eth_getLogs http ${res.status}`);
  }
  const j = await res.json();
  if (j.error) {
    const e = new Error(j.error.message || "eth_getLogs failed");
    e.data = j.error;
    throw e;
  }
  return j.result;
}

async function dispatch(method, params, id) {
  switch (method) {
    case "ping":
      return ok(id, {
        ok: true,
        protocol: PROTOCOL_VERSION,
        warmChains: Array.from(clients.values()).map((c) => c.chainId),
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
      if (!CHAIN_TO_KIND.has(chainId)) {
        return err(id, -32602, `params.chainId=${chainId} unsupported (known: ${[...CHAIN_TO_KIND.keys()].join(", ")})`);
      }
      if (typeof params.executionRpc !== "string" || !params.executionRpc.length) {
        return err(id, -32602, "params.executionRpc must be a non-empty string");
      }
      const inner = Array.isArray(params.params) ? params.params : [];
      try {
        if (params.method === "eth_getLogs") {
          const result = await logsBypass(params.executionRpc, inner);
          return ok(id, result);
        }
        const { provider } = await getClient(chainId, params.executionRpc);
        const result = await provider.request({ method: params.method, params: inner });
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
      if (!CHAIN_TO_KIND.has(chainId)) {
        return err(id, -32602, `params.chainId=${chainId} unsupported (known: ${[...CHAIN_TO_KIND.keys()].join(", ")})`);
      }
      if (typeof params.executionRpc !== "string" || !params.executionRpc.length) {
        return err(id, -32602, "params.executionRpc must be a non-empty string");
      }
      if (typeof params.to !== "string" || !params.to.startsWith("0x")) {
        return err(id, -32602, "params.to must be a 0x-prefixed address");
      }
      const callObj = {
        from: params.from,
        to: params.to,
        value: params.value ?? "0x0",
        data: params.data ?? "0x",
      };
      for (const k of Object.keys(callObj)) {
        if (callObj[k] === undefined) delete callObj[k];
      }
      const block = params.block ?? "latest";
      try {
        const { provider } = await getClient(chainId, params.executionRpc);
        // eth_call returns the raw return data or throws with revert info.
        // Helios executes both via the embedded REVM against verified state.
        let returnValue = null;
        let revertReason = null;
        try {
          returnValue = await provider.request({
            method: "eth_call",
            params: [callObj, block],
          });
        } catch (e) {
          revertReason = e?.message ?? String(e);
        }
        let gasUsed = null;
        try {
          gasUsed = await provider.request({
            method: "eth_estimateGas",
            params: [callObj, block],
          });
        } catch (e) {
          // estimateGas reverts when the call reverts; record reason if we
          // didn't already capture one from eth_call above.
          if (revertReason == null) revertReason = e?.message ?? String(e);
        }
        return ok(id, { gasUsed, returnValue, revertReason });
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
  const socketPath = argv[listenIdx + 1];
  try {
    fs.unlinkSync(socketPath);
  } catch (e) {
    if (e?.code !== "ENOENT") {
      process.stderr.write(`[helios] could not remove stale socket ${socketPath}: ${e.message}\n`);
    }
  }

  const server = net.createServer((conn) => {
    let buf = "";
    conn.on("data", (chunk) => {
      buf += chunk.toString("utf8");
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
      process.stderr.write(`[helios] conn error: ${e?.message ?? e}\n`);
    });
  });

  server.on("error", (e) => {
    process.stderr.write(`[helios] server error: ${e?.message ?? e}\n`);
    process.exit(1);
  });

  server.listen(socketPath, () => {
    try {
      fs.chmodSync(socketPath, 0o600);
    } catch { /* best-effort */ }
    process.stderr.write(`[helios] listening on ${socketPath}\n`);
  });

  const shutdown = () => {
    try { server.close(); } catch {}
    for (const c of clients.values()) {
      try { c.provider.destroy?.(); } catch {}
    }
    try { fs.unlinkSync(socketPath); } catch {}
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
} else if (rpcIdx !== -1 && argv[rpcIdx + 1]) {
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
    for (const c of clients.values()) {
      try { c.provider.destroy?.(); } catch {}
    }
  } catch (e) {
    process.stdout.write(
      err(req?.id ?? null, -32603, `dispatch crash: ${e?.message ?? e}`),
    );
    process.stdout.write("\n");
    process.exit(1);
  }
} else {
  process.stderr.write(
    "usage: leankohaku-helios-bridge --listen <socket-path>\n" +
    "       leankohaku-helios-bridge --rpc '<json-rpc-request>'\n",
  );
  process.exit(2);
}
