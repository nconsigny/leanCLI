# Phase 1c — Memory + compression + incognito

Phase 1c adds three loop-infrastructure features to the Lean-native
agent. None of them widen the trust surface: memory and compression
are pure-Lean transformations of the message transcript, gated by the
existing forbidden-import gate, and incognito is a hard switch that
**disables** persistence.

## Scope (and what is NOT scope)

In scope:

1. `LeanCli/Agent/Memory.lean` — load/save MEMORY.md;
   LLM-driven extraction at session close with a conservative
   post-extraction filter.
2. `LeanCli/Agent/MemoryPrompts.lean` — the extraction prompt with
   documented policy.
3. `LeanCli/Agent/Compression.lean` — token-budget-driven
   middle-turn summarisation.
4. Wiring in `Agent/Loop.lean` (compression) and
   `Agent/Prompt.lean` (memory rendering).
5. Two new daemon opcodes in `App/AgentDaemonMain.lean`:
   `extract_memory`, `update_memory`. Auto-trigger of
   `extract_memory` on `close_session` for non-incognito sessions.
6. Incognito propagation: CLI `--incognito` → bridge env →
   `create_session` metadata → daemon-side conditional writes.
7. `leancli memory show/edit/refresh/forget` CLI subcommands.
8. `docs/ARCHITECTURE.md` reflects the new modules and policies.

Out of scope (deferred):

- No new daemon RPCs in `leanclid` (the wallet daemon). Phase 1d.
- No new agent tools. Memory + compression are loop infra, not
  tools.
- No SQLCipher. Session DB stays plaintext on a 0600 file under a
  0700 directory; memory file gets the same posture.
- No real tokenizer. We use a word-count × 1.4 estimator with an
  override (`LEANCLI_TOKEN_RATIO`) for drift on specific models.
- No prompt caching / streaming. No L2.
- No changes to `bridge/clearsign/`, `LeanCli/Invariants/`,
  `LeanCli/Crypto/`, the wallet daemon, or the TUI source tree.
- No automated MEMORY.md import/export (manual user edits via
  `leancli memory edit`).

## Trust model (unchanged)

- Agent module import-graph gate still applies. Memory + compression
  touch the LLM and the session DB only — no signing, no key
  material.
- MEMORY.md mode 0600, parent dir 0700 — same posture as
  `sessions.db`.
- Incognito is a HARD switch: zero writes to sessions.db for that
  session, zero MEMORY.md writes. The agent loop runs entirely in
  memory.
- Memory extraction NEVER includes any of the following (forbidden by
  the prompt itself AND dropped by the post-extraction filter as
  defense in depth):
  - Private keys (`\b0x[a-fA-F0-9]{64}\b`)
  - Seed phrases / mnemonics (≥12 consecutive lowercase ASCII words)
  - Signing-API method names (`eth_sendRawTransaction`,
    `signTransaction`)
- Memory extraction also excludes (policy in the prompt, not in the
  filter): specific tx hashes, balances, addresses outside the
  trusted registry, exact amounts.

## §A — Memory module

`LeanCli/Agent/Memory.lean`:

```
namespace LeanCli.Agent.Memory

structure Memory where
  raw  : String
  path : System.FilePath

def defaultPath : IO System.FilePath
  -- $XDG_DATA_HOME/leancli/MEMORY.md
  --   fallback: $HOME/.local/share/leancli/MEMORY.md → /tmp

def load (path : System.FilePath) : IO Memory
  -- Returns Memory.raw = "" when the file is absent.

def save (m : Memory) : IO Unit
  -- Atomic write: tmpfile + rename. Mode 0600 on the rename target;
  -- best-effort chmod 0700 on the parent dir.

def renderForPrompt (m : Memory) (maxTokens : Nat := 1024) : String
  -- Trims to maxTokens (word-count × 1.4 estimator) with an
  -- explicit truncation marker.

def extract
    (cfg : AgentConfig) (existing : Memory)
    (sessionMessages : Array AgentMessage)
    : IO (Except String Memory)
  -- 1. Build meta-prompt (MemoryPrompts.extractionInstructions +
  --    existing + transcript)
  -- 2. Send to local LLM via Agent.Llm.chat
  -- 3. Parse the response as JSON; extract `memory` field
  -- 4. Apply post-extraction filter
  -- 5. Cap to 8192 bytes (line-boundary)
  -- Failure → Except.error; caller decides whether to keep the old
  -- file.

end LeanCli.Agent.Memory
```

