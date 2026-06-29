import LeanCli.Agent.State
import LeanCli.Agent.Prompt
import LeanCli.Agent.Tools
import LeanCli.Agent.Registry
import LeanCli.Agent.Loop
import LeanCli.Agent.Trace
import LeanCli.Agent.Session
import LeanCli.Agent.Skills
import LeanCli.Agent.Memory
import LeanCli.Agent.ToolDefs.Protocols
import LeanCli.Agent.ToolDefs.TrustedRegistry
import LeanCli.Encoding.Json
import LeanCli.Transport.Uds

/-!
# `leancli-agentd` — persistent agent daemon

Long-running sibling of `leancli-agent`. Listens on a Unix domain
socket and handles session-scoped chat turns backed by the SQLite
session store in `LeanCli/Agent/Session.lean`. Phase 1a wire
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

## Sticky chat sessions

`acquire_chat_session` returns a session id keyed by `(chainId, sessionKey)`.
`sessionKey` is an opaque caller-supplied string (the TUI uses a
per-chat-open UUID; callers that omit it pass `""`, which collapses to
the legacy single-sticky-session-per-chainId behavior — backward
compatible). The agentd remembers
`((chainId, sessionKey), session_id, estimatedTokens)` for the process
lifetime; the wallet daemon's `chat.draft` path asks for the sticky id
once per turn and the same SQLite-backed session accumulates messages
across many user turns. Once a session crosses `chatTokenBudget` (≈12k
tokens, measured by a `chars/4` heuristic), the next
`acquire_chat_session` call closes the stale session — which triggers
the standard memory-extraction path inside `opCloseSession` — and
hands out a fresh session id.

Two ways the cache rotates out from under a sticky session:

* **Automatic per-open** — the TUI generates a fresh `sessionKey` each
  time the chat screen opens. A previous session keyed by the old
  `sessionKey` is left in the cache until token-budget rollover; the
  new screen gets a fresh session immediately. (Practical upshot: a
  failed swap turn never pollutes the next chat open.)
* **Explicit `/clear`** — the TUI's `/clear` command issues
  `rollover_chat_session({chainId, sessionKey})`, which closes the
  cached session id (running `runExtraction` for non-incognito
  sessions) and removes the cache entry. The TUI then mints a NEW
  `sessionKey` and continues.

Sticky sessions are also how `MEMORY.md` actually grows: a one-shot
`create_session` / `run_turn` / walk-away cycle never accumulates
enough history to clear `autoExtractMinMessages`, so without sticky
sessions every chat turn was extraction-skipped.

Incognito sessions bypass the sticky cache entirely (see the
`incognito` branch in `LlmAgent/Bridge.lean`'s persistent path):
incognito callers create a fresh transient session per turn, are
never cached by chainId, and skip extraction on close. Sticky behavior
would defeat the "leave no trace" guarantee.
-/

namespace LeanCli.App.AgentDaemonMain

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Encoding.Json
open LeanCli.Transport.Uds

private def protocolVersion : String := "0.0.1-phase1a"

private def defaultLlmUrl : String := "http://127.0.0.1:8080/v1/chat/completions"

/-- Resolve the daemon UDS socket the agent uses for tool dispatch.
    Preference order matches `leancli-agent`'s. -/
private def resolveWalletSocket : IO String := do
  match ← IO.getEnv "LEANCLI_DAEMON_SOCKET" with
  | some s => pure s
  | none =>
      match ← IO.getEnv "LEANCLI_SOCKET" with
      | some s => pure s
      | none =>
          let runtime ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
            | some d => pure d
            | none =>
                match ← IO.getEnv "TMPDIR" with
                | some d => pure d
                | none => pure "/tmp"
          pure s!"{runtime}/leancli/leancli.sock"

/-- Resolve the path this daemon listens on. -/
private def resolveAgentSocket : IO String := do
  match ← IO.getEnv "LEANCLI_AGENT_SOCKET" with
  | some s => pure s
  | none =>
      let runtime ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
        | some d => pure d
        | none =>
            -- macOS launchd sets TMPDIR to a per-user mode-0700 dir
            -- under /var/folders/...; treat it as the XDG_RUNTIME_DIR
            -- equivalent before falling back further.
            match ← IO.getEnv "TMPDIR" with
            | some d => pure d
            | none =>
                match ← IO.getEnv "UID" with
                | some uid => pure s!"/run/user/{uid}"
                | none => pure "/tmp"
      pure s!"{runtime}/leancli/agent.sock"

/-- Resolve the session DB path. Matches the Phase 1a plan. -/
private def resolveDbPath : IO String := do
  match ← IO.getEnv "LEANCLI_AGENT_DB" with
  | some s => pure s
  | none =>
      let data ← match ← IO.getEnv "XDG_DATA_HOME" with
        | some d => pure d
        | none =>
            match ← IO.getEnv "HOME" with
            | some home => pure s!"{home}/.local/share"
            | none => pure "/tmp"
      pure s!"{data}/leancli/sessions.db"

private def resolveLlmUrl : IO String := do
  match ← IO.getEnv "LEANCLI_AGENT_LLM_URL" with
  | some s => pure s
  | none =>
      match ← IO.getEnv "LOCAL_LLM_BASE_URL" with
      | some base => pure (base ++ "/chat/completions")
      | none => pure defaultLlmUrl

private def resolveModel : IO String := do
  match ← IO.getEnv "LEANCLI_AGENT_MODEL" with
  | some s => pure s
  | none =>
      match ← IO.getEnv "LOCAL_LLM_MODEL" with
      | some s => pure s
      | none => pure "local-default"

/-- Per-request HTTP timeout (ms) for the LLM call. The default 30s
    in `AgentConfig.timeoutMs` is too tight once the context grows
    past ~8k tokens: prompt eval (~1500 t/s) plus generation
    (~55 t/s) plus tool-loop overhead routinely crosses 30s on a
    local model. 120s leaves real headroom while still bounding
    wedged requests. Tunable via `LEANCLI_AGENT_TIMEOUT_MS` for
    slower hardware or larger contexts; non-numeric values fall
    back to the default. -/
private def resolveTimeoutMs : IO Nat := do
  let dflt : Nat := 120000
  match ← IO.getEnv "LEANCLI_AGENT_TIMEOUT_MS" with
  | none => pure dflt
  | some s =>
      match s.trimAscii.toString.toNat? with
      | some n => pure n
      | none => pure dflt

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
    changes between turns). `none` means seed is locked.

    `chatSessions` maps `(chainId, sessionKey)` → `(session_id, est_tokens)`
    for sticky chat sessions. Each `acquire_chat_session` op consults
    this alist (small, <10 entries in practice) and either reuses an
    under-budget session or rolls it over. A list-of-tuples is
    deliberately preferred over `Std.HashMap` here: the cardinality is
    tiny, `BEq Nat` / `BEq String` is decidable, and `modifyGet` over a
    list keeps the rollover transition atomic w.r.t. the ref without
    pulling in a container type whose internals we do not need to reason
    about.

    `sessionKey` is opaque bookkeeping — the wallet daemon forwards it
    verbatim from the caller (the TUI uses a per-chat-open UUID; a
    caller that omits it gets `""`, which preserves the legacy
    single-sticky-session-per-chainId semantics). It NEVER gates a
    signing decision; ConfirmGate stays the trust anchor. -/
