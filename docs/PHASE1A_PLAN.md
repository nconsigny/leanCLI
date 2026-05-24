# Phase 1a — Persistent agent sidecar + sessions

Phase 0 landed a Lean-native agent (`kohaku-agent`) as a one-shot binary
that `LlmAgent.Bridge` spawns per `chat.draft` / `llm.parseIntent` call.
Phase 1a adds a **long-running** sibling daemon, `kohaku-agentd`, that
persists session history in SQLite (with FTS5 full-text search). The
one-shot path keeps working unchanged. `LlmAgent.Bridge` auto-detects
which transport to use; the TUI is not modified and cannot tell which
path served its request.

This document is the load-bearing reference for the Phase 1a layout:
file paths, XDG locations, UDS frame shape, divergences from the brief.

---

## Trust model (unchanged from Phase 0)

The wallet daemon remains the signing trust root.

* `kohaku-agentd` has the same import-graph constraints as
  `kohaku-agent`: no `Crypto.Secp256k1Native`, `Crypto.Random`,
  `Wallet.{EOA,HDKey,Mnemonic,Entropy}`, `Keystore/**`,
  `Daemon.State`. The acceptance gate greps for those names; the
  Phase 1a build extends the gate to `App/AgentDaemonMain.lean`.
* The HTTP loopback floor lives in C (`c/lean_http/lean_http.c`) and
  is unaffected by this phase.
* Tool dispatch still goes through `Agent.Tools.dispatch`, which
  enforces the operator's allowlist **in code** before any tool runs.
* Chain whitelist remains `[1, 11155111]` (mainnet, Sepolia). No L2
  strings anywhere.
* `run_turn` results are model output. They are still untrusted
  relative to the wallet daemon: a draft tx that comes out of a
  `run_turn` lands in the same `chat.draft` -> `IntentParser` ->
  `tx.simulate` -> `ConfirmGate` -> `eoa.send` pipeline as the
  Phase 0 one-shot path.

The session DB stores conversation history only:

* messages (user, assistant, tool) and structured tool calls,
* timestamps and metadata (chain id, model name),
* **no seed material, no private keys, no plaintext signing
  payloads** — those are not reachable from anything in `Agent/`.

DB file mode is `0600`; parent directory mode is `0700`.
`kohaku-agentd` runs as a user-scope systemd service; never root.

---

## XDG paths

Approved defaults from the Phase 1a prompt:

| What                | Env override             | Default                                                    |
|---------------------|--------------------------|------------------------------------------------------------|
| Session DB          | `KOHAKU_AGENT_DB`        | `$XDG_DATA_HOME/leankohaku/sessions.db`                    |
|                     |                          | (falls back to `$HOME/.local/share/leankohaku/sessions.db`)|
| Agent UDS socket    | `KOHAKU_AGENT_SOCKET`    | `$XDG_RUNTIME_DIR/leankohaku/agent.sock`                   |
|                     |                          | (falls back to `/run/user/$UID/leankohaku/agent.sock`)     |
| Wallet daemon UDS   | `LEAN_KOHAKU_DAEMON_SOCKET` / `LEANKOHAKU_SOCKET` | `$XDG_RUNTIME_DIR/leankohaku/leankohaku.sock`         |

`leankohaku.sock` and `agent.sock` share the same parent dir so a
single `mkdir -m700` covers both.

---

## Modules added (and approximate sizes)

| Path                                                  | Purpose                                                       |
|-------------------------------------------------------|---------------------------------------------------------------|
| `c/lean_sqlite/lean_sqlite.h`                         | C ABI (sqlite3 wrapper)                                       |
| `c/lean_sqlite/lean_sqlite.c`                         | FFI shim — `lk_sqlite_*` entry points; links system libsqlite3|
| `c/lean_sqlite/README.md`                             | System-libsqlite3 / FTS5 rationale                            |
| `script/setup_sqlite.sh`                              | Header + FTS5 probe; idempotent                               |
| `LeanKohaku/Agent/Session.lean`                       | Schema, opaque `Handle`, CRUD + `searchFts`                   |
| `LeanKohaku/Agent/SessionTest.lean`                   | Round-trip + concurrent-handle test (lean_exe)                |
| `LeanKohaku/App/AgentDaemonMain.lean`                 | `kohaku-agentd` entry point — accept loop, op dispatch        |
| `packaging/systemd/kohaku-agentd.service`             | User-scope unit, hardened                                     |
| `tests/agent_phase1a_smoke.sh`                        | End-to-end smoke (ping, run_turn x3, search, restart)         |

