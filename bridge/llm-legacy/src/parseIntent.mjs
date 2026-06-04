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
import { selectTools } from "./tools/registry.mjs";

function modeFromEnv() {
  const m = (process.env.LLM_BACKEND ?? "auto").toLowerCase();
  if (m === "local" || m === "anthropic") return m;
  return "auto";
}

/** Extract the list of tool names a skill declares it may call.
 *  Format (in the skill body):
 *
 *    ## Tools available
 *
 *    - `allowance` — short description
 *    - `balanceOf` — ...
 *
 *  Only the FIRST backticked identifier on a bullet line is lifted —
 *  anything later in the bullet (e.g. "don't confuse this with `foo`")
 *  is treated as descriptive prose and ignored. Following paragraphs
 *  are skipped entirely so "Don't call `balanceOf` here" cannot
 *  accidentally enable balanceOf. Returns an empty array when the
 *  section is missing — that's the signal this skill stays one-shot. */
function extractToolNames(skillBody) {
  if (typeof skillBody !== "string" || skillBody.length === 0) return [];
  const lines = skillBody.split("\n");
  let inSection = false;
  const names = [];
  for (const line of lines) {
    if (/^##\s+Tools available\b/i.test(line)) {
      inSection = true;
      continue;
    }
    if (inSection && /^##\s+/.test(line)) {
      break; // next heading ends the section
    }
    if (!inSection) continue;
    // Bullet line: `- \`name\` — description`. The first backticked
    // identifier wins; later ones (cross-references, anti-examples)
    // are ignored.
    const bullet = line.match(/^\s*[-*]\s+`([A-Za-z_][A-Za-z0-9_]*)`/);
    if (bullet) {
      if (!names.includes(bullet[1])) names.push(bullet[1]);
    }
  }
  return names;
}

/** Build the resolved tool list for a request. Honors a per-call
 *  override (env: LEANCLI_LLM_TOOLS=allowance,simulateTx) so it's easy
 *  to A/B without editing skill markdown. */
function resolveTools(params) {
  const override = (process.env.LEANCLI_LLM_TOOLS ?? "").trim();
  if (override) {
    return selectTools(override.split(",").map((s) => s.trim()).filter(Boolean));
  }
  const skillBody = params?.skillContext?.body ?? "";
  return selectTools(extractToolNames(skillBody));
}

/** Try local first when allowed; fall through to Anthropic if the local
 *  server isn't responding and Anthropic is configured. Returns the
 *  raw model output unchanged for the Lean daemon to parse. */
export async function parseIntent(params) {
  const mode = modeFromEnv();
  const localReachable = await localOpenAI.ping().catch(() => false);
  const tools = resolveTools(params);
  const enriched = { ...params, tools };

  if (mode === "local") {
    if (!localReachable) {
      throw new Error(
        "LLM_BACKEND=local but llama-server is not reachable at the configured base URL",
      );
    }
    return localOpenAI.parseIntent(enriched);
  }

  if (mode === "anthropic") {
    // Anthropic backend stays one-shot for now; agentic tool use is a
    // separate slice that needs the native /v1/messages tool_use shape.
    return anthropic.parseIntent(params);
  }

  // auto: prefer local
  if (localReachable) {
    return localOpenAI.parseIntent(enriched);
  }
  if (process.env.ANTHROPIC_API_KEY) {
    return anthropic.parseIntent(params);
  }
  throw new Error(
    "no LLM backend available: local llama-server unreachable AND ANTHROPIC_API_KEY unset",
  );
}
