// Anthropic-backed parseIntent client.
//
// Counterpart to clients/local-openai.mjs. Selected by the daemon when
// LLM_BACKEND=anthropic or when the local server is unreachable AND
// ANTHROPIC_API_KEY is set.
//
// SECURITY NOTES (same trust model as local backend):
//
//  1. Sidecar passes raw model output to Lean unchanged. No parsing,
//     no schema-check — IntentParser.lean is the trust boundary.
//  2. No filesystem writes; one-shot API call per invocation.
//  3. Receives Anthropic API key via env only; never logs the key.
//
// This is intentionally a **separate** module from the legacy
// anthropic-agent.mjs (which does the tool-loop + viem encoding).
// Slice 9 retires anthropic-agent.mjs; this thin client replaces it
// for the parseIntent path.

import Anthropic from "@anthropic-ai/sdk";

const DEFAULT_MODEL = "claude-opus-4-7";

const SYSTEM_PROMPT =
  "You convert natural-language Ethereum transaction intents into " +
  "structured JSON. You DO NOT compute calldata, signatures, or hex " +
  "bytes. Output schema: " +
  `{"action":"nativeTransfer"|"erc20Transfer"|"erc20Approve"|"uniswapV3SwapSingle"|"aaveV3Supply"|"aaveV3Withdraw"|"rawCall",` +
  `"chainId":<int>,...action-specific fields...}` +
  ' If unsure, return {"error":"...","ask":"..."}. ' +
  "Do NOT invent contract addresses; if a token symbol can't be " +
  "resolved, ask the user. Output ONLY the JSON object, nothing else.";

export async function parseIntent({ prompt, seed, chainId, skillContext, chainContext }, opts = {}) {
  const apiKey = opts.apiKey ?? process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY not set");
  }
  const model = opts.model ?? process.env.ANTHROPIC_MODEL ?? DEFAULT_MODEL;
  const client = new Anthropic({ apiKey });

  const userPayload = JSON.stringify({
    prompt,
    regex_seed: seed ?? null,
    chain_id: chainId,
  });

  let fullSystem = SYSTEM_PROMPT;
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
  const resp = await client.messages.create({
    model,
    max_tokens: 1024,
    system: fullSystem,
    messages: [{ role: "user", content: userPayload }],
  });

  // Concatenate any text-block content; Anthropic returns an array.
  const raw =
    (resp?.content ?? [])
      .filter((b) => b?.type === "text")
      .map((b) => b.text)
      .join("") || "";
  if (!raw) {
    throw new Error("Anthropic returned no text content");
  }
  return {
    raw,
    backend: "anthropic",
    model,
  };
}
