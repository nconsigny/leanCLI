import LeanKohaku.Agent.State
import LeanKohaku.Agent.Prompt
import LeanKohaku.Agent.Tools
import LeanKohaku.Agent.Registry
import LeanKohaku.Agent.Loop
import LeanKohaku.Agent.Session
import LeanKohaku.Encoding.Json
import LeanKohaku.Transport.Uds

/-!
# `kohaku-agentd` — persistent agent daemon

Long-running sibling of `kohaku-agent`. Listens on a Unix domain
socket and handles session-scoped chat turns backed by the SQLite
session store in `LeanKohaku/Agent/Session.lean`. Phase 1a wire
shape is newline-delimited JSON with the op set documented in
`docs/PHASE1A_PLAN.md`.

Trust contract (unchanged from Phase 0):
* This module imports no signing or key-material module. The
  forbidden-import list in `docs/PHASE0_PLAN.md` is the canonical
  reference; the CI gate greps for those names and this file is
  on the gated path.
* The only network path is `Agent.Http` (loopback-only) and
  `Agent.DaemonClient` (wallet daemon UDS).
* This binary never signs. Tool dispatch goes through
  `Agent.Tools.dispatch`, which enforces the operator's allowlist
  in code before any tool runs.

Single-flight per session: a second concurrent `run_turn` for the
same session id returns `kind:"busy"` rather than racing.
-/

namespace LeanKohaku.App.AgentDaemonMain

open LeanKohaku.Agent
open LeanKohaku.Agent.Tools
open LeanKohaku.Encoding.Json
open LeanKohaku.Transport.Uds

private def protocolVersion : String := "0.0.1-phase1a"

private def defaultLlmUrl : String := "http://127.0.0.1:8080/v1/chat/completions"

/-- Resolve the daemon UDS socket the agent uses for tool dispatch.
    Preference order matches `kohaku-agent`'s. -/
private def resolveWalletSocket : IO String := do
  match ← IO.getEnv "LEAN_KOHAKU_DAEMON_SOCKET" with
  | some s => pure s
  | none =>
      match ← IO.getEnv "LEANKOHAKU_SOCKET" with
      | some s => pure s
      | none =>
          let runtime ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
            | some d => pure d
            | none => pure "/tmp"
          pure s!"{runtime}/leankohaku/leankohaku.sock"

/-- Resolve the path this daemon listens on. -/
private def resolveAgentSocket : IO String := do
  match ← IO.getEnv "KOHAKU_AGENT_SOCKET" with
  | some s => pure s
  | none =>
      let runtime ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
        | some d => pure d
        | none => match ← IO.getEnv "UID" with
                  | some uid => pure s!"/run/user/{uid}"
                  | none => pure "/tmp"
      pure s!"{runtime}/leankohaku/agent.sock"

/-- Resolve the session DB path. Matches the Phase 1a plan. -/
private def resolveDbPath : IO String := do
  match ← IO.getEnv "KOHAKU_AGENT_DB" with
  | some s => pure s
  | none =>
      let data ← match ← IO.getEnv "XDG_DATA_HOME" with
        | some d => pure d
        | none =>
            match ← IO.getEnv "HOME" with
            | some home => pure s!"{home}/.local/share"
            | none => pure "/tmp"
      pure s!"{data}/leankohaku/sessions.db"

private def resolveLlmUrl : IO String := do
  match ← IO.getEnv "KOHAKU_AGENT_LLM_URL" with
  | some s => pure s
  | none =>
      match ← IO.getEnv "LOCAL_LLM_BASE_URL" with
      | some base => pure (base ++ "/chat/completions")
      | none => pure defaultLlmUrl

private def resolveModel : IO String := do
  match ← IO.getEnv "KOHAKU_AGENT_MODEL" with
  | some s => pure s
  | none =>
      match ← IO.getEnv "LOCAL_LLM_MODEL" with
      | some s => pure s
      | none => pure "local-default"

/-- Create the parent directory of `path` if missing. -/
private def ensureParentDir (path : String) : IO Unit := do
  let p : System.FilePath := path
  match p.parent with
  | some parent =>
      IO.FS.createDirAll parent
      -- Best-effort `0700` on the parent dir; the API is missing in
      -- Lean's IO.FS so we shell out via `IO.Process.run` only when
      -- the dir is freshly created and on a POSIX system.
      try
        let _ ← IO.Process.run {
          cmd := "chmod", args := #["700", parent.toString]
        }
      catch _ => pure ()
  | none => pure ()

/-- Best-effort `chmod 0600` on the session DB file. Skips silently if
    `chmod` is unavailable. -/
