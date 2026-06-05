// Fallback parser for text-embedded tool calls.
//
// llama.cpp with `--jinja` normalises most chat-template-specific
// tool-call formats into the OpenAI-standard `tool_calls` array on
// `message`. When it doesn't (older builds, missing template, model
// idiosyncrasies), the calls land in `message.content` as text tags.
// Qwen models in particular emit either:
//
//   <tool_call>{"name": "allowance", "arguments": {...}}</tool_call>
//
// or the `name` may be `function` and the args called `parameters`.
// This parser handles both shapes.
//
// Returns `{ toolCalls, remainingContent }`:
//   - toolCalls: standardised array of { id, name, args } (synthesised
//     id so the downstream loop can match a tool result back to a call)
//   - remainingContent: the original string with `<tool_call>` blocks
//     removed, useful when the model interleaves final-answer text
//     between calls (rare but happens).

const TOOL_CALL_RE = /<tool_call>\s*([\s\S]*?)\s*<\/tool_call>/g;

let synthId = 1;

export function parseQwenToolCalls(content) {
  if (typeof content !== "string" || !content.includes("<tool_call>")) {
    return { toolCalls: [], remainingContent: content ?? "" };
  }
  const toolCalls = [];
  let remaining = content;
  let match;
  // Reset lastIndex so we can re-use the global regex safely.
  TOOL_CALL_RE.lastIndex = 0;
  while ((match = TOOL_CALL_RE.exec(content)) !== null) {
    const body = match[1];
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      // Unparseable block — skip but keep it out of remaining so the
      // model doesn't keep trying to call something we can't dispatch.
      remaining = remaining.replace(match[0], "");
      continue;
    }
    const name = parsed?.name ?? parsed?.function ?? null;
    const args = parsed?.arguments ?? parsed?.parameters ?? {};
    if (typeof name !== "string") {
      remaining = remaining.replace(match[0], "");
      continue;
    }
    toolCalls.push({
      id: `qwen_call_${synthId++}`,
      name,
      args: typeof args === "object" && args !== null ? args : {},
    });
    remaining = remaining.replace(match[0], "");
  }
  return { toolCalls, remainingContent: remaining.trim() };
}