Files modified:

| Path                                  | Change                                                       |
|---------------------------------------|--------------------------------------------------------------|
| `lakefile.lean`                       | `extern_lib liblean_sqlite`, `lean_exe kohaku_agentd`, `lean_exe agent_session_test` |
| `LeanKohaku/LlmAgent/Bridge.lean`     | Mode resolution (env -> probe -> one-shot)                   |
| `packaging/arch/PKGBUILD`             | `sqlite` dep, install `kohaku-agentd` + systemd unit         |
| `docs/ARCHITECTURE.md`                | Module reference + native side updates                       |
| `INVARIANTS.md`                       | (only if new properties added — Phase 1a does not add any)   |

---

## SQLite FFI surface

Public C functions in `c/lean_sqlite/lean_sqlite.h`:

```c
int  lk_sqlite_open(const char* path, void** out_handle);
void lk_sqlite_close(void* handle);
int  lk_sqlite_exec(void* handle, const char* sql, char** out_err);
int  lk_sqlite_prepare(void* handle, const char* sql, void** out_stmt);
int  lk_sqlite_bind_text(void* stmt, int idx, const char* text);
int  lk_sqlite_bind_int64(void* stmt, int idx, long long val);
int  lk_sqlite_step(void* stmt);
const char* lk_sqlite_column_text(void* stmt, int idx);
long long   lk_sqlite_column_int64(void* stmt, int idx);
int  lk_sqlite_finalize(void* stmt);
const char* lk_sqlite_errmsg(void* handle);
void lk_sqlite_free_err(char* err);
```

Lean bindings live in `LeanKohaku/Agent/Session.lean` as
`@[extern] opaque` declarations (no `axiom`, per the approved Phase 1a
defaults). This matches the pattern in `Daemon/Uds.lean` and
`Agent/Http.lean`.

**System-libsqlite3 rationale**. SQLite ships with FTS5 in the
distribution package on Arch (`sqlite`) and on Debian 12+
(`libsqlite3-0`). Vendoring the amalgamation would (a) add ~250 KLOC
of C to the tree, (b) duplicate work distributions already do well,
(c) introduce a second source of truth for CVE patching. The trade-off
is that we pin against a moving target; `script/setup_sqlite.sh` does
a header probe and fails loudly if `sqlite3.h` is missing.

**Column lifetime**. SQLite's `sqlite3_column_text` returns a pointer
valid only until the next `_step` / `_finalize`. The FFI shim copies
into a Lean-owned `String` before returning, so Lean code can hold
onto the result across further DB calls. This is documented in
`c/lean_sqlite/lean_sqlite.c` and tested by appending 10 messages then
walking them with a single prepared statement.

---

## Session schema (Phase 1a — version 1)

```sql
CREATE TABLE IF NOT EXISTS schema_meta (
  version INTEGER NOT NULL
);
INSERT INTO schema_meta (version) VALUES (1);

CREATE TABLE IF NOT EXISTS sessions (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  closed_at  INTEGER,
  metadata   TEXT
);

CREATE TABLE IF NOT EXISTS messages (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   INTEGER NOT NULL REFERENCES sessions(id),
  seq          INTEGER NOT NULL,
  ts           INTEGER NOT NULL,
  role         TEXT NOT NULL,
  content      TEXT,
  tool_calls   TEXT,
  tool_call_id TEXT,
  UNIQUE(session_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
  USING fts5(content, content='messages', content_rowid='id');

CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, content)
    VALUES('delete', old.id, old.content);
END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, content)
    VALUES('delete', old.id, old.content);
  INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
END;
```

Phase 1a stays at `version = 1`. Schema migration is out of scope; a
mismatched `schema_meta.version` is a fatal error and the daemon
refuses to start. Phase 1c is expected to introduce schema-version 2.