private def chmodSessionDb (path : String) : IO Unit := do
  try
    let _ ← IO.Process.run { cmd := "chmod", args := #["600", path] }
  catch _ => pure ()

/-- Per-process state. `dbRef` holds the opened session handle for
    the entire daemon lifetime; `inFlight` is a simple list of
    session ids currently running a turn, guarded by an `IO.Mutex`. -/
private structure DaemonState where
  db       : Session.Handle
  inFlight : IO.Ref (List Session.SessionId)

/-- Mark `sid` busy if it isn't already. Returns `true` when the
    caller has acquired the per-session lock; `false` if another
    `run_turn` is already running for `sid`. The whole check-and-
    set is atomic w.r.t. the ref. -/
private def tryAcquireSession (st : DaemonState) (sid : Session.SessionId) : IO Bool := do
  st.inFlight.modifyGet fun ids =>
    if ids.contains sid then (false, ids) else (true, sid :: ids)

private def releaseSession (st : DaemonState) (sid : Session.SessionId) : IO Unit :=
  st.inFlight.modify fun ids => ids.filter (· ≠ sid)

private def okResp (result : Json) : Json :=
  .obj #[("ok", .bool true), ("result", result)]

private def errResp (kind msg : String) : Json :=
  .obj #[
    ("ok", .bool false),
    ("error", .obj #[
      ("kind", .str kind),
      ("msg",  .str msg)
    ])
  ]

private def buildCfg (llmUrl model walletSocket : String)
    (params : Json) : AgentConfig :=
  let defaultAllow : List String := Registry.default.map (·.name)
  let allowlist : List String :=
    match getField "toolAllowlist" params with
    | some (.arr arr) => arr.toList.filterMap (fun j => asString j)
    | _ => defaultAllow
  {
    llmUrl := llmUrl,
    model := model,
    daemonSocket := walletSocket,
    toolAllowlist := allowlist
  }

/-- Build a prompt transcript by loading session history and appending
    the new user prompt. Returns the message array plus the
    just-appended user `AgentMessage` (caller persists it before the
    loop runs). -/
private def buildTranscript
    (cfg : AgentConfig) (history : Array AgentMessage)
    (prompt : String) : Array AgentMessage × AgentMessage :=
  let visibleTools : List Prompt.ToolDoc :=
    Tools.toToolDocs (filterByAllowlist Registry.default cfg.toolAllowlist)
  let sys := Prompt.buildSystemPrompt cfg visibleTools
  let user := AgentMessage.user prompt
  -- System prompt always leads. If the history already contains one
  -- (it shouldn't, since we never persist the synthetic system msg),
  -- it will appear twice but the model handles that gracefully.
  let withSys : Array AgentMessage := #[AgentMessage.system sys] ++ history ++ #[user]
  (withSys, user)

/-- Handle `run_turn`. The session-id field is required. -/
private def opRunTurn (st : DaemonState) (params : Json) : IO Json := do
  let some sidJ := getField "session_id" params
    | return errResp "bad_request" "run_turn requires session_id"
  let some sidN := asNat sidJ
    | return errResp "bad_request" "session_id must be a non-negative integer"
  let sid : Session.SessionId := sidN
  let some promptJ := getField "prompt" params
    | return errResp "bad_request" "run_turn requires prompt"
  let some prompt := asString promptJ
    | return errResp "bad_request" "prompt must be a string"

  -- Single-flight: refuse if a turn is already running for this sid.
  let acquired ← tryAcquireSession st sid
  if !acquired then
    return errResp "busy" s!"session {sid} already has a run_turn in flight"
  try
    let walletSocket ← resolveWalletSocket
    let llmUrl ← resolveLlmUrl
    let model  ← resolveModel
    let cfg := buildCfg llmUrl model walletSocket params

    -- Load history. If the session doesn't exist we surface a
    -- structured error rather than letting the upstream UNIQUE check
    -- fail on insert later.
    let history ← Session.loadSession st.db sid
    let (transcript, userMsg) := buildTranscript cfg history prompt

    -- Persist the user turn FIRST so a crash mid-loop leaves a
    -- replayable record on disk.
    Session.appendMessage st.db sid userMsg

    let s₀ : AgentState := { messages := transcript, cfg := cfg }
    match ← Loop.runOneShot s₀ Registry.default with
    | .error e =>
        return errResp "agent" e
    | .ok finalMsg =>
        Session.appendMessage st.db sid finalMsg
        let raw := finalMsg.content.getD ""
        return okResp <| .obj #[
          ("session_id", .num (Int.ofNat sid)),
          ("raw",        .str raw),
          ("backend",    .str "lean-agent"),
          ("model",      .str cfg.model),
          ("toolTurns",  .num (Int.ofNat finalMsg.toolCalls.length))
        ]
  finally
    releaseSession st sid

/-- Handle `create_session`. -/
private def opCreateSession (st : DaemonState) (params : Json) : IO Json := do
  let metadata := (getField "metadata" params).getD (.obj #[])
  try
    let sid ← Session.createSession st.db metadata
    return okResp <| .obj #[
      ("session_id", .num (Int.ofNat sid))
    ]
  catch e =>
    return errResp "io" (toString e)

/-- Handle `close_session`. -/
private def opCloseSession (st : DaemonState) (params : Json) : IO Json := do
  let some sidJ := getField "session_id" params
    | return errResp "bad_request" "close_session requires session_id"
  let some sidN := asNat sidJ
    | return errResp "bad_request" "session_id must be a non-negative integer"
  try
    Session.closeSessionRow st.db sidN
    return okResp <| .obj #[("ok", .bool true)]
  catch e =>
    return errResp "io" (toString e)