private structure DaemonState where
  db           : Session.Handle
  inFlight     : IO.Ref (List Session.SessionId)
  skills       : ToolDefs.Protocols.RegistryRef
  memoryRef    : IO.Ref Memory.Memory
  incognito    : IO.Ref (List Session.SessionId)
  registryRef  : IO.Ref (Option ToolDefs.TrustedRegistry.Snapshot)
  chatSessions : IO.Ref (List ((Nat × String) × Session.SessionId × Nat))

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

/-- Add `delta` to the token estimate of the sticky-chat cache entry
    that currently holds `sid`. No-op if `sid` is not in the cache
    (e.g. incognito or one-shot transient sessions), so it is safe to
    call unconditionally at the end of every `run_turn`. -/
private def bumpChatSessionTokens
    (st : DaemonState) (sid : Session.SessionId) (delta : Nat) : IO Unit :=
  st.chatSessions.modify fun xs =>
    xs.map fun (key, s', toks) =>
      if s' = sid then (key, s', toks + delta) else (key, s', toks)

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

/-- Read the inbound chainId pin out of `run_turn`'s `params`. The
    wallet daemon's `chat.draft` path forwards its own `chainId` under
    `context.activeChainId` (preferred) or `context.chainId` (legacy);
    `opRunTurn` also accepts a top-level `chainId` for callers that
    plumb it directly. `none` means "no pin was supplied" — keep the
    defaults. -/
private def activeChainIdOf (params : Json) : Option Nat :=
  let ctx := (getField "context" params).getD (.obj #[])
  (getField "activeChainId" ctx >>= asNat)
    |>.orElse (fun _ => getField "chainId" ctx >>= asNat)
    |>.orElse (fun _ => getField "chainId" params >>= asNat)

/-- Parse the daemon-published `amounts` table into `AmountEntry`s. Each
    entry's `base` arrives as a decimal string (JSON numbers truncate
    past 2^53) and is converted back to a `Nat` here; an entry with a
    missing `ref`/`base` or an unparseable `base` is dropped rather than
    coerced, so a malformed table can only ever *shrink* the set of
    amounts the model may reference — never invent one. -/
private def parseAmountTable (params : Json) : List AmountEntry :=
  match getField "amounts" params with
  | some (.arr arr) =>
      arr.toList.filterMap (fun j =>
        match getField "ref" j >>= asString, getField "base" j >>= asString with
        | some ref, some baseStr =>
            match baseStr.toNat? with
            | some baseNat =>
                some {
                  ref      := ref,
                  human    := (getField "human" j >>= asString).getD "",
                  symbol   := (getField "symbol" j >>= asString).getD "",
                  base     := baseNat,
                  decimals := (getField "decimals" j >>= asNat).getD 0
                }
            | none => none
        | _, _ => none)
  | _ => []

private def buildCfg (llmUrl model walletSocket : String) (timeoutMs : Nat)
    (regRef : ToolDefs.Protocols.RegistryRef) (params : Json) : AgentConfig :=
  let defaultAllow : List String := (Registry.defaultWithSkills regRef).map (·.name)
  let allowlist : List String :=
    match getField "toolAllowlist" params with
    | some (.arr arr) => arr.toList.filterMap (fun j => asString j)
    | _ => defaultAllow
  -- Pin the chain whitelist to whatever `chat.draft` told us is active.
  -- Without this pin the default `[1, 11155111]` lets the model pick a
  -- chain — and at 4B params it sometimes picks the wrong one
  -- (mainnet for a Sepolia-configured daemon, observed). A pinned
  -- whitelist + `Tools.dispatch`'s chain_denied envelope force the
  -- model to self-correct on the next turn.
  let whitelist : List Nat :=
    match activeChainIdOf params with
    | some cid => [cid]
    | none     => [1, 11155111]
  {
    llmUrl := llmUrl,
    model := model,
    daemonSocket := walletSocket,
    toolAllowlist := allowlist,
    chainWhitelist := whitelist,
    amountTable := parseAmountTable params,
    timeoutMs := timeoutMs
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

/-- Canonical trusted-registry fetch shared by the create-session prime
    and the per-turn refresh, so the two never disagree on how wide the
    BIP-44 window is.

    We ask for a SINGLE canonical address per unlocked seed — external-
    chain index 0 (`m/44'/60'/0'/0/0`), the same address the TUI wallet
    pane and the regex resolver re-derive. Enumerating the full BIP-44
    window (both chains × N indices) surfaced up to ~10 speculative,
    never-realized addresses for a single unlocked seed; the model then
    reported them as e.g. "11 unlocked EOA slots" even though the wallet
    pane shows one. Realized/labelled sub-accounts still surface via the
    daemon's stored-accounts walk, independent of these params — so the
    LLM sees exactly the accounts the user actually has, no more. -/
private def primeRegistryFetch (socketPath : String) :
    IO (Except String ToolDefs.TrustedRegistry.Snapshot) :=
  ToolDefs.TrustedRegistry.fetchSnapshot socketPath ["m/44'/60'/0'/0"] 1 true

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
        -- Rotation or first-time fill: pull a real snapshot via the
        -- canonical narrow fetch (see `primeRegistryFetch`). One entry
        -- per slot also avoids the `slotDisplayName` collision where the
        -- full BIP-44 window collapsed onto an identical `slot/0` handle.
        match ← primeRegistryFetch socketPath with
        | .error _ => pure cached
        | .ok fresh =>
            if cachedFp != "" && cachedFp != fresh.seedFingerprint then
              IO.eprintln s!"[trusted-registry] seed rotation: {cachedFp} -> {fresh.seedFingerprint}"
            regRef.set (some fresh)
            pure (some fresh)

/-- Build the rebuild callback that produces the next system prompt
    and a `SkillReport` summarising which skills + optional blocks
    were rendered. Reads the live registry, memory ref, and trusted-
    registry snapshot off `st` so a `reload`, `update_memory`, or seed
    rotation between turns propagates immediately. The report is what
    the loop pushes into the per-turn trace as `TraceItem.skills`. -/
private def mkRebuildSystem
    (regRef : ToolDefs.Protocols.RegistryRef)
    (memRef : IO.Ref Memory.Memory)
    (registryRef : IO.Ref (Option ToolDefs.TrustedRegistry.Snapshot))
    (walletSocket : String) :
    AgentState → IO (String × Trace.SkillReport) := fun s => do
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
  let alwaysOnNames : Array String :=
    alwaysOn.map (fun sk => sk.frontmatter.name)
  let triggeredNames : Array String :=
    (triggered.map (fun sk => sk.frontmatter.name)).toArray
  let report : Trace.SkillReport :=
    { alwaysOn := alwaysOnNames,
      triggered := triggeredNames,
      memoryActive := !memoryRendered.isEmpty,
      trustedRegistryActive := !trustedRendered.isEmpty }
  -- Optional one-line stderr trace so operators can see what fired.
  -- Gated behind LEANCLI_LOG_PROMPT so the daemon log does not blow up
  -- on every turn.
  match ← IO.getEnv "LEANCLI_LOG_PROMPT" with
  | some v =>
      if v != "" && v != "0" then
        let names := (alwaysOnNames ++ triggeredNames).toList
        let memTag := if memoryRendered.isEmpty then "no" else "yes"
        let regTag := if trustedRendered.isEmpty then "no" else "yes"
        IO.eprintln s!"[skills] active: {String.intercalate "," names} memory={memTag} trustedRegistry={regTag}"
  | none => pure ()
  let body := Prompt.buildSystemPromptFull s.cfg visibleTools
          memoryRendered trustedRendered alwaysOnRendered triggeredRendered
  pure (body, report)

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
       let timeoutMs ← resolveTimeoutMs
       let cfg := buildCfg llmUrl model walletSocket timeoutMs st.skills params
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
       | .ok (finalMsg, trace) => do
           try appendIfNotIncognito st sid finalMsg
           catch _ => pure ()
           -- Graceful no-raw exit. The loop normally terminates with a
           -- tool_calls-empty assistant turn whose `content` is the
           -- model's final answer. When the model exhausts the
           -- maxSteps budget mid-tool-chain (or for any other reason
           -- emits a tool-calls turn with empty content) we'd
           -- otherwise hand the wallet daemon `raw=""` and trigger the
           -- "no raw field" hard reject. Instead: walk the trace
           -- backwards for the last assistant turn that DID emit
           -- content and synthesize that as the user-visible answer.
           -- `gaveUp` is exposed so downstream layers can render
           -- differently if they want (we don't change rendering in
           -- this commit).
           let rawContent := finalMsg.content.getD ""
           let lastToolName : String :=
             match finalMsg.toolCalls.getLast? with
             | some tc => tc.name
             | none    =>
                 -- Fall back to the latest tool_call seen in the trace.
                 let names : List String :=
                   trace.toList.filterMap fun it =>
                     match it with
                     | Trace.TraceItem.toolCall n _ _ => some n
                     | _ => none
                 names.getLast?.getD "(none)"
           let isMidChain : Bool :=
             rawContent.isEmpty ∧ !finalMsg.toolCalls.isEmpty
           let priorAssistantContent : Option String :=
             trace.toList.reverse.findSome? fun it =>
               match it with
               | Trace.TraceItem.assistant c _ =>
                   if c.isEmpty then none else some c
               | _ => none
           let (raw, gaveUp) : String × Bool :=
             if rawContent.isEmpty then
               match priorAssistantContent with
               | some c => (c, isMidChain)
               | none =>
                   ( s!"(agent ran {s₀.cfg.maxSteps} steps without producing a final answer — last tool: {lastToolName})"
                   , true )
             else
               (rawContent, false)
           -- Phase 1d sticky-session bookkeeping: charge this turn's
           -- prompt + assistant tokens to the chainId-keyed cache.
           -- No-op for sessions not in the cache (incognito + one-shot
           -- transients), so it is safe to call unconditionally.
           let turnTokens := (prompt.length + raw.length) / 4
           bumpChatSessionTokens st sid turnTokens
           -- `trace` rides on the existing chat.draft reply via the
           -- agentd wire (`result.trace`). It is display-only — the
           -- TUI's foldable trace block is the only consumer.
           -- `toolTurns` is preserved for backward compat with older
           -- clients; new clients should prefer counting `tool_call`
           -- items in `trace`.
           pure (okResp <| .obj #[
             ("session_id", .num (Int.ofNat sid)),
             ("raw",        .str raw),
             ("backend",    .str "lean-agent"),
             ("model",      .str cfg.model),
             ("incognito",  .bool incog),
             ("toolTurns",  .num (Int.ofNat finalMsg.toolCalls.length)),
             ("gaveUp",     .bool gaveUp),
             ("trace",      Trace.toJson trace)
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
      match ← primeRegistryFetch walletSocket with
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

/-- Token budget at which a sticky chat session rolls over. Crossing
    the threshold triggers a `close_session` (which calls
    `runExtraction` on non-incognito sessions) and a fresh
    `create_session` on the next `acquire_chat_session`.

    12000 was picked to sit well under a 16k-context local model's
    practical limit while leaving headroom for the system prompt,
    skills, and `MEMORY.md`. The estimator is intentionally cheap
    (sum of `content.length` divided by 4) so the rollover decision
    is O(messages) and FFI-free; tokenization belongs in the LLM
    sidecar, not in the daemon. Worst-case overestimate is ASCII-heavy
    text where the true count is closer to chars/4.5 — that's a
    conservative-rollover direction, which is the right bias. -/
private def chatTokenBudget : Nat := 12000

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
    let timeoutMs ← resolveTimeoutMs
    let cfg := buildCfg llmUrl model walletSocket timeoutMs st.skills (.obj #[])
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
    -- Drop any sticky-chat cache entry pointing at this sid so a later
    -- `acquire_chat_session` on the same chainId allocates a fresh one
    -- rather than handing back a just-closed session.
    st.chatSessions.modify fun xs => xs.filter (fun (_, s', _) => s' ≠ sidN)
    return okResp <| .obj #[
      ("ok",             .bool true),
      ("memoryUpdated",  .bool updated),
      ("incognito",      .bool incog)
    ]
  catch e =>
    return errResp "io" (toString e)

/-- Find the cached `(sessionId, tokens)` entry for the key
    `(chainId, sessionKey)`, if any. The pair is matched structurally
    so callers passing `sessionKey := ""` get the legacy
    per-chainId-only behavior (a cache miss until the same `""` key
    rolls over). -/
private def lookupChatSession (st : DaemonState)
    (chainId : Nat) (sessionKey : String) :
    IO (Option (Session.SessionId × Nat)) := do
  let xs ← st.chatSessions.get
  pure (xs.findSome? (fun ((cid, k), sid, toks) =>
    if cid == chainId ∧ k == sessionKey then some (sid, toks) else none))

/-- Close a stale sticky session: record `closed_at`, run extraction
    (sticky sessions are never incognito, so the gate is unconditional),
    and emit a stderr line summarising the rollover. Mirrors the close
    body inside `opCloseSession` but does not touch the wire response —
    rollover is internal to `acquire_chat_session`. -/
private def rolloverStaleSession
    (st : DaemonState) (sid : Session.SessionId) (tokens : Nat) : IO Unit := do
  try
    Session.closeSessionRow st.db sid
  catch e =>
    IO.eprintln s!"[chat-session] rollover: closeSessionRow raised for {sid}: {toString e}"
  let _ ← runExtraction st sid
  IO.eprintln s!"[chat-session] rolled over session {sid} at ~{tokens} estimated tokens"

/-- Replace the cache entry for `(chainId, sessionKey)` with
    `(sid, tokens)`. Drops any prior entry for the same key (rollover)
    before prepending the new one. Other keys on the same chainId
    survive — that is the whole point of per-`sessionKey` scoping:
    a stale entry from a closed TUI chat does not prevent a freshly
    opened chat on the same chain from getting its own session. -/
private def setChatSession
    (st : DaemonState) (chainId : Nat) (sessionKey : String)
    (sid : Session.SessionId) (tokens : Nat) : IO Unit :=
  st.chatSessions.modify fun xs =>
    ((chainId, sessionKey), sid, tokens) ::
      xs.filter (fun ((cid, k), _, _) => ¬ (cid = chainId ∧ k = sessionKey))

/-- Handle `acquire_chat_session`. Returns a session id sticky-keyed by
    `(chainId, sessionKey)`. `sessionKey` is optional in `params`; when
    absent or empty it falls back to `""`, which preserves the legacy
    single-sticky-session-per-chainId behavior for callers that have
    not yet plumbed a per-open key.

    If the cached session for the key is still under `chatTokenBudget`,
    it is reused and `reused:true` is reported. Otherwise the stale
    session is closed (triggering memory extraction via `runExtraction`)
    and a fresh session is created and cached.

    See this file's top docstring for the rationale (`MEMORY.md` only
    grows when sessions actually close with enough messages, and sticky
    sessions are how that happens). -/
private def opAcquireChatSession (st : DaemonState) (params : Json) : IO Json := do
  let some chainJ := getField "chainId" params
    | return errResp "bad_request" "acquire_chat_session requires chainId"
  let some chainId := asNat chainJ
    | return errResp "bad_request" "chainId must be a non-negative integer"
  let sessionKey : String :=
    (getField "sessionKey" params >>= asString).getD ""
  -- Inspect the cache atomically. We snapshot to a local first so the
  -- creation path below sees a consistent view.
  let cached ← lookupChatSession st chainId sessionKey
  match cached with
  | some (sid, toks) =>
      if toks < chatTokenBudget then
        return okResp <| .obj #[
          ("session_id", .num (Int.ofNat sid)),
          ("reused",     .bool true),
          ("chainId",    .num (Int.ofNat chainId)),
          ("sessionKey", .str sessionKey),
          ("tokens",     .num (Int.ofNat toks))
        ]
      else
        -- Rollover. Close + extract the stale session, then create.
        rolloverStaleSession st sid toks
        try
          let metadata : Json := .obj #[("chainId", .num (Int.ofNat chainId))]
          let newSid ← Session.createSession st.db metadata
          setChatSession st chainId sessionKey newSid 0
          return okResp <| .obj #[
            ("session_id", .num (Int.ofNat newSid)),
            ("reused",     .bool false),
            ("chainId",    .num (Int.ofNat chainId)),
            ("sessionKey", .str sessionKey),
            ("rolledFrom", .num (Int.ofNat sid))
          ]
        catch e =>
          return errResp "io" (toString e)
  | none =>
      try
        let metadata : Json := .obj #[("chainId", .num (Int.ofNat chainId))]
        let newSid ← Session.createSession st.db metadata
        setChatSession st chainId sessionKey newSid 0
        return okResp <| .obj #[
          ("session_id", .num (Int.ofNat newSid)),
          ("reused",     .bool false),
          ("chainId",    .num (Int.ofNat chainId)),
          ("sessionKey", .str sessionKey)
        ]
      catch e =>
        return errResp "io" (toString e)