### Post-extraction filter (defense in depth)

Drop any **line** in the proposed memory content that:

1. Contains `\b0x[a-fA-F0-9]{64}\b` (private-key shape).
2. Has ≥12 consecutive whitespace-separated lowercase ASCII words
   (potential BIP-39 mnemonic — over-cautious; the cost is dropping
   a long prose paragraph in lowercase, which is acceptable).
3. Contains `eth_sendRawTransaction`, `signTransaction`,
   `signTypedData`, `personal_sign`, or `eth_sign`.

Hard cap output at 8192 bytes; truncate at the last `\n` ≤ 8192 and
append `... (truncated)\n`.

We never log the dropped line content (only the **count** of dropped
lines, at info level).

## §B — Memory prompts module

`LeanCli/Agent/MemoryPrompts.lean` defines a single
`extractionInstructions : String` literal. It is the meta-prompt the
LLM sees when asked to update MEMORY.md.

Rationale per rule:

- **INCLUDE: user preferences, recurring patterns, role.** These are
  durably useful; future sessions can frame answers in terms of what
  the user has previously said about themselves.
- **EXCLUDE: tx hashes, block numbers, exact balances.** These are
  ephemeral and not useful as long-term memory (a stale tx hash
  cannot be acted on).
- **EXCLUDE: specific addresses unless in the trusted registry.**
  Memorising addresses the user typed once is a phishing vector — if
  the model later refers back to it as "your usual recipient", a
  homoglyph attack succeeds.
- **EXCLUDE: 64-char hex, 12+ lowercase ASCII words.** Belt-and-
  braces for the post-filter — the model should never even propose
  this content.
- **EXCLUDE: incognito sessions.** This is enforced by the caller
  (extract is never invoked for incognito sessions).
- **OUTPUT: single JSON object `{"memory": "..."}`.** Forces the
  model to commit to one full replacement rather than emit a diff
  the daemon would have to apply.

## §C — Compression module

`LeanCli/Agent/Compression.lean`:

```
namespace LeanCli.Agent.Compression

def estimateTokens (msgs : Array AgentMessage) : IO Nat
  -- Word count × ratio. Default ratio is 1.4. Read
  -- LEANCLI_TOKEN_RATIO env var for an override; parse failure
  -- → fall back to 1.4.

structure Policy where
  triggerTokens : Nat := 6000
  keepLastTurns : Nat := 4
  targetTokens  : Nat := 3000

def maybeCompress
    (cfg : AgentConfig) (policy : Policy)
    (msgs : Array AgentMessage)
    : IO (Except String (Array AgentMessage))

end LeanCli.Agent.Compression
```

### Compression algorithm

1. Estimate tokens. If `est ≤ triggerTokens`, return `Except.ok msgs`
   (no LLM call).
2. Partition the array:
   - `head`: the first system-role message (always preserved).
   - `tail`: the last `keepLastTurns` user/assistant turn pairs
     plus interleaved tool messages.
   - `middle`: everything in between.
3. If `middle` is empty (or only a single placeholder system msg),
   return unchanged — nothing to compress.
4. If `middle.head?` is already a system message whose content
   starts with `[Earlier in session, summarised]`, include its body
   in the new summary so prior compressions don't shed context.
5. Ask the LLM (one round, no tools) to summarise `middle` in
   ≤ `targetTokens` tokens, preserving addresses, contract names,
   user decisions, and load-bearing tool results.
6. Replace `middle` with a single system-role message:
   ```
   [Earlier in session, summarised]

   <summary>
   ```