`tool_calls` is the model-emitted JSON array (string-encoded). The
agent does not re-parse it on load; it round-trips bytes-for-bytes.

`seq` is monotonic per-session and is the wire-level ordering. The
session daemon never reorders; consumers read in `seq` ascending order.

---

## `kohaku-agentd` UDS frame shape

Newline-delimited JSON. One in-flight `run_turn` per session.
Same envelope shape as the JSON-RPC requests Phase 0 already speaks
(`{op, ...}` request -> `{ok, ...}` reply), but **not** JSON-RPC 2.0
proper: there is no `jsonrpc` / `id` / `method` keyword set. This keeps
the agent socket distinct from the wallet daemon socket so a misrouted
client cannot accidentally talk to the wrong process.

### Request ops

```json
{ "op": "ping" }
{ "op": "create_session", "metadata": { "chainId": 11155111, "model": "..." } }
{ "op": "run_turn", "session_id": 12, "prompt": "...", "context": {...} }
{ "op": "search", "query": "USDC transfer", "limit": 10 }
{ "op": "close_session", "session_id": 12 }
```

`context` is forwarded into the agent prompt-building step the same
way `chat.draft` already does in Phase 0: it carries `seed`, `chainId`,
`chainContext`, `walletContext`, `skillContext`. The agent
daemon does not interpret these fields beyond passing them along.

### Response envelopes

```json
{ "ok": true, "result": { "protocol": "0.0.1" } }
{ "ok": true, "result": { "session_id": 12, "created_at": 1700000000 } }
{ "ok": true, "result": {
    "session_id": 12,
    "seq": 4,
    "raw": "...assistant final-turn content...",
    "backend": "lean-agent",
    "model": "local-default",
    "toolTurns": 3
} }
{ "ok": true, "result": {
    "hits": [
      { "sessionId": 12, "messageId": 41, "snippet": "...USDC..." }
    ]
} }

{ "ok": false, "error": { "kind": "not_found",  "msg": "no session 12" } }
{ "ok": false, "error": { "kind": "busy",       "msg": "session 12 already running" } }
{ "ok": false, "error": { "kind": "agent",      "msg": "llm error: ..." } }
{ "ok": false, "error": { "kind": "schema",    "msg": "schema mismatch: db=2 expected=1" } }
{ "ok": false, "error": { "kind": "io",         "msg": "..." } }
```

Error `kind` strings are part of the contract — callers may key on them.

### `run_turn` semantics

1. Load existing messages for `session_id` in `seq` order.
2. Append the new `user` message (assigning the next `seq`).
3. Run `Agent.Loop.runOneShot` over `loaded ++ [user]` against the
   default tool registry.
4. Persist each new message produced during the loop (assistant +
   tool messages), each with the next monotonic `seq`.
5. Return the **final assistant message** as `result.raw` — same
   shape Phase 0's `kohaku-agent` already emits, so the wallet
   daemon's `chat.draft` code path needs no changes regardless of
   which backend served the request.

If `Agent.Loop.runOneShot` returns `.error`, the daemon still
persists the failed user turn and the partial transcript so the user
can see why it failed on the next load. The reply is
`{ok:false, error:{kind:"agent", msg:...}}`.

### Concurrency

One in-flight `run_turn` **per session** at a time, enforced by an
`IO.Mutex`-like guard keyed on `session_id`. A second concurrent
`run_turn` for the same session returns `kind:"busy"` without
attempting to run. Different sessions can run in parallel — this is
the simplest contract that makes restarts safe and matches the TUI's
single-flight-per-chat behaviour.

### Lifecycle

* Startup: open session DB, run schema bootstrap if empty, bind UDS,
  log `listening on <socket>` on stderr.
* Per request: one connection -> one line in -> one line out -> close.
* SIGTERM: stop accepting, drain in-flight `run_turn`s, close DB,
  exit clean. (Phase 1a draining: no per-turn checkpointing within
  the agent loop; the daemon waits for active turns to finish.)
* Wallet daemon disconnect mid-tool-call: bubbles up as
  `kind:"agent"` with the `DaemonClient.Error` message; the daemon
  itself does not crash.

---

## `LlmAgent/Bridge.lean` mode resolution

Order:

1. `LEAN_KOHAKU_AGENT_MODE=oneshot` -> force one-shot
   (spawn-and-wait, byte-identical to Phase 0).
2. `LEAN_KOHAKU_AGENT_MODE=persistent` -> force persistent. If the
   socket is missing or `ping` fails, the bridge returns a structured
   `Response.crash` instead of falling back. This is intentional: an
   operator who asked for persistent mode would rather see a clear
   failure than silently degrade.
3. Otherwise: auto-detect. If the agent socket exists and accepts
   `ping`, use persistent; else one-shot.
4. `LEAN_KOHAKU_LLM_BRIDGE_LEGACY=1` continues to route to the legacy
   Node sidecar at `bridge/llm-legacy/`. Legacy mode is incompatible
   with persistent; selecting both falls back to legacy (one-shot
   spawn). This is documented in `Bridge.resolveExecutable`'s
   docstring.

Persistent path inside `Bridge.call`:

1. `connect` to agent socket.
2. If no `session_id` field is in `params`, send `create_session`
   with `params.metadata` (if any); remember the returned id.
3. Send `run_turn` with `session_id`, `prompt`, and the rest of the
   original `params` (minus `prompt`) flattened into `context`.
4. Read one response line, close. Return the same
   `LlmAgent.Bridge.Response` shape (`ok` / `err` / `crash`) so the
   wallet daemon does not see any difference between modes.

The `chat.draft` handler in `Daemon/Server.lean` is the one upstream
consumer of `Bridge.call`. It does not need to know about sessions;
the bridge keeps the `session_id` opaque inside its own state. Phase
1a does not yet thread session ids through `chat.draft` -- a TUI chat
spans one bridge invocation (one user turn), so the bridge can create
a fresh session per invocation and close it on return.

**This is a Phase 1a divergence from the literal brief.** The brief
describes three `run_turn`s across one session as the canonical
smoke test; what we ship is "the agent daemon supports multi-turn
sessions, but the wallet daemon does not yet use that feature."
Reasoning: threading session ids through `chat.draft` is a wallet
daemon change (a new RPC argument), and §scope explicitly says "No
new wallet-daemon RPCs (1d)". Phase 1a's smoke test exercises the
multi-turn path directly against the agent socket; the wallet daemon
runs in single-turn mode. Phase 1d will hand-shake a `session_id`
through `chat.draft`.

---

## Divergences from the literal brief (and reasons)

* **`tui/src/screens/LlmDraftFlow.tsx` does not exist** in this tree;
  the equivalent screen is `LlmChatFlow.tsx`. I read that one
  instead. The brief's read-only constraint stands: no TUI source
  changes in Phase 1a.

* **`bridge/bridge.mjs` has an uncommitted modification** in the
  working tree from before this run (Railgun-SDK stdout redirect). It
  is unrelated to Phase 1a (§A-§G touches none of `bridge/`) and is
  not staged in any Phase 1a commit. The recovery stash
  (`stash@{0}`) is also left untouched per the operator's
  instruction.

* **Wallet daemon does not yet thread session ids through
  `chat.draft`** (see "Persistent path" above). Phase 1a's `kohaku-
  agentd` supports sessions, but the wallet daemon side keeps the
  Phase 0 single-turn shape until 1d.

* **No `Agent/Memory.lean`, no MEMORY.md, no
  `Agent/Compression.lean`, no `Agent/Skills.lean`.** Out of scope
  per the prompt (Phase 1b/1c).

* **No SQLCipher.** Approved Phase 1a default. DB file relies on
  `0600` mode plus the `0700` parent dir. Encrypted-at-rest sessions
  are a later phase.

* **No trajectory export, no incognito, no streaming.** Out of scope.

---

## Build & test

```bash
script/setup_sqlite.sh                          # header + FTS5 probe
lake build                                      # builds lib + 3 exes + tests
.lake/build/bin/agent_session_test              # runs the SQLite round-trip test
tests/agent_phase1a_smoke.sh                    # end-to-end (best-effort)
```

The CI grep gate (Phase 0 introduced) is extended to include
`LeanKohaku/App/AgentDaemonMain.lean`. The exact list of forbidden
imports is the same as Phase 0; the file simply joins the gated set.