/-- Handle `rollover_chat_session`. Looks up the cached entry for
    `(chainId, sessionKey)`, closes its session id (triggering
    `runExtraction` on non-incognito sessions, gated by the existing
    `autoExtractMinMessages` floor — a brand-new chat that is
    immediately `/clear`'d will not extract, by design), and removes
    the cache entry.

    Idempotent: when no entry exists, succeeds with
    `result.closed:false` and `wasInCache:false`. The TUI's `/clear`
    command is best-effort and fires this op every time; getting a
    no-op on a stale key is the right shape.

    Trust: this op does not produce calldata and never gates a signing
    decision. It is bookkeeping for the agentd's per-process cache. -/
private def opRolloverChatSession (st : DaemonState) (params : Json) : IO Json := do
  let some chainJ := getField "chainId" params
    | return errResp "bad_request" "rollover_chat_session requires chainId"
  let some chainId := asNat chainJ
    | return errResp "bad_request" "chainId must be a non-negative integer"
  let sessionKey : String :=
    (getField "sessionKey" params >>= asString).getD ""
  let cached ← lookupChatSession st chainId sessionKey
  match cached with
  | none =>
      return okResp <| .obj #[
        ("closed",     .bool false),
        ("wasInCache", .bool false),
        ("chainId",    .num (Int.ofNat chainId)),
        ("sessionKey", .str sessionKey)
      ]
  | some (sid, toks) =>
      -- Drop the cache entry FIRST so a concurrent acquire on the same
      -- key cannot observe the about-to-close session id.
      st.chatSessions.modify fun xs =>
        xs.filter (fun ((cid, k), _, _) => ¬ (cid = chainId ∧ k = sessionKey))
      rolloverStaleSession st sid toks
      return okResp <| .obj #[
        ("closed",     .bool true),
        ("wasInCache", .bool true),
        ("sessionId",  .num (Int.ofNat sid)),
        ("chainId",    .num (Int.ofNat chainId)),
        ("sessionKey", .str sessionKey),
        ("tokens",     .num (Int.ofNat toks))
      ]

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

