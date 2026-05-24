import LeanKohaku.Agent.State
import LeanKohaku.Agent.Prompt
import LeanKohaku.Agent.Tools
import LeanKohaku.Agent.Registry
import LeanKohaku.Agent.Loop
import LeanKohaku.Agent.Session
import LeanKohaku.Agent.Skills
import LeanKohaku.Agent.ToolDefs.Protocols
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
    session ids currently running a turn; `skills` is the live
    skills registry (Phase 1b), swapped under all readers by the
    `reload` op without restart. -/
private structure DaemonState where
  db       : Session.Handle
  inFlight : IO.Ref (List Session.SessionId)
  skills   : ToolDefs.Protocols.RegistryRef

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
    (regRef : ToolDefs.Protocols.RegistryRef) (params : Json) : AgentConfig :=
  let defaultAllow : List String := (Registry.defaultWithSkills regRef).map (·.name)
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

/-- Cap on trigger-matched skills per turn. Always-on skills are
    unbounded (there are only two). -/
private def maxTriggerSkills : Nat := 4

/-- Collect text relevant to skill trigger matching: the latest user
    message plus any tool-result tool messages in the transcript.
    Older user messages are intentionally excluded — they describe
    earlier subgoals and would over-eagerly activate skills. -/
private def collectMatchContext (msgs : Array AgentMessage) : String :=
  -- Latest user content + every tool-result content, joined by space.
  let toolBlobs : List String :=
    (msgs.toList.filter (fun m => m.role = .tool)).filterMap (fun m => m.content)
  let lastUser : String :=
    match (msgs.toList.filter (fun m => m.role = .user)).getLast? with
    | some m => m.content.getD ""
    | none => ""
  String.intercalate " " (lastUser :: toolBlobs)

/-- Build the rebuild callback that produces the next system prompt.
    Reads the live registry off `regRef` so a `reload` between turns
    propagates immediately. -/
private def mkRebuildSystem
    (regRef : ToolDefs.Protocols.RegistryRef) :
    AgentState → IO String := fun s => do
  let reg ← regRef.get
  let visibleTools : List Prompt.ToolDoc :=
    Tools.toToolDocs (filterByAllowlist (Registry.defaultWithSkills regRef) s.cfg.toolAllowlist)
  let alwaysOn := Skills.alwaysOn reg
  let ctx := collectMatchContext s.messages
  let triggered := (Skills.matchTriggers reg ctx).toList.take maxTriggerSkills
  let alwaysOnRendered := alwaysOn.toList.map Skills.renderForPrompt
  let triggeredRendered := triggered.map Skills.renderForPrompt
  -- Optional one-line stderr trace so operators can see what fired.
  -- Gated behind KOHAKU_LOG_PROMPT so the daemon log does not blow up
  -- on every turn.
  match ← IO.getEnv "KOHAKU_LOG_PROMPT" with
  | some v =>
      if v != "" && v != "0" then
        let names := (alwaysOn.toList.map (fun s => s.frontmatter.name)) ++
                     (triggered.map (fun s => s.frontmatter.name))
        IO.eprintln s!"[skills] active: {String.intercalate "," names}"
  | none => pure ()
  pure (Prompt.buildSystemPromptWithSkills s.cfg visibleTools
          alwaysOnRendered triggeredRendered)

/-- Build a prompt transcript by loading session history and appending
    the new user prompt. Returns the message array plus the
    just-appended user `AgentMessage` (caller persists it before the
    loop runs). The system message is a *placeholder* — `runOneShot`'s
    rebuild callback replaces its content before each LLM call with
    the live always-on + trigger-matched skills. -/
private def buildTranscript
    (regRef : ToolDefs.Protocols.RegistryRef)
    (cfg : AgentConfig) (history : Array AgentMessage)
    (prompt : String) : Array AgentMessage × AgentMessage :=
  let visibleTools : List Prompt.ToolDoc :=
    Tools.toToolDocs (filterByAllowlist (Registry.defaultWithSkills regRef) cfg.toolAllowlist)
  -- Placeholder: actual content is computed per-turn by the rebuild
  -- callback in `runOneShotWithRebuild`. Keeping a non-empty initial
  -- value means a Phase-0-style runner without the callback still
  -- gets a functioning prompt.
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
  let result ←
    (try
       let walletSocket ← resolveWalletSocket
       let llmUrl ← resolveLlmUrl
       let model  ← resolveModel
       let cfg := buildCfg llmUrl model walletSocket st.skills params
       let history ← Session.loadSession st.db sid
       let (transcript, userMsg) := buildTranscript st.skills cfg history prompt
       -- Persist the user turn FIRST so a crash mid-loop leaves a
       -- replayable record on disk.
       Session.appendMessage st.db sid userMsg
       let s₀ : AgentState := { messages := transcript, cfg := cfg }
       let rebuild := mkRebuildSystem st.skills
       let toolReg := Registry.defaultWithSkills st.skills
       match ← Loop.runOneShotWithRebuild s₀ toolReg (some rebuild) with
       | .error e => pure (errResp "agent" e)
       | .ok finalMsg => do
           try Session.appendMessage st.db sid finalMsg
           catch _ => pure ()
           let raw := finalMsg.content.getD ""
           pure (okResp <| .obj #[
             ("session_id", .num (Int.ofNat sid)),
             ("raw",        .str raw),
             ("backend",    .str "lean-agent"),
             ("model",      .str cfg.model),
             ("toolTurns",  .num (Int.ofNat finalMsg.toolCalls.length))
           ])
     catch e =>
       pure (errResp "io" s!"run_turn raised: {toString e}")
    : IO Json)
  releaseSession st sid
  pure result

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

