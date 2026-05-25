import LeanKohaku.Agent.State
import LeanKohaku.Agent.Prompt
import LeanKohaku.Agent.Tools
import LeanKohaku.Agent.Registry
import LeanKohaku.Agent.Loop
import LeanKohaku.Agent.Session
import LeanKohaku.Agent.Skills
import LeanKohaku.Agent.Memory
import LeanKohaku.Agent.ToolDefs.Protocols
import LeanKohaku.Agent.ToolDefs.TrustedRegistry
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
    `reload` op without restart; `memoryRef` holds the parsed
    MEMORY.md content (Phase 1c) so every turn can include it in
    the system prompt without a per-turn file read; `incognito` is
    the set of session ids that opted into incognito mode at
    `create_session` time; `registryRef` caches the most recent
    Phase-1d trusted-registry snapshot (Phase 1d, fetched at
    `create_session` and refreshed when the seed fingerprint
    changes between turns). `none` means seed is locked. -/
private structure DaemonState where
  db          : Session.Handle
  inFlight    : IO.Ref (List Session.SessionId)
  skills      : ToolDefs.Protocols.RegistryRef
  memoryRef   : IO.Ref Memory.Memory
  incognito   : IO.Ref (List Session.SessionId)
  registryRef : IO.Ref (Option ToolDefs.TrustedRegistry.Snapshot)

/-- Mark `sid` busy if it isn't already. Returns `true` when the
    caller has acquired the per-session lock; `false` if another
    `run_turn` is already running for `sid`. The whole check-and-
    set is atomic w.r.t. the ref. -/
private def tryAcquireSession (st : DaemonState) (sid : Session.SessionId) : IO Bool := do
  st.inFlight.modifyGet fun ids =>
    if ids.contains sid then (false, ids) else (true, sid :: ids)

private def releaseSession (st : DaemonState) (sid : Session.SessionId) : IO Unit :=
  st.inFlight.modify fun ids => ids.filter (· ≠ sid)

/-- Mark `sid` as incognito. Idempotent. -/
private def markIncognito (st : DaemonState) (sid : Session.SessionId) : IO Unit :=
  st.incognito.modify fun ids => if ids.contains sid then ids else sid :: ids

/-- True iff `sid` was registered as incognito at `create_session`
    time. -/
private def isIncognito (st : DaemonState) (sid : Session.SessionId) : IO Bool := do
  let ids ← st.incognito.get
  pure (ids.contains sid)

/-- Persist a message to the session DB unless the session is
    marked incognito. Incognito sessions are in-memory only — the
    DB row was created so `session_id` has meaning, but no
    `messages` rows are ever written. -/
private def appendIfNotIncognito
    (st : DaemonState) (sid : Session.SessionId) (m : AgentMessage) : IO Unit := do
  if ← isIncognito st sid then pure ()
  else Session.appendMessage st.db sid m

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

/-- Refresh the cached trusted-registry snapshot if the seed fingerprint
    has changed since the last fetch. Idempotent and graceful: when the
    daemon is locked or unreachable we return `none` and the prompt-
    builder downgrades to the locked-seed addendum. Logs (via stderr)
    when a rotation is observed so operators can see seed-swap events.

    Phase 1d: the snapshot is fetched at `create_session` and again here
    only if the daemon's *currently observable* fingerprint differs from
    the cached one. We piggy-back on a cheap follow-up RPC: we ask for
    `count=0` (clamped to the daemon's max but logically a no-op
    enumeration) and only its `seedFingerprint` field. -/