/-- Handle `update_memory`. Used by `leancli memory edit` and
    `leancli memory forget` — the CLI assembles the new content
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

/-- Parse session metadata JSON if present, return the chainId field if
    it is a non-negative integer. Tolerant: malformed JSON, missing
    field, and a non-numeric chainId all collapse to `none`. -/
private def metadataChainId (metadataJson : String) : Option Nat :=
  if metadataJson.isEmpty then none
  else
    match parse metadataJson with
    | .ok j   => getField "chainId" j >>= asNat
    | .error _ => none

/-- Parse session metadata JSON for a sessionKey string. Same
    tolerance rules as `metadataChainId`. -/
private def metadataSessionKey (metadataJson : String) : Option String :=
  if metadataJson.isEmpty then none
  else
    match parse metadataJson with
    | .ok j   => getField "sessionKey" j >>= asString
    | .error _ => none

/-- True iff the session was tagged `{"incognito": true}` at create
    time. Used to filter history-surface results so a leave-no-trace
    session never appears in `list_sessions` / `get_session` /
    `list_proposed_txs`. -/
private def metadataIsIncognito (metadataJson : String) : Bool :=
  if metadataJson.isEmpty then false
  else
    match parse metadataJson with
    | .ok j   => (getField "incognito" j >>= asBool).getD false
    | .error _ => false

