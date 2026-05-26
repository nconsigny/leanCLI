import LeanKohaku.Agent.State
import LeanKohaku.Encoding.Json

/-!
# Persistent agent session store

SQLite-backed session/message store used by the persistent
`kohaku-agentd` daemon. The schema, the schema bootstrap, and every
prepared statement live here. The opaque DB handle is wrapped in
`Handle` so callers cannot accidentally pass a raw pointer around.

Schema (version 1):

```sql
sessions(id, created_at, closed_at, metadata)
messages(id, session_id, seq, ts, role, content, tool_calls, tool_call_id)
messages_fts(content) virtual using fts5
```

Trust contract: this module imports no signing or key-material module.
Stored content is conversation history — user prompts, assistant text,
tool-call envelopes, tool-result JSON. By construction of the agent
import graph, no private-key bytes, no seed material, and no signing
payloads can reach this module. The DB file mode is `0600` and lives
under XDG_DATA_HOME with a `0700` parent dir; the caller is
responsible for enforcing those modes (`open` does not chmod because
the same `Handle` type is used for in-memory `:memory:` DBs in tests).
-/

namespace LeanKohaku.Agent.Session

open LeanKohaku.Agent
open LeanKohaku.Encoding.Json

/-- Opaque SQLite DB handle pointer, boxed as a `USize` across the
    FFI boundary. The `private` constructor prevents code outside
    this module from forging handles or passing in arbitrary
    pointer values. -/
structure Handle where
  private mk ::
  ptr : USize
  deriving Inhabited

/-- Opaque prepared-statement pointer. Same wrapping rationale as
    `Handle`. -/
private structure Stmt where
  mk ::
  ptr : USize

@[extern "lk_sqlite_open_ffi"]
private opaque sqliteOpen (path : @& String) : IO USize

@[extern "lk_sqlite_close_ffi"]
private opaque sqliteClose (h : USize) : IO Unit

@[extern "lk_sqlite_exec_ffi"]
private opaque sqliteExec (h : USize) (sql : @& String) : IO Unit

@[extern "lk_sqlite_prepare_ffi"]
private opaque sqlitePrepare (h : USize) (sql : @& String) : IO USize

@[extern "lk_sqlite_bind_text_ffi"]
private opaque sqliteBindText (s : USize) (idx : UInt32) (text : @& String) : IO Unit

@[extern "lk_sqlite_bind_int64_ffi"]
private opaque sqliteBindInt64 (s : USize) (idx : UInt32) (val : UInt64) : IO Unit

@[extern "lk_sqlite_step_ffi"]
private opaque sqliteStep (s : USize) : IO UInt32

@[extern "lk_sqlite_column_text_ffi"]
private opaque sqliteColumnText (s : USize) (idx : UInt32) : IO String

@[extern "lk_sqlite_column_int64_ffi"]
private opaque sqliteColumnInt64 (s : USize) (idx : UInt32) : IO UInt64

@[extern "lk_sqlite_finalize_ffi"]
private opaque sqliteFinalize (s : USize) : IO Unit

@[extern "lk_sqlite_errmsg_ffi"]
private opaque sqliteErrmsg (h : USize) : IO String

private def stepRow : UInt32 := 100
private def stepDone : UInt32 := 101

/-- Logical session identifier. -/
abbrev SessionId := Nat

/-- One FTS5 search hit, returned by `searchFts`. -/
structure SearchHit where
  sessionId : SessionId
  messageId : Nat
  snippet   : String
  deriving Repr

/-- Lightweight session-row projection used by the read-only history
    surface (`list_sessions` agentd op). Carries the column subset the
    TUI's session-list view needs without forcing a full transcript
    load. `metadataJson` is the raw JSON the session was created with
    (chainId / sessionKey live inside); the caller parses it. Older
    rows whose metadata column is `NULL` surface as `""`. -/
structure SessionMeta where
  sessionId      : SessionId
  createdAt      : Nat
  metadataJson   : String
  turnCount      : Nat
  firstUserPrompt : Option String
  lastTurnAt     : Option Nat
  deriving Repr, Inhabited

