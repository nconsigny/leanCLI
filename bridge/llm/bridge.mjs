#!/usr/bin/env node
// leankohaku-llm-bridge — untrusted JSON-RPC sidecar that turns natural-
// language intents into transaction-draft candidates. Mirrors the one-shot
// stdio pattern from bridge/clearsign/.
//
// Trust model: this process is treated as malicious. The Lean daemon never
// signs based on its output directly — every emitted draft flows through
// decode + simulate + user-confirm.

import { draftFromIntent, validateDraft } from "./src/draft.mjs";
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
        backend: "rule-based-v0",
        // Legacy fields (kept for compatibility with the old draftFromIntent
        // flow). The new path is llm.parseIntent, which selects between
        // local-openai and anthropic per LLM_BACKEND.
        modelConfigured: Boolean(process.env.ANTHROPIC_API_KEY),
        modelId: process.env.ANTHROPIC_API_KEY ? "claude-opus-4-7" : null,
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
        });
        return ok(id, result);
      } catch (e) {
        return err(id, -32603, `parseIntent failed: ${e?.message ?? e}`);
      }
    }

    case "tx.draftFromIntent": {
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
        const result = await draftFromIntent(params);
        // Defensive validation — the daemon also re-decodes, but cheap to
        // catch malformed drafts here.
        result.candidates = (result.candidates ?? []).map((c) => {
          if (c.confidence === "rejected") return c;
          return validateDraft(c)
            ? c
            : { ...c, confidence: "rejected", rationale: `${c.rationale ?? ""} [draft failed validation]` };
        });
        return ok(id, result);
      } catch (e) {
        return err(id, -32603, `draft failed: ${e?.message ?? e}`, {
          stack: String(e?.stack ?? ""),
        });
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
    "usage: leankohaku-llm-bridge --rpc '<json-rpc-request>'\n",
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