/-- Render a single `SessionMeta` as the wire shape consumed by the
    TUI's history-list view. `chainId` / `sessionKey` are emitted only
    when the on-disk metadata carries them (older rows simply omit). -/
private def sessionMetaToJson (m : Session.SessionMeta) : Json :=
  let mdChain := metadataChainId m.metadataJson
  let mdKey   := metadataSessionKey m.metadataJson
  let chainField : Array (String × Json) :=
    match mdChain with
    | some c => #[("chainId", .num (Int.ofNat c))]
    | none   => #[]
  let keyField : Array (String × Json) :=
    match mdKey with
    | some k => #[("sessionKey", .str k)]
    | none   => #[]
  let promptField : Array (String × Json) :=
    match m.firstUserPrompt with
    | some s => #[("firstUserPrompt", .str s)]
    | none   => #[]
  let lastField : Array (String × Json) :=
    match m.lastTurnAt with
    | some t => #[("lastTurnAt", .num (Int.ofNat t))]
    | none   => #[]
  .obj <| #[
    ("sessionId", .num (Int.ofNat m.sessionId)),
    ("createdAt", .num (Int.ofNat m.createdAt)),
    ("turnCount", .num (Int.ofNat m.turnCount))
  ] ++ chainField ++ keyField ++ promptField ++ lastField