7. Return the new array as `Except.ok`.

### Why these parameters?

- `triggerTokens = 6000`: a typical local-model context window is
  8–16k. Triggering at 6k leaves headroom for the next turn's user
  prompt + tool output before the model hits its limit.
- `keepLastTurns = 4`: empirical — four turn pairs is enough that
  the model can carry an in-progress task (typical: user asks →
  agent calls `decode_calldata` → calls `tx.simulate` → emits a
  `propose_send` draft).
- `targetTokens = 3000`: half of the trigger, leaves ~3k of margin
  for the rest of the system prompt + the new user turn.
- Idempotency: a second call to `maybeCompress` on already-
  compressed input falls under `est ≤ triggerTokens` (because the
  compressed transcript is by construction smaller than `target`)
  and returns the input unchanged.

## §D — Loop and Prompt integration

`Agent/Loop.lean`:

- Add a `maybeCompress` call **before** every LLM round inside
  `runOneShotWithRebuild`. On `Except.ok`, replace `s.messages`. On
  `Except.error`, log to stderr and proceed with the un-compressed
  transcript (compression failure is a graceful no-op).
- Log when compression actually fires (info level on stderr,
  gated by `LEANCLI_LOG_PROMPT`).

`Agent/Prompt.lean`:

- New section order in the system prompt:
  `persona → memory → always-on skills → trigger skills →
   operational rules → tool docs`.
- Memory block is omitted entirely (no header, no marker) when the
  rendered memory is empty.

We add `buildSystemPromptWithMemoryAndSkills` next to the existing
builders so the Phase-0 one-shot binary's call shape doesn't change.

## §E — Daemon integration

`App/AgentDaemonMain.lean`:

- Open MEMORY.md at startup. Hold the parsed `Memory` in a new
  `IO.Ref` field on `DaemonState`. Reload on `reload` op (memory
  fields are file-cached the same way skills are).
- New opcode `extract_memory`:
  `{"op": "extract_memory", "session_id": N}` — load messages,
  call `Memory.extract`, atomic-write on success, return
  `{ok:true, result:{updated:true, bytes:N}}` or
  `{ok:false, error:...}` on failure (file unchanged).
- New opcode `update_memory`:
  `{"op": "update_memory", "content": "..."}` — atomic write,
  used by `leancli memory edit`.
- Auto-trigger: on `close_session`, if the session is NOT
  incognito AND `≥6` messages have been appended, call
  `Memory.extract` synchronously before responding. Failure logs
  + proceeds without update (close_session still returns ok).
- Memory rendering: `mkRebuildSystem` reads the live memory off
  the daemon ref and passes the rendered string to the new
  `buildSystemPromptWithMemoryAndSkills`.

### Incognito plumbing (§F)

CLI:

- `leancli tui --incognito` — sets `LEANCLI_INCOGNITO=1` in the
  environment of the TUI subprocess. (TUI menu toggle for entering
  incognito mid-session is out of scope as visual UI; only the env
  pass-through is wired.)
- `leancli send --incognito ...` — applies to one-off send flow
  (already passes through the daemon's normal send path; only
  affects the agent-bridge call shape).

Wire-up:

- `LlmAgent/Bridge.lean` reads `LEANCLI_INCOGNITO=1` and adds
  `("incognito", .bool true)` to the `create_session` metadata
  object.
- `AgentDaemonMain.opCreateSession` inspects the metadata. If
  `incognito` is true:
  - The session row is created normally (so the returned
    `session_id` has meaning) and metadata records the flag.
  - `appendMessage` is a no-op for the lifetime of the session.
  - `close_session` does NOT auto-trigger `extract_memory`.
- The per-turn response carries an `incognito` flag back so the
  TUI can render a marker. Visual marker design is out of scope —
  flag pass-through only.

Implementation note: rather than thread "is this sid incognito"
through every operation, the daemon keeps an `IO.Ref` set of
incognito session ids. `opCreateSession` adds to the set when
metadata says incognito; `opCloseSession` removes from it. Append
and close paths check membership.