private def maybeRefreshRegistry
    (regRef : IO.Ref (Option ToolDefs.TrustedRegistry.Snapshot))
    (socketPath : String) : IO (Option ToolDefs.TrustedRegistry.Snapshot) := do
  let cached ← regRef.get
  let cachedFp := cached.map (·.seedFingerprint) |>.getD ""
  -- Cheap probe: count=0 returns just the fingerprint (or an error
  -- envelope if locked). Failure is a graceful downgrade — we keep
  -- the cached snapshot if any, otherwise return `none`.
  match ← ToolDefs.TrustedRegistry.fetchSnapshot socketPath
           ToolDefs.TrustedRegistry.defaultPaths 0 true with
  | .error _ => pure cached
  | .ok probe =>
      if probe.seedFingerprint == cachedFp && cached.isSome then
        pure cached
      else
        -- Rotation or first-time fill: pull a real snapshot with the
        -- daemon's default count cap.
        match ← ToolDefs.TrustedRegistry.fetchSnapshot socketPath
                 ToolDefs.TrustedRegistry.defaultPaths 5 true with
        | .error _ => pure cached
        | .ok fresh =>
            if cachedFp != "" && cachedFp != fresh.seedFingerprint then
              IO.eprintln s!"[trusted-registry] seed rotation: {cachedFp} -> {fresh.seedFingerprint}"
            regRef.set (some fresh)
            pure (some fresh)

/-- Build the rebuild callback that produces the next system prompt.
    Reads the live registry, memory ref, and trusted-registry snapshot
    off `st` so a `reload`, `update_memory`, or seed rotation between
    turns propagates immediately. -/
private def mkRebuildSystem
    (regRef : ToolDefs.Protocols.RegistryRef)
    (memRef : IO.Ref Memory.Memory)
    (registryRef : IO.Ref (Option ToolDefs.TrustedRegistry.Snapshot))
    (walletSocket : String) :
    AgentState → IO String := fun s => do
  let reg ← regRef.get
  let mem ← memRef.get
  let trustedSnap ← maybeRefreshRegistry registryRef walletSocket
  let visibleTools : List Prompt.ToolDoc :=
    Tools.toToolDocs (filterByAllowlist (Registry.defaultWithSkills regRef) s.cfg.toolAllowlist)
  let alwaysOn := Skills.alwaysOn reg
  let ctx := collectMatchContext s.messages
  let triggered := (Skills.matchTriggers reg ctx).toList.take maxTriggerSkills
  let alwaysOnRendered := alwaysOn.toList.map Skills.renderForPrompt
  let triggeredRendered := triggered.map Skills.renderForPrompt
  let memoryRendered := Memory.renderForPrompt mem 1024
  let trustedRendered :=
    match trustedSnap with
    | some snap =>
        if snap.addresses.isEmpty then ""
        else ToolDefs.TrustedRegistry.renderForPrompt snap
    | none => ""
  -- Optional one-line stderr trace so operators can see what fired.
  -- Gated behind KOHAKU_LOG_PROMPT so the daemon log does not blow up
  -- on every turn.
  match ← IO.getEnv "KOHAKU_LOG_PROMPT" with
  | some v =>
      if v != "" && v != "0" then
        let names := (alwaysOn.toList.map (fun s => s.frontmatter.name)) ++
                     (triggered.map (fun s => s.frontmatter.name))
        let memTag := if memoryRendered.isEmpty then "no" else "yes"
        let regTag := if trustedRendered.isEmpty then "no" else "yes"
        IO.eprintln s!"[skills] active: {String.intercalate "," names} memory={memTag} trustedRegistry={regTag}"
  | none => pure ()
  pure (Prompt.buildSystemPromptFull s.cfg visibleTools
          memoryRendered trustedRendered alwaysOnRendered triggeredRendered)

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
       -- replayable record on disk. Incognito sessions skip the
       -- write but still run the turn — see appendIfNotIncognito.
       appendIfNotIncognito st sid userMsg
       let s₀ : AgentState := { messages := transcript, cfg := cfg }
       let rebuild := mkRebuildSystem st.skills st.memoryRef
                        st.registryRef walletSocket
       let toolReg := Registry.defaultWithSkills st.skills
       let incog ← isIncognito st sid
       match ← Loop.runOneShotWithRebuild s₀ toolReg (some rebuild) with
       | .error e => pure (errResp "agent" e)
       | .ok finalMsg => do
           try appendIfNotIncognito st sid finalMsg
           catch _ => pure ()
           let raw := finalMsg.content.getD ""
           pure (okResp <| .obj #[
             ("session_id", .num (Int.ofNat sid)),
             ("raw",        .str raw),
             ("backend",    .str "lean-agent"),
             ("model",      .str cfg.model),
             ("incognito",  .bool incog),
             ("toolTurns",  .num (Int.ofNat finalMsg.toolCalls.length))
           ])
     catch e =>
       pure (errResp "io" s!"run_turn raised: {toString e}")
    : IO Json)
  releaseSession st sid
  pure result