/-- Per-message row used by `loadSessionRows` / the agentd's
    `get_session` op. Carries the wire fields the TUI's session-detail
    view needs (`ts` for sort/display, plus the raw `tool_calls` and
    `tool_call_id` strings). `appendedAt` is the on-disk `ts` column
    in milliseconds. -/
structure MessageRow where
  seq        : Nat
  appendedAt : Nat
  role       : String
  content    : String
  toolCalls  : String
  toolCallId : String
  deriving Repr, Inhabited

/-- Run a no-result SQL statement against a handle. -/
private def exec (h : Handle) (sql : String) : IO Unit :=
  sqliteExec h.ptr sql

/-- Run an action with a freshly-prepared statement, finalising it
    on completion (success or exception). -/
private def withStmt {α : Type}
    (h : Handle) (sql : String) (k : Stmt → IO α) : IO α := do
  let ptr ← sqlitePrepare h.ptr sql
  let stmt : Stmt := ⟨ptr⟩
  try
    k stmt
  finally
    try sqliteFinalize stmt.ptr catch _ => pure ()

/-- Schema bootstrap. Idempotent; uses `IF NOT EXISTS` everywhere so
    re-running on an existing DB is a no-op. The `messages_fts`
    triggers shadow the canonical `messages` table so a delete/update
    keeps the FTS index in sync — see SQLite FTS5 docs §4.4.4. -/
private def schemaSql : String :=
  "BEGIN;\n" ++
  "CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER NOT NULL);\n" ++
  "INSERT INTO schema_meta (version)\n" ++
  "  SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_meta);\n" ++
  "CREATE TABLE IF NOT EXISTS sessions (\n" ++
  "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n" ++
  "  created_at INTEGER NOT NULL,\n" ++
  "  closed_at INTEGER,\n" ++
  "  metadata TEXT\n" ++
  ");\n" ++
  "CREATE TABLE IF NOT EXISTS messages (\n" ++
  "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n" ++
  "  session_id INTEGER NOT NULL REFERENCES sessions(id),\n" ++
  "  seq INTEGER NOT NULL,\n" ++
  "  ts INTEGER NOT NULL,\n" ++
  "  role TEXT NOT NULL,\n" ++
  "  content TEXT,\n" ++
  "  tool_calls TEXT,\n" ++
  "  tool_call_id TEXT,\n" ++
  "  UNIQUE(session_id, seq)\n" ++
  ");\n" ++
  "CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);\n" ++
  "CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts\n" ++
  "  USING fts5(content, content='messages', content_rowid='id');\n" ++
  "CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN\n" ++
  "  INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);\n" ++
  "END;\n" ++
  "CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN\n" ++
  "  INSERT INTO messages_fts(messages_fts, rowid, content)\n" ++
  "    VALUES('delete', old.id, old.content);\n" ++
  "END;\n" ++
  "CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN\n" ++
  "  INSERT INTO messages_fts(messages_fts, rowid, content)\n" ++
  "    VALUES('delete', old.id, old.content);\n" ++
  "  INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);\n" ++
  "END;\n" ++
  "COMMIT;"

/-- Verify the on-disk schema version matches what this build expects.
    Phase 1a expects version 1; a mismatch is fatal so an older
    daemon never silently migrates a newer DB or vice versa. -/
private def expectedSchemaVersion : Nat := 1

private def checkSchemaVersion (h : Handle) : IO Unit := do
  withStmt h "SELECT version FROM schema_meta LIMIT 1;" fun s => do
    let rc ← sqliteStep s.ptr
    if rc == stepRow then
      let v ← sqliteColumnInt64 s.ptr 0
      let vn := v.toNat
      if vn ≠ expectedSchemaVersion then
        throw <| IO.userError
          s!"sqlite: schema mismatch (db={vn} expected={expectedSchemaVersion})"
    else
      throw <| IO.userError "sqlite: schema_meta row missing"

/-- Open `path` and bootstrap the schema if needed. Caller is
    responsible for enforcing file mode `0600` after this returns
    (skipped here so `:memory:` and `file::memory:?cache=shared`
    test handles work the same way). Named `openDb` because `open`
    is a reserved keyword in Lean 4 (namespace opener). -/
def openDb (path : String) : IO Handle := do
  let ptr ← sqliteOpen path
  let h : Handle := ⟨ptr⟩
  exec h schemaSql
  checkSchemaVersion h
  pure h

