// Local OpenAI-compatible client for gpt-oss-120b on llama-server.
//
// Per Slice 6 of the leanAI plan: this client is one of TWO selectable
// backends (the other is Anthropic). The Lean daemon decides which to
// use based on LLM_BACKEND env + reachability of 127.0.0.1:8080.
//
// SECURITY GUARDRAILS (load-bearing, do not relax without review):
//
//  1. **Loopback-only URL allowlist.** LOCAL_LLM_BASE_URL must resolve
//     to 127.0.0.1 or ::1. Refuse anything else, even if it parses as a
//     URL. Mitigates a misconfiguration that leaks prompts to a remote
//     endpoint — the entire reason for going local-first.
//
//  2. **Sidecar returns RAW model JSON to Lean unchanged.** No
//     parsing, no schema-checking, no field translation here. The Lean
//     daemon's IntentParser.lean is the trust boundary; this client is
//     a thin transport. If we parsed here, we'd silently widen the
//     attack surface.
//
//  3. **No persistent state.** llama.cpp's /v1 endpoints are stateless.
//     We pass conversation history explicitly per call. Each invocation
//     is one-shot from the sidecar's perspective.
//
// Per the Vitalik "Secure LLMs" framing: this is the path that lets the
// LLM run *as if it were just another untrusted tool we happen to host
// locally*. Local-only ≠ trusted; we still treat output as adversarial.

import net from "node:net";
import dns from "node:dns/promises";

const DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1";
const DEFAULT_REASONING = "medium"; // low | medium | high — medium is the project default

/** Auto-detect the served model id when LOCAL_LLM_MODEL is unset.
 *  llama.cpp tags by HF repo ("ggml-org/gpt-oss-120b-GGUF"); other
 *  servers use shorter ids. Picking the first one the server
 *  advertises is the most robust default. Returns null if the model
 *  list is empty or the probe fails. */
async function detectModelId(baseUrl) {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 2_000);
    const r = await fetch(`${baseUrl}/models`, { signal: ctl.signal });
    clearTimeout(t);
    if (!r.ok) return null;
    const body = await r.json();
    const first = body?.data?.[0]?.id ?? body?.models?.[0]?.model;
    return typeof first === "string" ? first : null;
  } catch {
    return null;
  }
}

/** Throw unless the URL points at a loopback address. Defense in depth
 *  for misconfiguration: even if someone sets LOCAL_LLM_BASE_URL to
 *  https://api.openai.com, this guard refuses. */
async function assertLoopbackOnly(baseUrl) {
  let parsed;
  try {
    parsed = new URL(baseUrl);
  } catch (e) {
    throw new Error(`LOCAL_LLM_BASE_URL is not a valid URL: ${baseUrl}`);
  }
  const host = parsed.hostname;
  // Fast path: already an IP literal.
  if (net.isIP(host)) {
    if (host === "127.0.0.1" || host === "::1") return;
    throw new Error(
      `LOCAL_LLM_BASE_URL host ${host} is not loopback; refusing (set to 127.0.0.1 or ::1)`,
    );
  }
  // Resolve hostname and check every address it resolves to.
  let addrs;
  try {
    addrs = await dns.lookup(host, { all: true });
  } catch (e) {
    throw new Error(`LOCAL_LLM_BASE_URL host ${host} did not resolve: ${e.message}`);
  }
  for (const a of addrs) {
    if (a.address !== "127.0.0.1" && a.address !== "::1") {
      throw new Error(
        `LOCAL_LLM_BASE_URL host ${host} resolved to ${a.address} (not loopback); refusing`,
      );
    }
  }
}

/** Probe `/models` to see if the server is up. Used by the daemon to
 *  decide whether to spawn llama-server. Returns true/false; never
 *  throws (transport errors are treated as "not up"). */
export async function ping(baseUrl = process.env.LOCAL_LLM_BASE_URL ?? DEFAULT_BASE_URL) {
  try {
    await assertLoopbackOnly(baseUrl);
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 2_000);
    const r = await fetch(`${baseUrl}/models`, { signal: ctl.signal });
    clearTimeout(t);
    return r.ok;
  } catch {
    return false;
  }
}

/** Build the structured prompt: system + user with raw text and
 *  regex-seed JSON. Returns an OpenAI-compatible messages array.
 *  Crucially, every value we interpolate is JSON-stringified — no
 *  unescaped chain-derived strings ever land in the prompt body. */