/-- Render a single message row as the wire shape consumed by the
    history-detail view. Mirrors the existing `AgentMessage` shape used
    by the `chat.draft` reply's trace: `role` is a string, `content` is
    a string (possibly empty), `toolCalls` is the raw JSON-encoded
    array (the agent loop's storage format; the TUI parses it the same
    way it parses the live-turn trace). -/
private def messageRowToJson (r : Session.MessageRow) : Json :=
  let toolCallsField : Array (String × Json) :=
    if r.toolCalls.isEmpty then #[]
    else #[("toolCallsJson", .str r.toolCalls)]
  let toolCallIdField : Array (String × Json) :=
    if r.toolCallId.isEmpty then #[]
    else #[("toolCallId", .str r.toolCallId)]
  .obj <| #[
    ("seq",        .num (Int.ofNat r.seq)),
    ("appendedAt", .num (Int.ofNat r.appendedAt)),
    ("role",       .str r.role),
    ("content",    .str r.content)
  ] ++ toolCallsField ++ toolCallIdField

/-- Default `limit` for `list_sessions`. The list view paints fast at
    50; callers wanting more pass it explicitly. -/
private def defaultListSessionsLimit : Nat := 50

/-- Default `limit` for `list_proposed_txs`. Higher than the session
    list because the propose_send index is sparser (one row per signing
    intent, not one per chat turn). -/
private def defaultListProposedTxsLimit : Nat := 100

/-- Handle `list_sessions`. Read-only enumeration of the session store,
    newest-first, with optional `chainId` / `sessionKey` filters that
    are applied AFTER row decode (the filters live inside the
    `metadata` JSON column, not in dedicated columns).

    Incognito sessions never appear in the result — their metadata
    carries `{"incognito": true}` at create time, and this op filters
    them out unconditionally. -/
private def opListSessions (st : DaemonState) (params : Json) : IO Json := do
  let limit : Nat :=
    (getField "limit" params >>= asNat).getD defaultListSessionsLimit
  let chainFilter? : Option Nat := getField "chainId" params >>= asNat
  let keyFilter? : Option String := getField "sessionKey" params >>= asString
  try
    -- Over-fetch when filtering so the post-filter result still tries
    -- to honor `limit`. A 10x multiplier is a cheap safety margin —
    -- 500 rows is still a millisecond-scale read.
    let fetchN := if chainFilter?.isSome ∨ keyFilter?.isSome then limit * 10 else limit
    let rows ← Session.listSessions st.db fetchN
    let filtered : Array Session.SessionMeta := rows.filter fun m =>
      let notIncog := !metadataIsIncognito m.metadataJson
      let chainOk : Bool :=
        match chainFilter? with
        | none => true
        | some c =>
            match metadataChainId m.metadataJson with
            | some c' => c == c'
            | none    => false
      let keyOk : Bool :=
        match keyFilter? with
        | none => true
        | some k =>
            match metadataSessionKey m.metadataJson with
            | some k' => k == k'
            | none    => false
      notIncog ∧ chainOk ∧ keyOk
    let truncated := filtered.extract 0 limit
    let arr : Array Json := truncated.map sessionMetaToJson
    return okResp <| .obj #[("sessions", .arr arr)]
  catch e =>
    return errResp "io" (toString e)

/-- Handle `get_session`. Read-only fetch of one session's full
    transcript, ordered by `seq`. Refuses incognito sessions with a
    structured `kind:"incognito"` error envelope so the TUI can render
    a clear "no rows stored" message. -/
private def opGetSession (st : DaemonState) (params : Json) : IO Json := do
  let some sidJ := getField "session_id" params
    | return errResp "bad_request" "get_session requires session_id"
  let some sidN := asNat sidJ
    | return errResp "bad_request" "session_id must be a non-negative integer"
  try
    -- Find the session in the listing to recover createdAt + metadata.
    -- One extra round-trip avoided by reusing the listing's projection
    -- in the absence of a dedicated single-session helper; the cost is
    -- O(rows in DB) per call but the DB is small and this view is not
    -- a hot path. If listings ever stop fitting in memory, swap to a
    -- targeted `SELECT … WHERE id = ?`.
    let rows ← Session.listSessions st.db 100000
    match rows.find? (·.sessionId = sidN) with
    | none => return errResp "not_found" s!"session {sidN} not found"
    | some sm =>
        if metadataIsIncognito sm.metadataJson then
          return errResp "incognito" "session was incognito; no rows stored"
        let msgs ← Session.loadSessionRows st.db sidN
        let chainField : Array (String × Json) :=
          match metadataChainId sm.metadataJson with
          | some c => #[("chainId", .num (Int.ofNat c))]
          | none   => #[]
        let keyField : Array (String × Json) :=
          match metadataSessionKey sm.metadataJson with
          | some k => #[("sessionKey", .str k)]
          | none   => #[]
        let turns : Array Json := msgs.map messageRowToJson
        return okResp <| .obj <| #[
          ("sessionId", .num (Int.ofNat sidN)),
          ("createdAt", .num (Int.ofNat sm.createdAt)),
          ("turns",     .arr turns)
        ] ++ chainField ++ keyField
  catch e =>
    return errResp "io" (toString e)