/-- Close a handle. Idempotent; safe to call from a `finally`. -/
def close (h : Handle) : IO Unit :=
  sqliteClose h.ptr

/-- Wall-clock millis since epoch. Used as `ts`/`created_at`. We use
    monotonic ms in tests where reproducibility matters; production
    sessions get the real time clock. -/
private def nowMs : IO UInt64 := do
  pure ((← IO.monoMsNow).toUInt64)

/-- Create a new session with `metadata` (serialised compact JSON). -/
def createSession (h : Handle) (metadata : Json) : IO SessionId := do
  let ts ← nowMs
  let md := compact metadata
  withStmt h
    "INSERT INTO sessions (created_at, metadata) VALUES (?, ?);" fun s => do
    sqliteBindInt64 s.ptr 1 ts
    sqliteBindText s.ptr 2 md
    let rc ← sqliteStep s.ptr
    if rc ≠ stepDone then
      throw <| IO.userError s!"createSession: unexpected step rc={rc}"
  withStmt h "SELECT last_insert_rowid();" fun s => do
    let rc ← sqliteStep s.ptr
    if rc ≠ stepRow then
      throw <| IO.userError "createSession: last_insert_rowid returned no row"
    let v ← sqliteColumnInt64 s.ptr 0
    pure v.toNat

/-- Mark a session closed. Subsequent `appendMessage` calls will still
    succeed; closing only records a `closed_at` for diagnostics. -/
def closeSessionRow (h : Handle) (sid : SessionId) : IO Unit := do
  let ts ← nowMs
  withStmt h
    "UPDATE sessions SET closed_at = ? WHERE id = ?;" fun s => do
    sqliteBindInt64 s.ptr 1 ts
    sqliteBindInt64 s.ptr 2 sid.toUInt64
    let rc ← sqliteStep s.ptr
    if rc ≠ stepDone then
      throw <| IO.userError s!"closeSession: unexpected step rc={rc}"

private def roleToString : Role → String
  | .system    => "system"
  | .user      => "user"
  | .assistant => "assistant"
  | .tool      => "tool"

private def roleOfString : String → Role
  | "system"    => .system
  | "user"      => .user
  | "assistant" => .assistant
  | "tool"      => .tool
  | _           => .user   -- never reached for our own writes; defensive

/-- Encode the tool-call array as compact JSON for storage. -/
private def encodeToolCalls (cs : List ToolCall) : String :=
  if cs.isEmpty then "" else
    compact <| .arr <| cs.toArray.map fun c =>
      .obj #[
        ("id",      .str c.id),
        ("name",    .str c.name),
        ("argsJson", .str c.argsJson)
      ]

private def decodeToolCalls (s : String) : List ToolCall :=
  if s.isEmpty then [] else
    match parse s with
    | .ok (.arr arr) =>
        arr.toList.filterMap fun j =>
          match j with
          | .obj _ =>
              let id   := (getField "id" j >>= asString).getD ""
              let name := (getField "name" j >>= asString).getD ""
              let args := (getField "argsJson" j >>= asString).getD "{}"
              if name.isEmpty then none
              else some { id := id, name := name, argsJson := args }
          | _ => none
    | _ => []

/-- Append a message to `sid`. `seq` is computed as 1 + the current
    max for the session so the daemon never has to track it
    out-of-band. -/
def appendMessage (h : Handle) (sid : SessionId) (msg : AgentMessage) : IO Unit := do
  let ts ← nowMs
  -- Compute next seq. Two statements, one transaction.
  let nextSeq : UInt64 ← withStmt h
    "SELECT COALESCE(MAX(seq) + 1, 0) FROM messages WHERE session_id = ?;"
    fun s => do
      sqliteBindInt64 s.ptr 1 sid.toUInt64
      let rc ← sqliteStep s.ptr
      if rc ≠ stepRow then
        throw <| IO.userError "appendMessage: max(seq) returned no row"
      sqliteColumnInt64 s.ptr 0
  withStmt h
    ("INSERT INTO messages\n" ++
     "  (session_id, seq, ts, role, content, tool_calls, tool_call_id)\n" ++
     "  VALUES (?, ?, ?, ?, ?, ?, ?);") fun s => do
    sqliteBindInt64 s.ptr 1 sid.toUInt64
    sqliteBindInt64 s.ptr 2 nextSeq
    sqliteBindInt64 s.ptr 3 ts
    sqliteBindText  s.ptr 4 (roleToString msg.role)
    sqliteBindText  s.ptr 5 (msg.content.getD "")
    sqliteBindText  s.ptr 6 (encodeToolCalls msg.toolCalls)
    sqliteBindText  s.ptr 7 (msg.toolCallId.getD "")
    let rc ← sqliteStep s.ptr
    if rc ≠ stepDone then
      throw <| IO.userError s!"appendMessage: unexpected step rc={rc}"

