// Backend selector for the parseIntent RPC.
//
// LLM_BACKEND env:
//   local     — always use the local llama-server (refuse if unreachable)
//   anthropic — always use the Anthropic SDK (refuse if no API key)
//   auto      — (default) try local first; fall back to anthropic if
//               local is unreachable AND ANTHROPIC_API_KEY is set;
//               otherwise return a structured "no backend" error so
//               the Lean daemon can surface it to the user verbatim.

import * as localOpenAI from "./clients/local-openai.mjs";
import * as anthropic from "./clients/anthropic.mjs";

function modeFromEnv() {
  const m = (process.env.LLM_BACKEND ?? "auto").toLowerCase();
  if (m === "local" || m === "anthropic") return m;
  return "auto";
}

/** Try local first when allowed; fall through to Anthropic if the local
 *  server isn't responding and Anthropic is configured. Returns the
 *  raw model output unchanged for the Lean daemon to parse. */
export async function parseIntent(params) {
  const mode = modeFromEnv();
  const localReachable = await localOpenAI.ping().catch(() => false);

  if (mode === "local") {
    if (!localReachable) {
      throw new Error(
        "LLM_BACKEND=local but llama-server is not reachable at the configured base URL",
      );
    }
    return localOpenAI.parseIntent(params);
  }

  if (mode === "anthropic") {
    return anthropic.parseIntent(params);
  }

  // auto: prefer local
  if (localReachable) {
    return localOpenAI.parseIntent(params);
  }
  if (process.env.ANTHROPIC_API_KEY) {
    return anthropic.parseIntent(params);
  }
  throw new Error(
    "no LLM backend available: local llama-server unreachable AND ANTHROPIC_API_KEY unset",
  );
}