/-- A propose_send call extracted from a session's tool-call log. -/
private structure ProposedTx where
  sessionId         : Session.SessionId
  sessionCreatedAt  : Nat
  turnIndex         : Nat
  ts                : Nat
  chainId           : Nat
  to                : String
  value             : String
  data              : String
  sender            : Option String
  summaryFromTool   : Option String

/-- Render a `ProposedTx` as the wire shape consumed by the TUI's
    Transactions tab. `value` and `data` are passed through verbatim
    (hex strings as the model emitted them); the daemon is not in the
    business of re-rendering these for display. -/
private def proposedTxToJson (p : ProposedTx) : Json :=
  let senderField : Array (String × Json) :=
    match p.sender with
    | some s => #[("sender", .str s)]
    | none   => #[]
  let summaryField : Array (String × Json) :=
    match p.summaryFromTool with
    | some s => #[("summaryFromTool", .str s)]
    | none   => #[]
  .obj <| #[
    ("sessionId",        .num (Int.ofNat p.sessionId)),
    ("sessionCreatedAt", .num (Int.ofNat p.sessionCreatedAt)),
    ("turnIndex",        .num (Int.ofNat p.turnIndex)),
    ("ts",               .num (Int.ofNat p.ts)),
    ("chainId",          .num (Int.ofNat p.chainId)),
    ("to",               .str p.to),
    ("value",            .str p.value),
    ("data",             .str p.data)
  ] ++ senderField ++ summaryField

/-- Walk one session's messages, extract every `propose_send` tool
    call, and return a `ProposedTx` per match. Tolerant: a malformed
    `argsJson` (or a row from an older session that emitted a now-
    deprecated shape) is skipped silently rather than failing the
    whole walk. We need both the assistant turn carrying the tool call
    AND the matching tool-result turn (to recover `summary`); the
    walker pairs by tool_call_id, falling back to "no summary" when
    the result is missing. -/
private def extractProposedTxs
    (sid : Session.SessionId) (createdAt : Nat) (rows : Array Session.MessageRow) :
    Array ProposedTx := Id.run do
  -- First pass: build an alist of tool_call_id → summary from the
  -- tool-role rows. We avoid HashMap to keep this build's import
  -- surface tight; the cardinality per session is small (10s).
  let mut summaries : List (String × String) := []
  for r in rows do
    if r.role = "tool" ∧ !r.toolCallId.isEmpty then
      let summary : String :=
        if r.content.isEmpty then ""
        else
          match parse r.content with
          | .ok j =>
              match getField "summary" j with
              | some (.str s) => s
              | _ => r.content
          | .error _ => r.content
      summaries := (r.toolCallId, summary) :: summaries
  -- Second pass: every assistant turn with a non-empty tool_calls
  -- string is parsed for `propose_send` calls. `turnIndex` tracks the
  -- chat-position of the assistant turn so the TUI can jump back to
  -- the right place.
  let mut out : Array ProposedTx := #[]
  let mut turnIdx : Nat := 0
  for r in rows do
    if r.role = "assistant" then
      turnIdx := turnIdx + 1
      if !r.toolCalls.isEmpty then
        match parse r.toolCalls with
        | .ok (.arr arr) =>
            for tc in arr do
              let name := (getField "name" tc >>= asString).getD ""
              if name = "propose_send" then
                let argsStr := (getField "argsJson" tc >>= asString).getD ""
                let id      := (getField "id" tc >>= asString).getD ""
                if !argsStr.isEmpty then
                  match parse argsStr with
                  | .ok argsJ =>
                      let chainId := (getField "chainId" argsJ >>= asNat).getD 0
                      let to      := (getField "to" argsJ >>= asString).getD ""
                      let value   := (getField "value" argsJ >>= asString).getD "0x0"
                      let data    := (getField "data" argsJ >>= asString).getD "0x"
                      let sender  := getField "sender" argsJ >>= asString
                      let summary? : Option String :=
                        (summaries.find? (fun (k, _) => k = id)).map Prod.snd
                      out := out.push {
                        sessionId := sid,
                        sessionCreatedAt := createdAt,
                        turnIndex := turnIdx,
                        ts := r.appendedAt,
                        chainId := chainId,
                        to := to,
                        value := value,
                        data := data,
                        sender := sender,
                        summaryFromTool := summary?
                      }
                  | .error _ => pure ()
                else pure ()
              else pure ()
        | _ => pure ()
  out

/-- Handle `list_proposed_txs`. Walks every non-incognito session,
    extracts every `propose_send` tool call, and returns the merged
    list newest-first. Optional `chainId` filter applies to the
    extracted chainId (the one the model passed to the tool, not the
    session's metadata chainId — the model can target a different
    chain than the chat opened on, and the daemon's chain whitelist
    pins per call). -/