/-- Read all messages for `sid` in `seq` order. -/
def loadSession (h : Handle) (sid : SessionId) : IO (Array AgentMessage) := do
  withStmt h
    ("SELECT role, content, tool_calls, tool_call_id\n" ++
     "  FROM messages WHERE session_id = ? ORDER BY seq ASC;") fun s => do
    sqliteBindInt64 s.ptr 1 sid.toUInt64
    let mut out : Array AgentMessage := #[]
    let mut loop := true
    while loop do
      let rc ← sqliteStep s.ptr
      if rc == stepRow then
        let role       ← sqliteColumnText s.ptr 0
        let content    ← sqliteColumnText s.ptr 1
        let toolCalls  ← sqliteColumnText s.ptr 2
        let toolCallId ← sqliteColumnText s.ptr 3
        let m : AgentMessage := {
          role := roleOfString role,
          content := if content.isEmpty then none else some content,
          toolCalls := decodeToolCalls toolCalls,
          toolCallId := if toolCallId.isEmpty then none else some toolCallId
        }
        out := out.push m
      else
        loop := false
    pure out

/-- Display-only cap on `firstUserPrompt` in the session-list view.
    Matches the wire spec for the agentd's `list_sessions` op. -/
def firstUserPromptCap : Nat := 140

/-- Truncate `s` to at most `firstUserPromptCap` characters, appending
    an ellipsis when truncated. Pure, no IO. Used only for the list
    projection — the session-detail view still shows the full content. -/
def truncatePromptForList (s : String) : String :=
  if s.length ≤ firstUserPromptCap then s
  else String.ofList (s.toList.take firstUserPromptCap) ++ "…"

/-- Enumerate sessions newest-first. The filtering predicate is run in
    Lean after row decode rather than in SQL because the `chainId` /
    `sessionKey` live inside the metadata JSON column; parsing in Lean
    is straightforward and avoids depending on SQLite's `json_extract`.

    Older rows whose `metadata` column is `NULL` (or whose JSON is
    malformed) survive the listing — they just surface with
    `metadataJson := ""` and the caller treats their chainId /
    sessionKey as absent.

    The per-session aggregate (turn count, first user prompt, last
    `ts`) is computed with a single grouped query so listing N sessions
    is O(N) row fetches rather than 3N. `limit` caps the result set. -/