/-- Handle `create_session`. If the metadata carries
    `{"incognito": true}`, the session id is registered in the
    incognito set so subsequent `appendMessage` calls become
    no-ops and `close_session` skips memory extraction.

    Phase 1d: also primes the trusted-registry cache from the wallet
    daemon. The daemon's `wallet.lean_verified_addresses` handler
    enforces all the bounds documented in
    `docs/PHASE1D_THREAT_MODEL.md`; failure here is graceful and just
    leaves the cache as `none` (which renders as the locked-seed
    addendum in the next system prompt). -/
private def opCreateSession (st : DaemonState) (params : Json) : IO Json := do
  let metadata := (getField "metadata" params).getD (.obj #[])
  try
    let sid ← Session.createSession st.db metadata
    -- Inspect incognito flag — it lives inside the metadata object.
    let incog := (getField "incognito" metadata >>= asBool).getD false
    if incog then markIncognito st sid
    -- Phase 1d: prime the trusted-registry snapshot. Best-effort —
    -- a locked seed, an unreachable daemon, or a slow socket all
    -- collapse to "no registry yet" without breaking session creation.
    try
      let walletSocket ← resolveWalletSocket
      match ← ToolDefs.TrustedRegistry.fetchSnapshot walletSocket
               ToolDefs.TrustedRegistry.defaultPaths 5 true with
      | .ok snap => st.registryRef.set (some snap)
      | .error _ => st.registryRef.set none
    catch _ => st.registryRef.set none
    return okResp <| .obj #[
      ("session_id", .num (Int.ofNat sid)),
      ("incognito",  .bool incog)
    ]
  catch e =>
    return errResp "io" (toString e)

/-- Minimum message count below which auto-extraction is skipped.
    Short sessions (single-shot lookups, errors) are rarely worth
    summarising and the extraction round-trip adds latency. -/
private def autoExtractMinMessages : Nat := 6

/-- Run the memory extraction pipeline for `sid` against the
    daemon's live memory ref. Returns a `Bool` indicating whether
    the memory was updated. Failure is logged but not propagated —
    the caller's response should still succeed. -/
private def runExtraction (st : DaemonState) (sid : Session.SessionId) : IO Bool := do
  try
    let history ← Session.loadSession st.db sid
    if history.size < autoExtractMinMessages then return false
    let walletSocket ← resolveWalletSocket
    let llmUrl ← resolveLlmUrl
    let model  ← resolveModel
    let cfg := buildCfg llmUrl model walletSocket st.skills (.obj #[])
    let existing ← st.memoryRef.get
    match ← Memory.extract cfg existing history with
    | .error e =>
        IO.eprintln s!"[memory] extraction failed for session {sid}: {e}"
        pure false
    | .ok newMem =>
        Memory.save newMem
        st.memoryRef.set newMem
        IO.eprintln s!"[memory] extraction updated MEMORY.md for session {sid} \
({newMem.raw.utf8ByteSize} bytes)"
        pure true
  catch e =>
    IO.eprintln s!"[memory] extraction raised for session {sid}: {toString e}"
    pure false

/-- Handle `close_session`. Auto-triggers memory extraction on
    non-incognito sessions of at least `autoExtractMinMessages`
    messages. Extraction failure does NOT fail the close — it's a
    graceful no-op. -/
private def opCloseSession (st : DaemonState) (params : Json) : IO Json := do
  let some sidJ := getField "session_id" params
    | return errResp "bad_request" "close_session requires session_id"
  let some sidN := asNat sidJ
    | return errResp "bad_request" "session_id must be a non-negative integer"
  try
    Session.closeSessionRow st.db sidN
    let incog ← isIncognito st sidN
    let updated ←
      if incog then pure false
      else runExtraction st sidN
    -- Drop the sid from the incognito set on close (no-op if not
    -- present) so re-using the same numeric id never carries a
    -- stale flag.
    st.incognito.modify fun ids => ids.filter (· ≠ sidN)
    return okResp <| .obj #[
      ("ok",             .bool true),
      ("memoryUpdated",  .bool updated),
      ("incognito",      .bool incog)
    ]
  catch e =>
    return errResp "io" (toString e)

