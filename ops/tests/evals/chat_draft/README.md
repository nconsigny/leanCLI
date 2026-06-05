# `chat.draft` eval corpus

Prompt-level test cases for the wallet daemon's `chat.draft` RPC. Each
JSON file is one case; the runner reads the prompt + chainId, calls
`chat.draft`, and scores the response shape against `expect`.

Two sub-corpora:

* `regex/` — prompts that SHOULD be served by the deterministic pipeline
  (RuleParser → ENS/wallet/book resolution → DirectSynth or
  regex-clarification). The LLM must not fire. Expected `backend` is one
  of `wallet-direct` or `regex-clarification`.
* `llm/` — prompts that fall through to the LLM agent. Expected
  `backend` is one of `lean-agent` or `agent-propose-send`. Scoring is
  necessarily softer (the model is allowed to pick different tools as
  long as the encoded outcome is correct).

## Case shape

```json
{
  "name":    "send-eth-explicit-address-sepolia",
  "prompt":  "send 0.01 ETH to 0xabc...",
  "chainId": 11155111,
  "expect": {
    "backend": "wallet-direct",
    "intent":  "nativeTransfer",
    "encoded": {
      "to":      "0xabc...",
      "value":   10000000000000000,
      "dataPrefix": "0x"
    },
    "maxToolCalls": 0
  }
}
```

Field reference (every field under `expect` is optional unless flagged):

| Field | Type | Notes |
|---|---|---|
| `backend` (req.) | string | One of `wallet-direct`, `regex-clarification`, `lean-agent`, `agent-propose-send`. The runner asserts exact match. |
| `intent` | string | Compared against `regex.action` for `wallet-direct`, or against the encoded intent tag for LLM paths. |
| `encoded.to` | hex string | Lowercase 0x-prefixed address. Compared lowercase-insensitive. |
| `encoded.value` | number | Wei amount, decimal. Compared exactly. |
| `encoded.dataPrefix` | string | `data` field must start with this. Useful for selector matching (`0xa9059cbb` = `transfer(address,uint256)`). |
| `maxToolCalls` | int | Upper bound on `tool_call` items in `agentTrace`. `regex/` cases use 0 (LLM never invoked). |
| `minToolCalls` | int | Lower bound. Use to assert a swap path actually queried token meta. |
| `mustContainTrace` | array&lt;string&gt; | Substrings the encoded JSON of `agentTrace` must contain — typically tool names (`token_lookup`, `prepare_uniswap_v3_swap`). |
| `unresolvedNoteContains` | string | For `regex-clarification` cases, a substring the regex's clarification note must contain. |

## Running

Not wired into CI yet. The runner is intentionally trivial — bash +
`jq` will do, or a Lean smoke binary similar to
`tests/agent_phase0_smoke.sh`. Skeleton:

```bash
# Prerequisites: leancli-daemon + leancli-agentd both running.
for case in tests/evals/chat_draft/{regex,llm}/*.json; do
  prompt=$(jq -r .prompt "$case")
  chainId=$(jq -r .chainId "$case")
  resp=$(printf '{"jsonrpc":"2.0","id":1,"method":"chat.draft","params":{"prompt":%s,"chainId":%d}}' \
           "$(jq -nc --arg p "$prompt" '$p')" "$chainId" \
       | nc -U "$XDG_RUNTIME_DIR/leancli/leancli.sock")
  # Score against jq queries on $resp and "$case".expect — see runner.sh.
done
```

Cases under `regex/` must NEVER hit the LLM. If `agentTrace.length > 0`
the case is flagged: either the prompt drifted out of RuleParser's
coverage or RuleParser regressed. Both are interesting failures.

## Authoring guidance

* Use explicit 0x addresses in the prompt — wallet-name and address-book
  resolution depend on local state the corpus deliberately does not set
  up. Cases that exercise resolution belong in a separate integration
  fixture.
* Keep `chainId` to 11155111 (Sepolia) unless the case specifically
  tests a mainnet-only protocol. The chain pin in
  `Agent.Prompt.operationalRules` only matters once the LLM fires; the
  regex layer is chain-agnostic.
* For `llm/` cases, assert the **outcome** (final encoded intent kind),
  not the path (which tools the model chose). The local model is
  permitted to take different tool routes as long as the wallet still
  reaches a correct `propose_send`.
* Trace items added by the new `llmCall` and `skills` constructors
  (`LeanCli/Agent/Trace.lean`) carry `durationMs` + token counts +
  skill activation per round — use them to compute cost-aware metrics
  (tokens per outcome, p95 turn latency, skill→outcome correlation).