def listSessions (h : Handle) (limit : Nat) : IO (Array SessionMeta) := do
  withStmt h
    ("SELECT s.id, s.created_at, COALESCE(s.metadata, ''),\n" ++
     "       COALESCE(c.cnt, 0),\n" ++
     "       (SELECT m.content FROM messages m\n" ++
     "          WHERE m.session_id = s.id AND m.role = 'user'\n" ++
     "          ORDER BY m.seq ASC LIMIT 1) AS first_user,\n" ++
     "       c.last_ts\n" ++
     "  FROM sessions s\n" ++
     "  LEFT JOIN (\n" ++
     "    SELECT session_id, COUNT(*) AS cnt, MAX(ts) AS last_ts\n" ++
     "      FROM messages GROUP BY session_id\n" ++
     "  ) c ON c.session_id = s.id\n" ++
     "  ORDER BY s.created_at DESC LIMIT ?;") fun s => do
    sqliteBindInt64 s.ptr 1 limit.toUInt64
    let mut out : Array SessionMeta := #[]
    let mut loop := true
    while loop do
      let rc ← sqliteStep s.ptr
      if rc == stepRow then
        let sid       ← sqliteColumnInt64 s.ptr 0
        let createdAt ← sqliteColumnInt64 s.ptr 1
        let metaJson  ← sqliteColumnText s.ptr 2
        let cnt       ← sqliteColumnInt64 s.ptr 3
        let firstUser ← sqliteColumnText s.ptr 4
        let lastTs    ← sqliteColumnInt64 s.ptr 5
        -- SQLite NULL via the lk_sqlite_column_text_ffi shim arrives as
        -- the empty string; preserve that so the caller can distinguish
        -- "no user message yet" from a real empty content.
        let firstUserOpt : Option String :=
          if firstUser.isEmpty then none
          else some (truncatePromptForList firstUser)
        -- A 0 from MAX(ts) means "no rows" (the LEFT JOIN gave us a
        -- NULL, mapped to 0 by the shim). Surface it as `none` so the
        -- TUI does not render a 1970 epoch timestamp.
        let lastTsOpt : Option Nat :=
          if lastTs.toNat = 0 then none else some lastTs.toNat
        out := out.push {
          sessionId := sid.toNat,
          createdAt := createdAt.toNat,
          metadataJson := metaJson,
          turnCount := cnt.toNat,
          firstUserPrompt := firstUserOpt,
          lastTurnAt := lastTsOpt
        }
      else
        loop := false
    pure out

/-- Read all message rows for `sid` in `seq` order, preserving every
    column the wire-shape consumers need (including `ts` and the raw
    `tool_calls` / `tool_call_id` strings).

    Companion to `loadSession`, which projects directly into
    `AgentMessage` and drops `seq`/`ts`. The history surface wants both
    the turn index and the appended-at timestamp for display, so a
    separate projection is cheaper than reshaping the agent-loop type. -/
def loadSessionRows (h : Handle) (sid : SessionId) : IO (Array MessageRow) := do
  withStmt h
    ("SELECT seq, ts, role, content, tool_calls, tool_call_id\n" ++
     "  FROM messages WHERE session_id = ? ORDER BY seq ASC;") fun s => do
    sqliteBindInt64 s.ptr 1 sid.toUInt64
    let mut out : Array MessageRow := #[]
    let mut loop := true
    while loop do
      let rc ← sqliteStep s.ptr
      if rc == stepRow then
        let seq        ← sqliteColumnInt64 s.ptr 0
        let ts         ← sqliteColumnInt64 s.ptr 1
        let role       ← sqliteColumnText s.ptr 2
        let content    ← sqliteColumnText s.ptr 3
        let toolCalls  ← sqliteColumnText s.ptr 4
        let toolCallId ← sqliteColumnText s.ptr 5
        out := out.push {
          seq := seq.toNat,
          appendedAt := ts.toNat,
          role := role,
          content := content,
          toolCalls := toolCalls,
          toolCallId := toolCallId
        }
      else
        loop := false
    pure out

/-- FTS5 full-text search over message content. Returns the top
    `limit` matches with a `snippet(...)` that highlights the matched
    region. Caller is expected to sanitise `query` — FTS5 has its own
    query syntax (`AND`, `OR`, `"..."`, column filters); we pass the
    string through verbatim. -/
def searchFts (h : Handle) (query : String) (limit : Nat := 20) :
    IO (Array SearchHit) := do
  withStmt h
    ("SELECT m.session_id, m.id,\n" ++
     "       snippet(messages_fts, 0, '<<', '>>', '...', 16)\n" ++
     "  FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid\n" ++
     "  WHERE messages_fts MATCH ?\n" ++
     "  ORDER BY rank LIMIT ?;") fun s => do
    sqliteBindText  s.ptr 1 query
    sqliteBindInt64 s.ptr 2 limit.toUInt64
    let mut out : Array SearchHit := #[]
    let mut loop := true
    while loop do
      let rc ← sqliteStep s.ptr
      if rc == stepRow then
        let sid ← sqliteColumnInt64 s.ptr 0
        let mid ← sqliteColumnInt64 s.ptr 1
        let snip ← sqliteColumnText s.ptr 2
        out := out.push {
          sessionId := sid.toNat,
          messageId := mid.toNat,
          snippet   := snip
        }
      else
        loop := false
    pure out

end LeanKohaku.Agent.Session