## §G — CLI subcommands

`LeanCli/Cli/MemoryCmd.lean`:

- `leancli memory show` — `socketCall` to the agent daemon's
  `update_memory`? No — show is a read-mostly op, but to keep the
  daemon as sole writer (and avoid an inconsistent file mode race
  with `leancli memory edit`), `show` reads the file directly. The
  daemon writes, the CLI reads. (Documented in the module
  docstring.)
- `leancli memory edit` — read the file, write to a temp file under
  `$XDG_RUNTIME_DIR/leancli/memory.edit.<pid>.md`, open
  `$EDITOR` (fallback `vi`). After the editor exits with 0, slurp
  the file and POST it to the agent daemon as `update_memory`.
- `leancli memory refresh [--session N]` — POST `extract_memory`
  for the given session (or the latest closed one, if `--session`
  is omitted — daemon picks).
- `leancli memory forget <pattern>` — refuse if `pattern.length <
  4`. Otherwise read the current memory, strip any **line**
  containing `pattern`, POST the result via `update_memory`.

All four go through the agent daemon socket for writes so the
daemon remains the sole writer of MEMORY.md (parity with
sessions.db being daemon-owned).

## Ambiguity and resolution

- **llama-server JSON mode unreliable** → fall back to defensive
  parse (first balanced JSON object found in the response; failure
  → `Except.error`, don't update).
- **Token estimator drifts on specific model** →
  `LEANCLI_TOKEN_RATIO` env override. Default unchanged.
- **Curator wants to edit MEMORY.md while daemon holds it open** →
  `leancli memory edit` routes through the daemon's `update_memory`
  op, NOT a direct write. The daemon is the single writer; the
  CLI's role is to assemble the new content and POST it.
- **What happens when the LLM returns malformed JSON?** Extraction
  returns `Except.error`, file is unchanged, the user's existing
  memory is preserved. We never blow MEMORY.md to zero on a
  protocol error.
- **What if the wallet daemon is down when the LLM agent extracts
  memory?** Memory extraction does not touch the wallet daemon —
  it goes through `Agent.Llm.chat` (loopback HTTP) only.

## Divergences from upstream `ethereum/kohaku`

Upstream has no formal Lean counterpart for memory or compression;
TypeScript implementations of similar features tend to live in the
front-end. This phase establishes the Lean-side primitive so the
TUI / CLI both delegate to the same audited code path. The
extraction prompt and post-filter rules are leanCLI-specific
(more restrictive than what a TS implementation might do); when /
if upstream introduces a memory feature, we'll cross-reference the
exclusion list explicitly.

## Acceptance criteria

1. `lake build` succeeds. No `Invariants/` regression. No new
   `sorry` or `axiom`.
2. MEMORY.md created at documented path with mode `0600`, parent dir
   `0700`.
3. Closing a normal (non-incognito) session of ≥6 messages triggers
   extraction and updates MEMORY.md.
4. Post-extraction filter drops a line containing a 64-char hex
   (smoke step 4).
5. Post-extraction filter drops a line containing 12+ consecutive
   lowercase ASCII words.
6. Memory content appears in the system prompt of new sessions
   when non-empty; absent (no header / no marker) when empty.
7. Compression fires deterministically when estimated tokens
   exceed the threshold; produces a single
   `[Earlier in session, summarised]` system message; preserves
   first system message + last K turn pairs.
8. Compression is idempotent: running twice on already-compressed
   input is a no-op.
9. Incognito: messages not in `sessions.db`, MEMORY.md unchanged
   after close, `create_session` metadata records the flag.
10. `leancli memory show/edit/refresh/forget` all work.
    `forget` refuses patterns < 4 chars.
11. Forbidden-import gate still empty.
12. `docs/ARCHITECTURE.md` reflects the new modules.
13. Files outside §A–§G unchanged.
14. Memory extraction or compression error does NOT crash the
    agent. Both are graceful no-ops on failure.