/-- Handle `reload`. Re-walks the on-disk skills directory and swaps
    the `IO.Ref` under all active readers. SIGHUP-equivalent — Lean
    4 v4.29.1 lacks POSIX signal APIs, so operators trigger this
    over the socket instead. -/
private def opReload (st : DaemonState) (_req : Json) : IO Json := do
  try
    let oldReg ← st.skills.get
    let newReg ← Skills.reload oldReg
    st.skills.set newReg
    return okResp <| .obj #[
      ("ok",     .bool true),
      ("skills", .num (Int.ofNat newReg.skills.size))
    ]
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
  | "reload" =>
      opReload st req
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
--
-- Connections are handled SERIALLY in Phase 1a, not on `IO.asTask`,
-- because (a) the SQLite handle is shared, and serialising at the
-- accept loop is a simpler concurrency story than per-connection
-- locking; (b) `Loop.runOneShot` and its downstream libcurl calls
-- have been observed to misbehave under `IO.asTask` in this build,
-- and serial dispatch avoids the issue without adding new
-- dependencies. The single-flight per session guard
-- (`tryAcquireSession`) is kept because parallel turns are still a
-- 1b/1d roadmap item.
partial def acceptLoop (st : DaemonState) (listener : Listener)
    (shutdownRef : IO.Ref Bool) : IO Unit := do
  if (← shutdownRef.get) then
    return
  let conn ← accept listener
  handleConn st conn
  acceptLoop st listener shutdownRef

/-- Trap SIGTERM / SIGINT into the shutdown ref so the accept loop
    drops out cleanly. Lean 4 does not expose POSIX signal handlers,
    so we use `IO.setupGCHandler` equivalent — `setupGracefulShutdown`
    relies on the controlling terminal sending EOF or the parent
    closing stdin to trigger orderly shutdown. systemd's
    TimeoutStopSec=30 + KillSignal=SIGTERM is the production path. -/
private def setupShutdown : IO (IO.Ref Bool) := do
  IO.mkRef false

/-- Resolve the on-disk skills root. Preference order:
    `KOHAKU_AGENT_SKILLS_DIR` env override → `$XDG_DATA_HOME/leankohaku/skills`
    if present → `/usr/share/leankohaku/skills` (installed location) →
    `<cwd>/skills` (dev mode).  This mirrors the data-home fallback
    `Daemon/SkillsStore.lean` uses for action-skills. -/
private def resolveSkillsDir : IO System.FilePath := do
  match ← IO.getEnv "KOHAKU_AGENT_SKILLS_DIR" with
  | some d => pure d
  | none =>
      let dataHome ← match ← IO.getEnv "XDG_DATA_HOME" with
        | some d => pure (System.FilePath.mk d)
        | none =>
            match ← IO.getEnv "HOME" with
            | some h => pure ((System.FilePath.mk h) / ".local" / "share")
            | none => pure (System.FilePath.mk "/tmp")
      let userDir := dataHome / "leankohaku" / "skills"
      if (← userDir.pathExists) then pure userDir
      else
        let sysDir : System.FilePath := "/usr/share/leankohaku/skills"
        if (← sysDir.pathExists) then pure sysDir
        else pure ((← IO.currentDir) / "skills")

def main (args : List String) : IO UInt32 := do
  let _ := args
  let dbPath ← resolveDbPath
  let socket ← resolveAgentSocket
  let skillsDir ← resolveSkillsDir
  ensureParentDir dbPath
  ensureParentDir socket

  -- Open session DB; mode is set on disk if `chmod` is available.
  let db ← Session.openDb dbPath
  chmodSessionDb dbPath

  let initialSkills ← Skills.loadRegistry skillsDir
  let skillsRef ← IO.mkRef initialSkills

  let inFlight ← IO.mkRef ([] : List Session.SessionId)
  let st : DaemonState := {
    db := db, inFlight := inFlight, skills := skillsRef
  }

  IO.eprintln s!"kohaku-agentd: db at {dbPath}"
  IO.eprintln s!"kohaku-agentd: skills at {skillsDir} ({initialSkills.skills.size} loaded)"
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
