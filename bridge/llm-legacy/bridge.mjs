#!/usr/bin/env node
// leancli-llm-bridge — untrusted JSON-RPC sidecar. Thin transport:
// dispatches llm.parseIntent to the selected backend (local llama-server
// or Anthropic SDK) and returns the raw model output unchanged. The
// Lean daemon's IntentParser does the trust-boundary validation.
//
// Trust model: this process is treated as malicious. The Lean daemon
// never signs based on its output directly — every emitted intent flows
// through Lean's IntentParser hard-rejects, tx.encodeIntent's
// deterministic encoder, tx.simulate, and the TUI ConfirmGate.

import { parseIntent as parseIntentBackend } from "./src/parseIntent.mjs";

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

async function dispatch(method, params, id) {
  switch (method) {
    case "ping":
      return ok(id, { ok: true, protocol: PROTOCOL_VERSION });

    case "version":
      return ok(id, {
        protocol: PROTOCOL_VERSION,
        parseIntent: {
          selector: (process.env.LLM_BACKEND ?? "auto").toLowerCase(),
          localBaseUrl: process.env.LOCAL_LLM_BASE_URL ?? "http://127.0.0.1:8080/v1",
          anthropicConfigured: Boolean(process.env.ANTHROPIC_API_KEY),
        },
      });

    case "llm.parseIntent": {
      // Thin transport: ask the selected backend for a JSON intent,
      // return its raw output to the Lean daemon unchanged. NO parsing
      // here — IntentParser.lean is the trust boundary. Params:
      //   { prompt: string, seed?: <RegexDraft JSON>, chainId: number }
      if (!params || typeof params !== "object") {
        return err(id, -32602, "params must be an object");
      }
      if (typeof params.prompt !== "string") {
        return err(id, -32602, "params.prompt (string) required");
      }
      if (typeof params.chainId !== "number") {
        return err(id, -32602, "params.chainId (number) required");
      }
      try {
        const result = await parseIntentBackend({
          prompt: params.prompt,
          seed: params.seed ?? null,
          chainId: params.chainId,
          skillContext: params.skillContext ?? null,
          chainContext: params.chainContext ?? null,
          walletContext: params.walletContext ?? null,
        });
        return ok(id, result);
      } catch (e) {
        return err(id, -32603, `parseIntent failed: ${e?.message ?? e}`);
      }
    }

    default:
      return err(id, -32601, `method not found: ${method}`);
  }
}

const argv = process.argv.slice(2);
const rpcIdx = argv.indexOf("--rpc");
if (rpcIdx === -1 || !argv[rpcIdx + 1]) {
  process.stderr.write(
    "usage: leancli-llm-bridge --rpc '<json-rpc-request>'\n",
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

const out = await dispatch(req?.method, req?.params, req?.id);
process.stdout.write(out);
process.stdout.write("\n");
