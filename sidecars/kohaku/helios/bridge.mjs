#!/usr/bin/env node
// leancli-helios-bridge — JSON-RPC sidecar exposing @a16z/helios.
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

// chainId -> { network, kind } per @a16z/helios v0.11.x. `kind` is the
// family the second arg to createHeliosProvider takes; `network` is the
// specific chain literal that goes into the config. Defaults pick a
// public lightclientdata.org consensus endpoint where one is well-known;
// callers can override per-request via params.consensusRpc.
// Default beacon endpoints match upstream helios @ 0.11.1 (see helios
// issue #710: lightclientdata.org died, a16z migrated everything to
// operationsolarstorm.org). Per-chain notes:
//
//  - mainnet: operationsolarstorm.org's light-client API is the only
//    public one verified to be helios-compatible (publicnode + Ankr
//    Premium both return /light_client/updates payloads that helios
//    rejects with `InvalidPeriod`). Helios's baked-in default checkpoint
//    is still served here, so no auto-fetch is needed and we explicitly
//    do NOT pass one (a freshly-finalized root can sit mid-period and
//    force the first update to skip, which itself triggers InvalidPeriod).
//
//  - sepolia: OSS does not host Sepolia. publicnode's Sepolia beacon is
//    reachable but serves light_client/updates helios 0.11.1 CANNOT parse
//    (`.sync_data.update: Invalid selector for union` → "invalid sync
//    committee period"). The working public Sepolia light-client beacon is
//    Nimbus's, per a16z/helios#555 (maintainer's own recommendation,
//    verified end-to-end: eth_getBalance returned the correct verified wei).
//    NOTE http:// — its TLS cert does not match the hostname, so https
//    fails the handshake. Helios's baked-in Sepolia checkpoint has been
//    pruned by public beacons, so autoCheckpoint=true fetches a fresh
//    finalized root from this consensusRpc before client init.
const CHAIN_TO_NET = new Map([
  [1,        { network: "mainnet", kind: "ethereum", defaultConsensusRpc: "https://ethereum.operationsolarstorm.org",        autoCheckpoint: false }],
  [11155111, { network: "sepolia", kind: "ethereum", defaultConsensusRpc: "http://unstable.sepolia.beacon-api.nimbus.team", autoCheckpoint: true  }],
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

// Keyed by `${chainId}|${executionRpc}|${consensusRpc}` so changing any
// of them provisions a fresh client. In --listen mode the map persists
// for the process lifetime.
const clients = new Map();

// Fetch the current finalized block root from a beacon RPC and use it as
// helios's checkpoint. Without this, helios falls back to the checkpoint
// it was published with (months stale), which crashes sync with
// "invalid sync committee period" once a few periods have rolled over.
// The endpoint shape is the canonical Beacon API: GET /eth/v1/beacon/headers/finalized
// → { data: { root: "0x...", header: { ... } } }.
async function fetchFinalizedCheckpoint(consensusRpc) {
  const base = consensusRpc.replace(/\/+$/, "");
  const url = `${base}/eth/v1/beacon/headers/finalized`;
  const res = await fetch(url, { headers: { accept: "application/json" } });
  if (!res.ok) {
    throw new Error(`checkpoint fetch failed: HTTP ${res.status} on ${url}`);
  }
  const j = await res.json();
  const root = j?.data?.root;
  if (typeof root !== "string" || !root.startsWith("0x")) {
    throw new Error(`checkpoint fetch: unexpected response shape from ${url}`);
  }
  return root;
}

async function getClient(chainId, executionRpc, consensusRpcOverride, checkpointOverride) {
  const meta = CHAIN_TO_NET.get(chainId);
  if (!meta) {
    throw new Error(`helios: unsupported chainId=${chainId} (known: ${[...CHAIN_TO_NET.keys()].join(", ")})`);
  }
  if (typeof executionRpc !== "string" || !executionRpc.length) {
    throw new Error("helios: executionRpc is required");
  }
  const consensusRpc = consensusRpcOverride ?? meta.defaultConsensusRpc;
  if (!consensusRpc) {
    throw new Error(`helios: consensusRpc is required for chainId=${chainId} (no built-in default; pass params.consensusRpc)`);
  }

  const key = `${chainId}|${executionRpc}|${consensusRpc}`;
  let entry = clients.get(key);
  if (entry) return entry;

  // Checkpoint policy:
  //  - Caller-supplied wins.
  //  - Otherwise, use the chain's autoCheckpoint flag: true means fetch
  //    the current finalized root from the consensus RPC (required when
  //    helios's baked-in checkpoint has been pruned by the beacon, which
  //    is what happens on Sepolia). false leaves it unset so helios
  //    falls back to its release-time default — preferred for mainnet,
  //    where the default is still served and a fresh finalized root can
  //    race the chain advancing into the next sync-committee period
  //    between bootstrap and the first update.
  const checkpoint = checkpointOverride
    ?? (meta.autoCheckpoint ? await fetchFinalizedCheckpoint(consensusRpc) : undefined);

  // dbType: "config" — the default "localstorage" only works in browsers
  // and throws under Node. "config" tells helios to persist checkpoints
  // through the in-process config object (and the helios cache dir on
  // disk that the daemon confines via cwd in Helios.Persistent).
  const config = {
    executionRpc,
    consensusRpc,
    network: meta.network,
    dbType: "config",
  };
  if (checkpoint) config.checkpoint = checkpoint;
  const provider = await createHeliosProvider(config, meta.kind);
  // waitSynced() blocks until the sync committee has caught up; cold-start
  // is typically a few seconds.
  await provider.waitSynced();
  entry = { provider, executionRpc, consensusRpc, chainId, checkpoint };
  clients.set(key, entry);
  return entry;
}

// Helios verifies eth_getLogs only within ~8191 blocks of head (one sync
// committee period); deeper / unbounded ranges (indexer sync, deep history)
// have no verified path. So we TIER: in-window queries go through the
// verified helios client; everything else (or any failure) degrades to a
// raw bypass against the configured executionRpc. This narrows — rather than
// blanket-removes — upstream's `bypassGetLogs` (ethereum/kohaku), so recent
// history / approvals / prior-interactions become consensus-verified while
// deep scans stay functional. DIVERGENCE from upstream documented here.
const HELIOS_LOG_WINDOW = 8191;

// Decide whether a getLogs filter is verifiable by helios, and serve it via
// the verified client when so. Falls back to logsBypass on out-of-window
// ranges or any verified-path error. Returns the logs array either way
// (callers see the same shape; whether it was verified is the daemon's call
// to surface — it knows the range it asked for).
async function getLogsTiered(provider, executionRpc, filter) {
  let head = null;
  try {
    head = parseInt(await provider.request({ method: "eth_blockNumber", params: [] }), 16);
  } catch {
    head = null;
  }
  const norm = (b) => {
    if (b == null || b === "latest" || b === "pending") return head;
    if (b === "earliest") return 0;
    if (typeof b === "string") return parseInt(b, 16);
    if (typeof b === "number") return b;
    return null;
  };
  const from = norm(filter?.fromBlock);
  const to = norm(filter?.toBlock);
  const inWindow =
    head != null && from != null && to != null && from <= to && head - from <= HELIOS_LOG_WINDOW;
  if (inWindow) {
    try {
      return await provider.request({ method: "eth_getLogs", params: [filter] });
    } catch {
      // helios couldn't serve it verified (older client / unsupported) —
      // degrade to the raw bypass rather than fail the read.
    }
  }
  return await logsBypass(executionRpc, [filter]);
}

// Raw, UNVERIFIED eth_getLogs against the configured executionRpc — the
// fallback for out-of-window ranges (see getLogsTiered).
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
      if (!CHAIN_TO_NET.has(chainId)) {
        return err(id, -32602, `params.chainId=${chainId} unsupported (known: ${[...CHAIN_TO_NET.keys()].join(", ")})`);
      }
      if (typeof params.executionRpc !== "string" || !params.executionRpc.length) {
        return err(id, -32602, "params.executionRpc must be a non-empty string");
      }
      const inner = Array.isArray(params.params) ? params.params : [];
      try {
        const { provider } = await getClient(chainId, params.executionRpc, params.consensusRpc, params.checkpoint);
        if (params.method === "eth_getLogs") {
          const result = await getLogsTiered(provider, params.executionRpc, inner[0] ?? {});
          return ok(id, result);
        }
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
      if (!CHAIN_TO_NET.has(chainId)) {
        return err(id, -32602, `params.chainId=${chainId} unsupported (known: ${[...CHAIN_TO_NET.keys()].join(", ")})`);
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
        const { provider } = await getClient(chainId, params.executionRpc, params.consensusRpc, params.checkpoint);
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
        // The block this simulation was verified against. For "latest"
        // we ask helios for its consensus-verified head so the daemon can
        // report an honest height (block height proven against), not just
        // the literal "latest" the caller passed.
        let provenAtBlock = null;
        try {
          provenAtBlock =
            block === "latest" || block === "pending"
              ? await provider.request({ method: "eth_blockNumber", params: [] })
              : block;
        } catch {
          // best-effort; the daemon still reports verifiedBy=helios without
          // a height if the head lookup fails.
        }
        return ok(id, { gasUsed, returnValue, revertReason, provenAtBlock });
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
      try { c.provider.shutdown?.(); } catch {}
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
      try { c.provider.shutdown?.(); } catch {}
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
    "usage: leancli-helios-bridge --listen <socket-path>\n" +
    "       leancli-helios-bridge --rpc '<json-rpc-request>'\n",
  );
  process.exit(2);
}
