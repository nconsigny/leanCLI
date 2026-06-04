#!/usr/bin/env node
// leancli-clearsign-bridge — untrusted JSON-RPC sidecar that decodes
// calldata and EIP-712 messages against ERC-7730 descriptors. Mirrors the
// stdio one-shot pattern from bridge/bridge.mjs (LeanCli/Privacy/Bridge.lean).
//
// SECURITY: This process is trusted to render human-readable intents but
// UNTRUSTED for signing decisions. The Lean side never signs based on the
// rendered fields alone — it only uses them as confirmation UI; the
// transaction structure is re-decoded in Lean before signing.

import { loadRegistry } from "./src/registry.mjs";
import { decodeTxIntent } from "./src/decoder.mjs";
import { decodeEip712Intent } from "./src/eip712.mjs";

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

// Boot once: parse every JSON in registry/ into an in-memory index.
let REGISTRY;
try {
  REGISTRY = loadRegistry();
} catch (e) {
  process.stderr.write(`[clearsign] failed to load registry: ${e?.stack ?? e}\n`);
  REGISTRY = { byDeployment: new Map(), bySelector: new Map() };
}

function dispatch(method, params, id) {
  switch (method) {
    case "ping":
      return ok(id, {
        ok: true,
        protocol: PROTOCOL_VERSION,
        descriptors: {
          deployments: REGISTRY.byDeployment.size,
          selectors: REGISTRY.bySelector.size,
        },
      });

    case "version":
      return ok(id, { protocol: PROTOCOL_VERSION });

    case "tx.decodeIntent": {
      if (!params || typeof params !== "object") {
        return err(id, -32602, "params must be an object");
      }
      if (typeof params.data !== "string" || !params.data.startsWith("0x")) {
        return err(id, -32602, "params.data must be a 0x-prefixed hex string");
      }
      try {
        const result = decodeTxIntent(params, REGISTRY);
        return ok(id, result);
      } catch (e) {
        return err(id, -32603, `decode failed: ${e?.message ?? e}`, {
          stack: String(e?.stack ?? ""),
        });
      }
    }

    case "eip712.decodeIntent": {
      if (!params || typeof params !== "object") {
        return err(id, -32602, "params must be an object");
      }
      if (typeof params.primaryType !== "string" || typeof params.types !== "object") {
        return err(id, -32602, "params.primaryType (string) and params.types (object) required");
      }
      if (!params.domain || typeof params.domain !== "object") {
        return err(id, -32602, "params.domain (object) required");
      }
      try {
        const result = decodeEip712Intent(params, REGISTRY);
        return ok(id, result);
      } catch (e) {
        return err(id, -32603, `eip712 decode failed: ${e?.message ?? e}`, {
          stack: String(e?.stack ?? ""),
        });
      }
    }

    default:
      return err(id, -32601, `method not found: ${method}`);
  }
}

// One-shot mode: --rpc <json> on argv. Mirrors bridge/bridge.mjs.
const argv = process.argv.slice(2);
const rpcIdx = argv.indexOf("--rpc");
if (rpcIdx === -1 || !argv[rpcIdx + 1]) {
  process.stderr.write(
    "usage: leancli-clearsign-bridge --rpc '<json-rpc-request>'\n",
  );
  process.exit(2);
}

let req;
try {
  req = JSON.parse(argv[rpcIdx + 1]);
} catch (e) {
  process.stdout.write(err(null, -32700, `parse error: ${e?.message ?? e}`));
  process.stdout.write("\n");
  process.exit(0);
}

const out = dispatch(req?.method, req?.params, req?.id);
process.stdout.write(out);
process.stdout.write("\n");