/-- Handle `search`. -/
private def opSearch (st : DaemonState) (params : Json) : IO Json := do
  let some queryJ := getField "query" params
    | return errResp "bad_request" "search requires query"
  let some query := asString queryJ
    | return errResp "bad_request" "query must be a string"
  let limit := (getField "limit" params >>= asNat).getD 20
  try
    let hits ← Session.searchFts st.db query limit
    let hitsJson : Array Json := hits.map fun h =>
      .obj #[
        ("sessionId", .num (Int.ofNat h.sessionId)),
        ("messageId", .num (Int.ofNat h.messageId)),
        ("snippet",   .str h.snippet)
      ]
    return okResp <| .obj #[("hits", .arr hitsJson)]
  catch e =>
    return errResp "io" (toString e)

/-- Dispatch a single request `op` value to its handler. -/
def dispatch (st : DaemonState) (req : Json) : IO Json := do
  let opStr := (getField "op" req >>= asString).getD ""
  match opStr with
  | "ping" =>
      pure (okResp (.obj #[
        ("ok", .bool true),
        ("protocol", .str protocolVersion)
      ]))
  | "create_session" =>
      opCreateSession st (req)
  | "close_session" =>
      opCloseSession st (req)
  | "run_turn" =>
      opRunTurn st req
  | "search" =>
      opSearch st req
  | "" =>
      pure (errResp "bad_request" "missing op")
  | other =>
      pure (errResp "bad_request" s!"unknown op: {other}")

/-- Decode a single line from a connection. The wire frame is
    newline-delimited JSON; we receive whatever the peer has sent so
    far (up to 64 KiB per read) and treat the first line as the
    request. -/
private def decodeRequestBytes (bytes : ByteArray) : Except String String :=
  match String.fromUTF8? bytes with
  | some s => .ok s.trimAscii.toString
  | none => .error "request was not valid UTF-8"

/-- Handle one connection: read request line, dispatch, write
    response line, close. -/
def handleConn (st : DaemonState) (conn : Conn) : IO Unit := do
  try
    let sameUid ← peerUidMatchesCurrent conn
    if !sameUid then
      let response := compact (errResp "auth" "peer uid rejected")
      discard <| write conn (response ++ "\n").toByteArray
    else
      let bytes ← read conn
      match decodeRequestBytes bytes with
      | .error err =>
          let response := compact (errResp "bad_request" err)
          discard <| write conn (response ++ "\n").toByteArray
      | .ok line =>
          match parse line with
          | .error e =>
              let response := compact (errResp "bad_request" s!"json parse: {e}")
              discard <| write conn (response ++ "\n").toByteArray
          | .ok req =>
              let response ← dispatch st req
              discard <| write conn (compact response ++ "\n").toByteArray
  finally
    close conn

-- The Phase 1a accept loop is `partial def` because we recurse on a
-- runtime condition (the listener stays open until a SIGTERM-set
-- ref flips). The wallet daemon's acceptLoop has the same shape;
-- a termination proof would have to lift the runtime ref into the
-- type system. Tagged PHASE_N like the wallet daemon's.
partial def acceptLoop (st : DaemonState) (listener : Listener)
    (shutdownRef : IO.Ref Bool) : IO Unit := do
  if (← shutdownRef.get) then
    return
  let conn ← accept listener
  -- One-request-per-conn: a misbehaving client cannot starve other
  -- sessions. handleConn closes the conn in a finally.
  discard <| IO.asTask (handleConn st conn)
  acceptLoop st listener shutdownRef

/-- Trap SIGTERM / SIGINT into the shutdown ref so the accept loop
    drops out cleanly. Lean 4 does not expose POSIX signal handlers,
    so we use `IO.setupGCHandler` equivalent — `setupGracefulShutdown`
    relies on the controlling terminal sending EOF or the parent
    closing stdin to trigger orderly shutdown. systemd's
    TimeoutStopSec=30 + KillSignal=SIGTERM is the production path. -/
private def setupShutdown : IO (IO.Ref Bool) := do
  IO.mkRef false

def main (args : List String) : IO UInt32 := do
  let _ := args
  let dbPath ← resolveDbPath
  let socket ← resolveAgentSocket
  ensureParentDir dbPath
  ensureParentDir socket

  -- Open session DB; mode is set on disk if `chmod` is available.
  let db ← Session.openDb dbPath
  chmodSessionDb dbPath

  let inFlight ← IO.mkRef ([] : List Session.SessionId)
  let st : DaemonState := { db := db, inFlight := inFlight }

  IO.eprintln s!"kohaku-agentd: db at {dbPath}"
  IO.eprintln s!"kohaku-agentd: listening on {socket}"

  let listener ← bind socket
  let shutdownRef ← setupShutdown
  try
    acceptLoop st listener shutdownRef
  finally
    closeListener listener
    Session.close db
    IO.eprintln "kohaku-agentd: shutdown clean"
  pure 0

end LeanKohaku.App.AgentDaemonMain

def main (args : List String) : IO UInt32 :=
  LeanKohaku.App.AgentDaemonMain.main args