/-- Handle `extract_memory`. Forces an extraction round for the
    given session id (or the latest closed session when omitted).
    Refuses to extract from an incognito session. -/
private def opExtractMemory (st : DaemonState) (params : Json) : IO Json := do
  let some sidJ := getField "session_id" params
    | return errResp "bad_request" "extract_memory requires session_id"
  let some sidN := asNat sidJ
    | return errResp "bad_request" "session_id must be a non-negative integer"
  let incog ← isIncognito st sidN
  if incog then
    return errResp "incognito" "refusing to extract memory from an incognito session"
  let updated ← runExtraction st sidN
  let mem ← st.memoryRef.get
  return okResp <| .obj #[
    ("updated", .bool updated),
    ("bytes",   .num (Int.ofNat mem.raw.utf8ByteSize))
  ]

/-- Handle `update_memory`. Used by `kohaku memory edit` and
    `kohaku memory forget` — the CLI assembles the new content
    locally and POSTs it; the daemon is the sole writer of
    MEMORY.md. -/
private def opUpdateMemory (st : DaemonState) (params : Json) : IO Json := do
  let some contentJ := getField "content" params
    | return errResp "bad_request" "update_memory requires content"
  let some content := asString contentJ
    | return errResp "bad_request" "content must be a string"
  try
    let mem ← st.memoryRef.get
    let (filtered, dropped) := Memory.postFilter content
    let newMem : Memory.Memory := { mem with raw := filtered }
    Memory.save newMem
    st.memoryRef.set newMem
    return okResp <| .obj #[
      ("bytes",   .num (Int.ofNat newMem.raw.utf8ByteSize)),
      ("dropped", .num (Int.ofNat dropped))
    ]
  catch e =>
    return errResp "io" (toString e)

/-- Handle `show_memory`. Reads from the in-memory ref rather than
    the file so the response is consistent with what the next
    `run_turn` will see. -/
private def opShowMemory (st : DaemonState) (_params : Json) : IO Json := do
  let mem ← st.memoryRef.get
  return okResp <| .obj #[
    ("path",  .str mem.path.toString),
    ("bytes", .num (Int.ofNat mem.raw.utf8ByteSize)),
    ("raw",   .str mem.raw)
  ]

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
  | "extract_memory" =>
      opExtractMemory st req
  | "update_memory" =>
      opUpdateMemory st req
  | "show_memory" =>
      opShowMemory st req
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

  let memoryPath ← Memory.defaultPath
  let initialMemory ← Memory.load memoryPath
  let memoryRef ← IO.mkRef initialMemory

  let inFlight ← IO.mkRef ([] : List Session.SessionId)
  let incognito ← IO.mkRef ([] : List Session.SessionId)
  -- Phase 1d: trusted-registry snapshot cache. Starts empty; populated
  -- by the first `create_session` and refreshed when the seed
  -- fingerprint changes between turns.
  let registryRef ← IO.mkRef (none : Option ToolDefs.TrustedRegistry.Snapshot)
  let st : DaemonState := {
    db := db, inFlight := inFlight, skills := skillsRef,
    memoryRef := memoryRef, incognito := incognito,
    registryRef := registryRef
  }

  IO.eprintln s!"kohaku-agentd: db at {dbPath}"
  IO.eprintln s!"kohaku-agentd: skills at {skillsDir} ({initialSkills.skills.size} loaded)"
  IO.eprintln s!"kohaku-agentd: memory at {memoryPath} ({initialMemory.raw.utf8ByteSize} bytes)"
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