function buildMessages({ prompt, seed, chainId, skillContext }) {
  // Field-by-field schema. The prompt is intentionally verbose: gpt-oss
  // is documented unreliable on Ethereum-specific factual details, so we
  // overspecify the wire shape and let the Lean validator hard-reject
  // anything off-spec.
  const system = [
    "You convert natural-language Ethereum transaction intents into structured JSON.",
    "You DO NOT compute calldata, signatures, RLP bytes, or v/r/s. You ONLY produce the structured intent.",
    "",
    "OUTPUT: exactly one JSON object matching one of these shapes. NO prose, NO code fences.",
    "",
    "Common: every shape has \"action\" (string tag) and \"chainId\" (integer).",
    "Amounts are INTEGERS in the smallest unit of the asset (wei for ETH, base units for tokens).",
    "Addresses are 0x-prefixed 42-character checksummed strings. NEVER invent addresses.",
    "",
    "nativeTransfer: {\"action\":\"nativeTransfer\",\"chainId\":<int>,\"to\":<addr>,\"amountWei\":<int>}",
    "  Example: \"send 0.01 ETH to 0xAbC...\" on sepolia →",
    "  {\"action\":\"nativeTransfer\",\"chainId\":11155111,\"to\":\"0xAbC...\",\"amountWei\":10000000000000000}",
    "",
    "erc20Transfer: {\"action\":\"erc20Transfer\",\"chainId\":<int>,\"token\":<addr>,\"decimals\":<int>,\"to\":<addr>,\"amount\":<int>}",
    "  amount is in base units (e.g. 100 USDC with 6 decimals = 100000000).",
    "",
    "erc20Approve: {\"action\":\"erc20Approve\",\"chainId\":<int>,\"token\":<addr>,\"spender\":<addr>,\"amount\":{\"exact\":<int>}|\"unlimited\"}",
    "",
    "rawCall: {\"action\":\"rawCall\",\"chainId\":<int>,\"to\":<addr>,\"valueWei\":<int>,\"data\":\"0x...\",\"rationale\":<string>}",
    "",
    "If the request is ambiguous, missing addresses, or you cannot fill every required field WITHOUT INVENTING,",
    "respond with {\"error\":\"<reason>\",\"ask\":\"<question for the user>\"}.",
    "",
    "DO NOT include any fields not listed above. DO NOT include v/r/s/signature/RLP — those are at the wrong layer.",
    "DO NOT name dead testnets (goerli/ropsten/rinkeby/kovan). The Lean validator will reject them anyway.",
  ].join("\n");
  // Append the skill body when present. The skill is treated as
  // additional authoritative instructions for this specific action
  // class. It overrides the generic system prompt where they conflict
  // (the skill is more specific).
  const fullSystem = skillContext
    ? system +
      "\n\n--- SKILL: " +
      (skillContext.name ?? "(unnamed)") +
      " ---\n" +
      "The following skill scopes the action class for this request. Follow its 'Intent shape' section EXACTLY.\n\n" +
      skillContext.body
    : system;
  const userMsg = {
    prompt,
    regex_seed: seed ?? null,
    chain_id: chainId,
  };
  return [
    { role: "system", content: fullSystem },
    { role: "user", content: JSON.stringify(userMsg) },
  ];
}

/** Call llama-server's chat-completions endpoint, return raw model
 *  text. Retries once on ECONNREFUSED to ride out a server restart. */
export async function parseIntent({ prompt, seed, chainId, skillContext }, opts = {}) {
  const baseUrl = opts.baseUrl ?? process.env.LOCAL_LLM_BASE_URL ?? DEFAULT_BASE_URL;
  await assertLoopbackOnly(baseUrl);
  // Resolution order: explicit opts → env override → first model the server advertises.
  let model = opts.model ?? process.env.LOCAL_LLM_MODEL;
  if (!model) {
    model = (await detectModelId(baseUrl)) ?? "gpt-oss-120b";
  }
  const reasoning = opts.reasoning ?? process.env.LOCAL_LLM_REASONING ?? DEFAULT_REASONING;

  const messages = buildMessages({ prompt, seed, chainId, skillContext });
  const body = {
    model,
    messages,
    reasoning_effort: reasoning,
    response_format: { type: "json_object" },
    // Bounded; intent JSON is small. Keeps a runaway model from eating
    // the context window.
    max_tokens: 1024,
    // No streaming for one-shot sidecar use.
    stream: false,
  };

  const attempt = async () => {
    const r = await fetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!r.ok) {
      const txt = await r.text().catch(() => "");
      throw new Error(`local LLM HTTP ${r.status}: ${txt.slice(0, 300)}`);
    }
    return r.json();
  };

  let resp;
  try {
    resp = await attempt();
  } catch (e) {
    if (e?.cause?.code === "ECONNREFUSED") {
      // server may be restarting; one retry after 500ms backoff
      await new Promise((res) => setTimeout(res, 500));
      resp = await attempt();
    } else {
      throw e;
    }
  }
  const raw = resp?.choices?.[0]?.message?.content;
  if (typeof raw !== "string") {
    throw new Error("local LLM returned no content");
  }
  return {
    raw,
    backend: "local-openai",
    model,
    reasoning_effort: reasoning,
  };
}
