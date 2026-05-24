// Local OpenAI-compatible client for any chat-completions server on
// the loopback interface (llama.cpp, vLLM, Ollama's /v1 surface, etc.).
// Historically targeted gpt-oss-120b; now model-agnostic — the served
// model id is auto-detected from /v1/models so swapping the backing
// model (e.g. Qwen3.5-35B-A3B) needs no code change.
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
import { toolSchemas, findTool } from "../tools/registry.mjs";
import { parseQwenToolCalls } from "../tools/qwenParser.mjs";

const DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1";

/** Hard cap on tool-call rounds. A 3.5B-class model is much more
 *  likely to over-call or loop on the same tool than a frontier model;
 *  the cap is the only thing preventing a runaway sidecar from holding
 *  the chat-completions endpoint open indefinitely. Tuned for the
 *  current 4-tool surface — bump if the surface grows. */
const MAX_TOOL_TURNS = 5;

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

/** Cap on the number of previous chat turns we replay into the model.
 *  Beyond this we drop the oldest. Each turn is one user or assistant
 *  message — six is roughly three round-trips, enough for the user to
 *  clarify a swap ("which router?" → "uniswap v3") without ballooning
 *  context. Tool messages from prior turns are NEVER replayed: each
 *  tool result is ephemeral per the current intent and the model would
 *  thrash if it saw stale balances / allowances in the transcript. */
const MAX_HISTORY_TURNS = 6;

/** Build the structured prompt: system + (optional history) + user
 *  with raw text and regex-seed JSON. Returns an OpenAI-compatible
 *  messages array. Crucially, every value we interpolate is
 *  JSON-stringified — no unescaped chain-derived strings ever land in
 *  the prompt body. History is treated as untrusted text (same trust
 *  model as the current prompt); the Lean IntentParser still hard-
 *  rejects whatever the model emits. */
