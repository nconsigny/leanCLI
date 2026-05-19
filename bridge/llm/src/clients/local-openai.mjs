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
const DEFAULT_MODEL = "gpt-oss-120b";
const DEFAULT_REASONING = "medium"; // low | medium | high — medium is the project default

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
function buildMessages({ prompt, seed, chainId }) {
  const system =
    "You convert natural-language Ethereum transaction intents into structured JSON. " +
    "You DO NOT compute calldata, signatures, or hex bytes. " +
    "Output schema: " +
    `{"action":"nativeTransfer"|"erc20Transfer"|"erc20Approve"|"uniswapV3SwapSingle"|"aaveV3Supply"|"aaveV3Withdraw"|"rawCall",` +
    `"chainId":<int>,...action-specific fields...}` +
    " If unsure, return {\"error\":\"...\",\"ask\":\"...\"}. " +
    "Do NOT invent contract addresses; if a token symbol can't be resolved, ask the user.";
  const userMsg = {
    prompt,
    regex_seed: seed ?? null,
    chain_id: chainId,
  };
  return [
    { role: "system", content: system },
    { role: "user", content: JSON.stringify(userMsg) },
  ];
}

/** Call llama-server's chat-completions endpoint, return raw model
 *  text. Retries once on ECONNREFUSED to ride out a server restart. */
export async function parseIntent({ prompt, seed, chainId }, opts = {}) {
  const baseUrl = opts.baseUrl ?? process.env.LOCAL_LLM_BASE_URL ?? DEFAULT_BASE_URL;
  const model = opts.model ?? process.env.LOCAL_LLM_MODEL ?? DEFAULT_MODEL;
  const reasoning = opts.reasoning ?? process.env.LOCAL_LLM_REASONING ?? DEFAULT_REASONING;
  await assertLoopbackOnly(baseUrl);

  const messages = buildMessages({ prompt, seed, chainId });
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