private def opListProposedTxs (st : DaemonState) (params : Json) : IO Json := do
  let limit : Nat :=
    (getField "limit" params >>= asNat).getD defaultListProposedTxsLimit
  let chainFilter? : Option Nat := getField "chainId" params >>= asNat
  try
    let sessions ← Session.listSessions st.db 100000
    let mut all : Array ProposedTx := #[]
    for m in sessions do
      if metadataIsIncognito m.metadataJson then
        pure ()
      else
        try
          let rows ← Session.loadSessionRows st.db m.sessionId
          let txs := extractProposedTxs m.sessionId m.createdAt rows
          all := all ++ txs
        catch _ => pure ()
    -- Sort newest-first by `ts`. `Array.qsort` is in scope without
    -- additional imports; comparison is on `Nat`.
    let sorted := all.qsort (fun a b => a.ts > b.ts)
    let filtered : Array ProposedTx :=
      match chainFilter? with
      | none   => sorted
      | some c => sorted.filter (·.chainId = c)
    let truncated := filtered.extract 0 limit
    let arr : Array Json := truncated.map proposedTxToJson
    return okResp <| .obj #[("txs", .arr arr)]
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
  | "acquire_chat_session" =>
      opAcquireChatSession st req
  | "rollover_chat_session" =>
      opRolloverChatSession st req
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
  | "list_sessions" =>
      opListSessions st req
  | "get_session" =>
      opGetSession st req
  | "list_proposed_txs" =>
      opListProposedTxs st req
  | "" =>
      pure (errResp "bad_request" "missing op")
  | other =>
      pure (errResp "bad_request" s!"unknown op: {other}")

/-- Decode the request line bytes (the wire frame is newline-delimited
    JSON). `readLine` already stripped the trailing `\n`. -/
private def decodeRequestBytes (bytes : ByteArray) : Except String String :=
  match String.fromUTF8? bytes with
  | some s => .ok s.trimAscii.toString
  | none => .error "request was not valid UTF-8"

/-- Body of `handleConn` — read one request line, dispatch, write
    one response line. Extracted so it can be wrapped in a
    `try/catch` that converts any escaping IO error into a
    structured wire frame. -/
private def handleConnBody (st : DaemonState) (conn : Conn) : IO Unit := do
  let sameUid ← peerUidMatchesCurrent conn
  if !sameUid then
    let response := compact (errResp "auth" "peer uid rejected")
    discard <| write conn (response ++ "\n").toByteArray
  else
    -- `readLine` buffers across SOCK_STREAM `read(2)` chunks so a
    -- request the kernel splits doesn't get truncated mid-JSON.
    let bytes ← LeanCli.Transport.Uds.readLine conn
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

/-- Handle one connection: read request line, dispatch, write
    response line, close.

    The dispatch path is wrapped in a `try/catch` that always
    produces a wire response even when a handler raises an IO error
    that escaped its own catch (panic from a C shim, a tool that
    forgot to translate `IO.Error` into `.appError`, etc.). Without
    this arm, an uncaught throw would skip the `write` and the peer
    would observe a closed socket — surfacing on the client as a
    parse error on an empty reply (`unexpected end of JSON input`)
    rather than a structured `kind:"io"` envelope. -/
def handleConn (st : DaemonState) (conn : Conn) : IO Unit := do
  let recover (e : IO.Error) : IO Unit := do
    IO.eprintln s!"[agentd] handleConn raised, returning io error: {toString e}"
    try
      let response := compact (errResp "io" s!"handleConn raised: {toString e}")
      discard <| write conn (response ++ "\n").toByteArray
    catch _ => pure ()
  let body : IO Unit := do
    try
      handleConnBody st conn
    catch e =>
      recover e
  try
    body
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
    `LEANCLI_AGENT_SKILLS_DIR` env override → `$XDG_DATA_HOME/leancli/skills`
    if present → `/usr/share/leancli/skills` (installed location) →
    `<cwd>/skills` (dev mode).  This mirrors the data-home fallback
    `Daemon/SkillsStore.lean` uses for action-skills. -/
private def resolveSkillsDir : IO System.FilePath := do
  match ← IO.getEnv "LEANCLI_AGENT_SKILLS_DIR" with
  | some d => pure d
  | none =>
      let dataHome ← match ← IO.getEnv "XDG_DATA_HOME" with
        | some d => pure (System.FilePath.mk d)
        | none =>
            match ← IO.getEnv "HOME" with
            | some h => pure ((System.FilePath.mk h) / ".local" / "share")
            | none => pure (System.FilePath.mk "/tmp")
      let userDir := dataHome / "leancli" / "skills"
      if (← userDir.pathExists) then pure userDir
      else
        let sysDir : System.FilePath := "/usr/share/leancli/skills"
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
  -- Sticky chat-session cache keyed by `(chainId, sessionKey)`. Populated
  -- lazily by `acquire_chat_session`; rolls a session over once it
  -- crosses `chatTokenBudget` so memory extraction actually fires. The
  -- TUI mints a fresh `sessionKey` per chat open and may `/clear`
  -- explicitly via `rollover_chat_session`.
  let chatSessions ← IO.mkRef
    ([] : List ((Nat × String) × Session.SessionId × Nat))
  let st : DaemonState := {
    db := db, inFlight := inFlight, skills := skillsRef,
    memoryRef := memoryRef, incognito := incognito,
    registryRef := registryRef,
    chatSessions := chatSessions
  }

  IO.eprintln s!"leancli-agentd: db at {dbPath}"
  IO.eprintln s!"leancli-agentd: skills at {skillsDir} ({initialSkills.skills.size} loaded)"
  IO.eprintln s!"leancli-agentd: memory at {memoryPath} ({initialMemory.raw.utf8ByteSize} bytes)"
  IO.eprintln s!"leancli-agentd: listening on {socket}"

  let listener ← bind socket
  let shutdownRef ← setupShutdown
  try
    acceptLoop st listener shutdownRef
  finally
    closeListener listener
    Session.close db
    IO.eprintln "leancli-agentd: shutdown clean"
  pure 0

end LeanCli.App.AgentDaemonMain

def main (args : List String) : IO UInt32 :=
  LeanCli.App.AgentDaemonMain.main args