function buildMessages({ prompt, seed, chainId, skillContext, chainContext, walletContext, history }) {
  // Field-by-field schema. The prompt is intentionally verbose: local
  // open-weight models are documented unreliable on Ethereum-specific
  // factual details (chain ids, dead-testnet names, RLP layouts, fee
  // fields, contract addresses), so we overspecify the wire shape and
  // let the Lean validator hard-reject anything off-spec. This isn't
  // model-specific defensiveness — it's the cost of putting any model
  // on the signing path.
  const system = [
    "You convert natural-language Ethereum transaction intents into structured JSON.",
    "You DO NOT compute calldata, signatures, RLP bytes, or v/r/s. You ONLY produce the structured intent.",
    "",
    "OUTPUT: exactly one JSON object matching one of these shapes. NO prose, NO code fences.",
    "",
    "Common: every shape has \"action\" (string tag) and \"chainId\" (integer).",
    "Amounts are INTEGERS in the smallest unit of the asset (wei for ETH, base units for tokens).",
    "**NEVER COMPUTE UNIT CONVERSION YOURSELF.** The seed contains `amountBase` — a string-form integer the daemon already computed via parseUnits(decimal, token.decimals). COPY IT VERBATIM into the Intent's amount field. Recomputing causes off-by-zeros bugs and is the worst-case failure mode for this system.",
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
  // Append the chain-context (known tokens) and skill body to the
  // system prompt. The chain-context block exists so the model can
  // resolve "USDC" → contract address without inventing it; the skill
  // body specifies the exact Intent shape for the current action.
  let fullSystem = system;
  if (walletContext) {
    const walletLines = (walletContext.wallets ?? [])
      .map((w) => `  ${w.name.padEnd(16)} ${w.address}`)
      .join("\n");
    const bookLines = (walletContext.addressBook ?? [])
      .map((e) => `  ${e.label.padEnd(16)} ${e.address}  [${e.source}]`)
      .join("\n");
    const defLine = walletContext.defaultWallet
      ? `Default wallet (use when the user says \"my wallet\" or omits the sender): ${walletContext.defaultWallet}\n`
      : "";
    fullSystem +=
      "\n\n--- WALLET CONTEXT ---\n" +
      defLine +
      "The user's local wallets (use the address when they refer to a wallet by name):\n" +
      (walletLines || "  (no wallets registered)") +
      "\n\nAddress book (use these labels as aliases for the address):\n" +
      (bookLines || "  (empty)");
  }
  if (chainContext) {
    const tokenLines = (chainContext.knownTokens ?? [])
      .map((t) => `  ${t.symbol.padEnd(8)} ${t.address}  decimals=${t.decimals}  (${t.name})`)
      .join("\n");
    fullSystem +=
      "\n\n--- CHAIN CONTEXT: chain " +
      chainContext.chainId +
      " ---\n" +
      "Known token contracts (use these — DO NOT invent addresses):\n" +
      (tokenLines || "  (none registered for this chain)");
  }
  if (skillContext) {
    fullSystem +=
      "\n\n--- SKILL: " +
      (skillContext.name ?? "(unnamed)") +
      " ---\n" +
      "The following skill scopes the action class for this request. Follow its 'Intent shape' section EXACTLY.\n\n" +
      skillContext.body;
  }
  const userMsg = {
    prompt,
    regex_seed: seed ?? null,
    chain_id: chainId,
  };
  // Normalise history: keep only user/assistant string-content turns
  // (no tool messages), cap to MAX_HISTORY_TURNS from the tail.
  const historyMsgs = Array.isArray(history)
    ? history
        .filter(
          (m) =>
            m &&
            (m.role === "user" || m.role === "assistant") &&
            typeof m.content === "string" &&
            m.content.length > 0,
        )
        .slice(-MAX_HISTORY_TURNS)
        .map((m) => ({ role: m.role, content: m.content }))
    : [];
  return [
    { role: "system", content: fullSystem },
    ...historyMsgs,
    { role: "user", content: JSON.stringify(userMsg) },
  ];
}

/** Call llama-server's chat-completions endpoint, return raw model
 *  text. Retries once on ECONNREFUSED to ride out a server restart.
 *
 *  When `tools` (non-empty array of registry entries) is provided,
 *  enters a bounded tool-call loop instead of a single-shot call. Each
 *  iteration: send messages+tools, dispatch any tool_calls (structured
 *  or qwen `<tool_call>` tags), append the results as `role: "tool"`
 *  messages, repeat until the model emits final JSON content or
 *  MAX_TOOL_TURNS is hit. */
export async function parseIntent({ prompt, seed, chainId, skillContext, chainContext, walletContext, tools, history }, opts = {}) {
  const baseUrl = opts.baseUrl ?? process.env.LOCAL_LLM_BASE_URL ?? DEFAULT_BASE_URL;
  await assertLoopbackOnly(baseUrl);
  // Resolution order: explicit opts → env override → first model the
  // server advertises. No hardcoded model-name fallback: if /v1/models
  // returns nothing usable we'd rather error loudly than silently
  // POST with a wrong id that a strict server (vLLM, future
  // llama.cpp) would 404 on.
  let model = opts.model ?? process.env.LOCAL_LLM_MODEL;
  if (!model) {
    model = await detectModelId(baseUrl);
    if (!model) {
      throw new Error(
        "could not determine local LLM model id: /v1/models returned no usable entry. " +
        "Set LOCAL_LLM_MODEL explicitly to override.",
      );
    }
  }
  // reasoning_effort is an OpenAI / gpt-oss extension. Only send it
  // when the caller explicitly opts in via env or opts — gating keeps
  // the wire request minimal for models that don't speak it (most
  // Qwen / Llama / Mistral builds) so we never have to rely on the
  // server silently dropping unknown fields.
  const reasoning = opts.reasoning ?? process.env.LOCAL_LLM_REASONING ?? null;

  const messages = buildMessages({ prompt, seed, chainId, skillContext, chainContext, walletContext, history });

  const baseBody = {
    model,
    // Bumped from 1024 — the skill body + chain context push the
    // prompt long, and some models put reasoning tokens in the
    // response too. Cap is still per-call so a runaway model can't
    // wedge the chat.
    max_tokens: 4096,
    stream: false,
  };
  if (reasoning) {
    baseBody.reasoning_effort = reasoning;
  }

  const callChat = async (body) => {
    const doFetch = async () => {
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
    try {
      return await doFetch();
    } catch (e) {
      if (e?.cause?.code === "ECONNREFUSED") {
        await new Promise((res) => setTimeout(res, 500));
        return await doFetch();
      }
      throw e;
    }
  };

  const extractContent = (resp) => {
    const choice = resp?.choices?.[0];
    const candidates = [
      choice?.message?.content,
      choice?.message?.reasoning_content,
      choice?.text,
    ];
    return candidates.find((s) => typeof s === "string" && s.trim().length > 0);
  };

  // Single-shot path — preserved verbatim for callers that don't pass
  // `tools`. This is still the default for the DirectSynth fallback
  // and for skills that don't benefit from chain probing.
  if (!Array.isArray(tools) || tools.length === 0) {
    const body = {
      ...baseBody,
      messages,
      response_format: { type: "json_object" },
    };
    const resp = await callChat(body);
    const raw = extractContent(resp);
    if (!raw) {
      const dump = JSON.stringify(resp ?? {}).slice(0, 400);
      throw new Error(`local LLM returned no usable content. response was: ${dump}`);
    }
    return { raw, backend: "local-openai", model, reasoning_effort: reasoning };
  }

  // Tool-call loop. Bounded by MAX_TOOL_TURNS so a model that loops on
  // the same tool can't hold the endpoint open. The trace is included
  // in the returned object so the daemon can surface it in errors
  // (useful when debugging "why did the model call X with these args?").
  const trace = [];
  let convo = messages.slice();
  const schemas = toolSchemas(tools);

  for (let turn = 0; turn < MAX_TOOL_TURNS; turn++) {
    const body = {
      ...baseBody,
      messages: convo,
      tools: schemas,
      tool_choice: "auto",
      // response_format omitted when tools are active: a model emitting
      // a tool_call must NOT also be forced to emit JSON-only content,
      // or it gets confused about whether the call goes in `content` or
      // `tool_calls`. The final-answer turn (no tool_calls) still
      // emits the Intent as JSON because the system prompt demands it.
    };
    const resp = await callChat(body);
    const choice = resp?.choices?.[0];
    const assistantMsg = choice?.message ?? {};
    const structuredCalls = Array.isArray(assistantMsg.tool_calls)
      ? assistantMsg.tool_calls
      : [];
    const contentStr = extractContent(resp) ?? "";
    const { toolCalls: qwenCalls, remainingContent } = parseQwenToolCalls(contentStr);

    // Prefer structured tool_calls (what llama.cpp emits with --jinja
    // + a model whose template supports tool use). Fall through to the
    // Qwen text-tag parser when structured is empty.
    const calls =
      structuredCalls.length > 0
        ? structuredCalls.map((c) => ({
            id: c.id,
            name: c?.function?.name ?? "",
            args: (() => {
              try {
                return JSON.parse(c?.function?.arguments ?? "{}");
              } catch {
                return {};
              }
            })(),
          }))
        : qwenCalls;

    if (calls.length === 0) {
      // No tool calls → the model is emitting the final Intent JSON.
      const final = (contentStr && contentStr.trim()) || remainingContent;
      if (!final) {
        const dump = JSON.stringify(resp ?? {}).slice(0, 400);
        throw new Error(`local LLM returned no usable content on final turn. response was: ${dump}`);
      }
      return {
        raw: final,
        backend: "local-openai",
        model,
        reasoning_effort: reasoning,
        toolTurns: turn,
        toolTrace: trace,
      };
    }

    // Echo the assistant turn back into the conversation so the model
    // sees its own tool_calls in context (required by the OpenAI spec —
    // we cannot just send a `role: "tool"` reply without the matching
    // assistant turn). Some llama.cpp builds return the raw structured
    // form; we round-trip whatever the server gave us.
    convo.push({
      role: "assistant",
      content: assistantMsg.content ?? "",
      ...(structuredCalls.length > 0 ? { tool_calls: structuredCalls } : {}),
    });

    // Dispatch each tool call, appending one role:"tool" message per.
    let sawRepeat = false;
    for (const call of calls) {
      const sig = `${call.name}:${JSON.stringify(call.args)}`;
      if (trace.some((t) => t.sig === sig)) {
        // Same tool + same args as a prior turn — the model is thrashing.
        // Surface this as a tool result so it can react, but mark the
        // loop for early exit if it happens twice in a row.
        sawRepeat = true;
      }
      const def = findTool(tools, call.name);
      let result;
      if (!def) {
        result = { ok: false, error: `unknown tool: ${call.name}` };
      } else {
        try {
          result = await def.impl(call.args ?? {});
        } catch (e) {
          result = { ok: false, error: e?.message ?? String(e) };
        }
      }
      trace.push({ sig, name: call.name, args: call.args, result });
      // role:"tool" message. The OpenAI spec requires `tool_call_id`
      // matching the assistant turn's id; we synthesise one for the
      // qwen path so the format stays consistent.
      convo.push({
        role: "tool",
        tool_call_id: call.id ?? `synth_${trace.length}`,
        name: call.name,
        content: JSON.stringify({
          result,
          summary: def?.summary?.(call.args ?? {}, result) ?? null,
        }),
      });
    }

    // Anti-thrash: if we saw the same tool+args twice in a row, nudge
    // the model toward a final answer.
    if (sawRepeat) {
      convo.push({
        role: "system",
        content:
          "You called the same tool with identical arguments twice. " +
          "You have enough information; emit the final Intent JSON now.",
      });
    }
  }

  // Loop budget exhausted without a final-answer turn. Per the design
  // doc, we surface this as a structured error so the user knows the
  // LLM was thrashing — never silently sign.
  throw new Error(
    `local LLM exceeded ${MAX_TOOL_TURNS} tool-call rounds without emitting a final Intent. ` +
      `Last ${trace.length} tool calls in trace.`,
  );
}
