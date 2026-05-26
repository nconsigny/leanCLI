import LeanKohaku.Encoding.Json
import LeanKohaku.Util.Sandbox
import LeanKohaku.Util.BridgeResolve
import LeanKohaku.Transport.Uds

/-!
# LLM-agent bridge

Bridges the wallet daemon's `chat.draft` / `llm.parseIntent` path to
one of three LLM backends, selected at call time:

* **Lean-native one-shot** (Phase 0 default) — spawn `kohaku-agent`,
  pass `--rpc <json>`, read one stdout line. Same trust shape as the
  privacy and clearsign bridges.
* **Lean-native persistent** (Phase 1a) — talk to a long-running
  `kohaku-agentd` over its UDS socket; the agent persists session
  history under XDG_DATA_HOME via SQLite.
* **Legacy Node sidecar** (opt-in) — `bridge/llm-legacy/bridge.mjs`,
  selected by `LEAN_KOHAKU_LLM_BRIDGE_LEGACY=1`.

Mode resolution (`resolveMode`):

  1. `LEAN_KOHAKU_AGENT_MODE=oneshot` ⇒ force one-shot.
  2. `LEAN_KOHAKU_AGENT_MODE=persistent` ⇒ force persistent;
     error if the socket is missing.
  3. `LEAN_KOHAKU_LLM_BRIDGE_LEGACY=1` ⇒ legacy Node bridge.
  4. Otherwise: probe the agent socket. If it accepts `ping`, use
     persistent; else one-shot.

The Lean daemon is the trusted policy enforcer; every backend is
treated as a thin transport over an untrusted process. Every draft
the bridge emits flows through the existing decode → simulate →
user-confirm gate before any signing happens.

This module is the **only** place that talks to the llm backend.
-/

namespace LeanKohaku.LlmAgent.Bridge

open LeanKohaku.Encoding.Json

def defaultExecutable : String := "kohaku-agent"

/-- Phase 0: the Lean-native `kohaku-agent` executable is the default
    backend. `LEAN_KOHAKU_LLM_BRIDGE` still overrides everything (used
    by integration tests and operators pinning a custom binary).
    `LEAN_KOHAKU_LLM_BRIDGE_LEGACY=1` opts back into the legacy Node
    sidecar at `bridge/llm-legacy/bridge.mjs`.

    Stale-override safety: an explicit `LEAN_KOHAKU_LLM_BRIDGE` that
    points at a missing filesystem path falls through to the default
    lookup. This catches stale `daemon.env` files carrying a
    pre-rename `bridge/llm/bridge.mjs` after the package moved to
    `bridge/llm-legacy/`. PATH-resolved bare names (e.g.
    `kohaku-agent`) pass through unchanged. -/
def resolveExecutable : IO String := do
  let overrideOk? : IO (Option String) := do
    match ← IO.getEnv "LEAN_KOHAKU_LLM_BRIDGE" with
    | none => pure none
    | some s =>
        if s.contains '/' ∧ !(← System.FilePath.pathExists (System.FilePath.mk s)) then do
          IO.eprintln s!"[LEAN_KOHAKU_LLM_BRIDGE] override points at missing file ({s}); falling back to default lookup chain"
          pure none
        else
          pure (some s)
  match ← overrideOk? with
  | some s => pure s
  | none =>
      let useLegacy : Bool ← do
        match ← IO.getEnv "LEAN_KOHAKU_LLM_BRIDGE_LEGACY" with
        | some v =>
            let t := v.trimAscii.toString
            pure (t ≠ "" && t ≠ "0")
        | none => pure false
      if useLegacy then
        LeanKohaku.Util.BridgeResolve.resolveExecutable
          "LEAN_KOHAKU_LLM_BRIDGE_LEGACY_PATH"
          ("bridge" / "llm-legacy" / "bridge.mjs")
          "leankohaku-llm-bridge"
      else
        -- Lean-native default. The agent is built into the same Lake
        -- project; .lake/build/bin/kohaku_agent (lake's underscore
        -- form) is the dev fallback, and the installed binary is
        -- `kohaku-agent` on PATH (the canonical install name).
        let cwd ← IO.currentDir
        let devCandidate := cwd / ".lake" / "build" / "bin" / "kohaku_agent"
        if (← devCandidate.pathExists) then
          pure devCandidate.toString
        else
          pure defaultExecutable

structure Request where
  method : String
  params : Json
  id     : Nat
  deriving Repr

inductive Response where
  | ok    (result : Json)
  | err   (code : Int) (message : String) (data : Option Json)
  | crash (stderr : String) (exitCode : UInt32)
  deriving Repr

def encodeRequest (req : Request) : String :=
  compact <| .obj #[
    ("jsonrpc", .str "2.0"),
    ("method",  .str req.method),
    ("params",  req.params),
    ("id",      .num (Int.ofNat req.id))
  ]

private def parseResponse (raw : String) : Response :=
  match parse raw.trimAscii.toString with
  | .error e => Response.crash s!"llm returned non-JSON ({e}): {raw}" 0
  | .ok (Json.obj fields) =>
      let lookup (k : String) : Option Json :=
        (fields.find? (fun (key, _) => key == k)).map Prod.snd
      match lookup "error" with
      | some (Json.obj ef) =>
          let code := match (ef.find? (fun (k, _) => k == "code")).map Prod.snd with
            | some (Json.num n) => n
            | _ => -32603
          let msg := match (ef.find? (fun (k, _) => k == "message")).map Prod.snd with
            | some (Json.str s) => s
            | _ => "llm bridge error"
          let data := (ef.find? (fun (k, _) => k == "data")).map Prod.snd
          Response.err code msg data
      | _ =>
          match lookup "result" with
          | some j => Response.ok j
          | none => Response.crash s!"llm response missing result: {raw}" 0
  | .ok _ => Response.crash s!"llm response not a JSON object: {raw}" 0

/-- One-shot path: spawn the executable, pipe a single JSON-RPC
    request on argv, read the response from stdout. Phase 0
    behaviour, unchanged. -/
private def callOneShot (req : Request) : IO Response := do
  let exe ← resolveExecutable
  let encoded := encodeRequest req
  try
    -- Sandbox the LLM sidecar. needsTcpLoopback=true keeps the host
    -- network namespace because this sidecar must reach the local
    -- llama-server at 127.0.0.1:8080. The loopback-only URL guard in
    -- bridge/llm/src/clients/ is the policy layer that prevents the
    -- sidecar from reaching anything *but* loopback.
    let (cmd, args) ← LeanKohaku.Util.Sandbox.wrap
      { cmd := exe, args := #["--rpc", encoded], needsTcpLoopback := true }
    let child ← IO.Process.spawn {
      cmd := cmd,
      args := args,
      stdin := .null,
      stdout := .piped,
      stderr := .inherit
    }
    let stdout ← child.stdout.readToEnd
    let exitCode ← child.wait
    if exitCode == 0 then
      pure (parseResponse stdout)
    else if !stdout.trimAscii.toString.isEmpty then
      pure (parseResponse stdout)
    else
      pure (Response.crash s!"llm exited with code {exitCode}" exitCode)
  catch e =>
    pure (Response.crash (toString e) 0)

/-- Resolve the agent UDS socket path. Mirrors
    `kohaku-agentd`'s own `resolveAgentSocket`. -/
private def resolveAgentSocket : IO String := do
  match ← IO.getEnv "KOHAKU_AGENT_SOCKET" with
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
      pure s!"{runtime}/leankohaku/agent.sock"

/-- Send a single newline-delimited JSON frame on `socketPath` and
    read the reply line. The peer is `kohaku-agentd`, which always
    closes the connection after one reply.

    An EOF before any payload (`bytes.isEmpty`) is reported as a
    transport error rather than passed through as an empty string —
    otherwise the downstream `parse` blames the symptom
    (`unexpected end of JSON input`) rather than the cause (the
    peer closed without writing). An invalid-UTF-8 payload is
    treated the same way; we never pass garbage to the JSON
    parser. -/
private def socketCall (socketPath : String) (frame : String) :
    IO (Except String String) := do
  try
    let conn ← LeanKohaku.Transport.Uds.connect socketPath
    try
      let _ ← LeanKohaku.Transport.Uds.write conn (frame ++ "\n").toByteArray
      -- SOCK_STREAM read(2) may return any prefix of what the peer
      -- wrote; `readLine` loops until the terminating `\n` (or EOF) so
      -- a kernel-split reply doesn't silently truncate the JSON and
      -- surface as `unexpected end of JSON input` downstream.
      let bytes ← LeanKohaku.Transport.Uds.readLine conn
      if bytes.isEmpty then
        pure (.error s!"agentd closed socket without writing a reply \
(peer likely crashed mid-handler; check `journalctl -u kohaku-agentd` \
or stderr for `[agentd] handleConn raised`)")
      else
        match String.fromUTF8? bytes with
        | none   => pure (.error s!"agentd reply was not valid UTF-8 \
({bytes.size} bytes)")
        | some s => pure (.ok s.trimAscii.toString)
    finally
      LeanKohaku.Transport.Uds.close conn
  catch e =>
    pure (.error (toString e))

/-- Try a `ping` over the agent socket. Returns `true` iff the
    response is a well-formed `{ok:true,...}` envelope. Used by
    `resolveMode` to autodetect persistent vs one-shot. -/
private def pingAgentSocket (socketPath : String) : IO Bool := do
  match ← socketCall socketPath "{\"op\":\"ping\"}" with
  | .error _ => pure false
  | .ok line =>
      match parse line with
      | .ok (.obj fields) =>
          let ok := fields.findSome? (fun (k, v) =>
            if k = "ok" then some v else none)
          match ok with
          | some (Json.bool true) => pure true
          | _ => pure false
      | _ => pure false

/-- Effective bridge mode for a single call. -/
inductive Mode where
  | oneshot
  | persistent
  | legacy
  deriving Repr, DecidableEq

private def legacySelected : IO Bool := do
  match ← IO.getEnv "LEAN_KOHAKU_LLM_BRIDGE_LEGACY" with
  | none => pure false
  | some v =>
      let t := v.trimAscii.toString
      pure (t ≠ "" && t ≠ "0")

private def explicitMode : IO (Option Mode) := do
  match ← IO.getEnv "LEAN_KOHAKU_AGENT_MODE" with
  | none => pure none
  | some v =>
      match v.trimAscii.toString with
      | "oneshot"   => pure (some Mode.oneshot)
      | "persistent"=> pure (some Mode.persistent)
      | ""          => pure none
      | _           => pure none

/-- Decide the mode for this call. Documented order of preference:
    env override → legacy → socket probe → one-shot. -/
def resolveMode : IO Mode := do
  if ← legacySelected then return Mode.legacy
  match ← explicitMode with
  | some m => return m
  | none =>
      let sock ← resolveAgentSocket
      if (← pingAgentSocket sock) then return Mode.persistent
      else return Mode.oneshot

/-- Build the agent-socket frame for an upstream JSON-RPC request.
    Phase 1a sends one `create_session` (no id is threaded through
    upstream yet) then one `run_turn`. Two RTTs but a single TCP
    connection per RTT keeps the wire shape simple. -/
private def callPersistent (req : Request) : IO Response := do
  let sock ← resolveAgentSocket
  match req.method with
  | "ping" =>
      match ← socketCall sock "{\"op\":\"ping\"}" with
      | .error e => pure (Response.crash s!"agentd transport: {e}" 0)
      | .ok line => pure (parseResponse line)
  | "llm.parseIntent" =>
      -- Phase 1d: non-incognito calls reuse a sticky session keyed by
      -- `chainId` via the agentd's `acquire_chat_session` op. The
      -- agentd holds the (chainId → session_id) mapping for the
      -- process lifetime and rolls the session over once it crosses
      -- ~12k estimated tokens; rollover is what makes
      -- `MEMORY.md`'s auto-extraction fire (a one-shot create + turn
      -- + walk-away cycle never accumulates the message floor).
      --
      -- Incognito calls explicitly bypass the sticky cache and keep
      -- the Phase 1a shape (fresh transient session per turn, no
      -- extraction on close) so the "leave no trace" guarantee
      -- holds.
      let prompt :=
        (getField "prompt" req.params >>= asString).getD ""
      if prompt.isEmpty then
        return Response.crash "llm.parseIntent: missing prompt" 0
      let incognito : Bool ← do
        match ← IO.getEnv "LEAN_KOHAKU_INCOGNITO" with
        | none => pure false
        | some v =>
            let t := v.trimAscii.toString
            pure (t ≠ "" && t ≠ "0")
      let chainIdJ? : Option Json := getField "chainId" req.params
      -- Forward an opaque per-chat-open key from the caller. Missing
      -- or non-string → "". The agentd treats "" as the legacy
      -- single-sticky-session-per-chainId mode so older callers keep
      -- working unchanged. New callers (the TUI's `LlmChatFlow`) mint
      -- a UUID per chat open so a failed turn on one open cannot
      -- pollute the next open on the same chain.
      let sessionKey : String :=
        (getField "sessionKey" req.params >>= asString).getD ""
      -- Acquire the session id. Three branches, all converging on
      -- `sid : Nat`:
      --   1. incognito → fresh transient session via create_session
      --      (no chainId metadata, no incognito-tagged sticky cache).
      --   2. non-incognito with chainId → acquire_chat_session
      --      (passing `sessionKey` for per-open scoping).
      --   3. non-incognito without chainId → fresh transient session,
      --      so callers that have not yet plumbed chainId still work.
      let acquireSid : IO (Except Response Nat) := do
        if incognito then
          let metadataJson : Json :=
            .obj ((match chainIdJ? with
                    | some j => #[("chainId", j)]
                    | none   => #[]) ++ #[("incognito", .bool true)])
          let createFrame : String :=
            compact <| .obj #[
              ("op", .str "create_session"),
              ("metadata", metadataJson)
            ]
          match ← socketCall sock createFrame with
          | .error e =>
              pure (.error (Response.crash s!"agentd create_session: {e}" 0))
          | .ok line =>
              match parse line with
              | .error e =>
                  pure (.error (Response.crash s!"agentd create_session parse: {e}: {line}" 0))
              | .ok j =>
                  match getField "ok" j with
                  | some (.bool true) =>
                      let result := (getField "result" j).getD .null
                      let sid := (getField "session_id" result >>= asNat).getD 0
                      if sid == 0 then
                        pure (.error (Response.crash s!"agentd create_session: no session_id in {line}" 0))
                      else pure (.ok sid)
                  | _ =>
                      pure (.error (Response.crash s!"agentd create_session not ok: {line}" 0))
        else
          match chainIdJ? >>= asNat with
          | some chainId =>
              let frame : String :=
                compact <| .obj #[
                  ("op", .str "acquire_chat_session"),
                  ("chainId", .num (Int.ofNat chainId)),
                  ("sessionKey", .str sessionKey)
                ]
              match ← socketCall sock frame with
              | .error e =>
                  pure (.error (Response.crash s!"agentd acquire_chat_session: {e}" 0))
              | .ok line =>
                  match parse line with
                  | .error e =>
                      pure (.error (Response.crash s!"agentd acquire_chat_session parse: {e}: {line}" 0))
                  | .ok j =>
                      match getField "ok" j with
                      | some (.bool true) =>
                          let result := (getField "result" j).getD .null
                          let sid := (getField "session_id" result >>= asNat).getD 0
                          if sid == 0 then
                            pure (.error (Response.crash s!"agentd acquire_chat_session: no session_id in {line}" 0))
                          else pure (.ok sid)
                      | _ =>
                          pure (.error (Response.crash s!"agentd acquire_chat_session not ok: {line}" 0))
          | none =>
              -- No chainId in params → fall back to transient session
              -- (parity with the pre-1d shape for callers that have
              -- not yet plumbed chainId through to chat.draft).
              let createFrame : String :=
                compact <| .obj #[("op", .str "create_session"), ("metadata", .obj #[])]
              match ← socketCall sock createFrame with
              | .error e =>
                  pure (.error (Response.crash s!"agentd create_session: {e}" 0))
              | .ok line =>
                  match parse line with
                  | .error e =>
                      pure (.error (Response.crash s!"agentd create_session parse: {e}: {line}" 0))
                  | .ok j =>
                      match getField "ok" j with
                      | some (.bool true) =>
                          let result := (getField "result" j).getD .null
                          let sid := (getField "session_id" result >>= asNat).getD 0
                          if sid == 0 then
                            pure (.error (Response.crash s!"agentd create_session: no session_id in {line}" 0))
                          else pure (.ok sid)
                      | _ =>
                          pure (.error (Response.crash s!"agentd create_session not ok: {line}" 0))
      match ← acquireSid with
      | .error resp => return resp
      | .ok sid =>
          let runFrame : String :=
            compact <| .obj <| #[
              ("op", .str "run_turn"),
              ("session_id", .num (Int.ofNat sid)),
              ("prompt", .str prompt),
              ("context", req.params)
            ]
          match ← socketCall sock runFrame with
          | .error e => return Response.crash s!"agentd run_turn: {e}" 0
          | .ok runLine =>
              match parse runLine with
              | .error e => return Response.crash s!"agentd run_turn parse: {e}" 0
              | .ok j =>
                  match getField "ok" j with
                  | some (.bool true) =>
                      let r := (getField "result" j).getD .null
                      pure (Response.ok r)
                  | _ =>
                      let errJ := (getField "error" j).getD .null
                      let msg := (getField "msg" errJ >>= asString).getD "agent error"
                      pure (Response.err (-32000) msg none)
  | other =>
      pure (Response.crash s!"persistent bridge has no opcode for method: {other}" 0)

/-- Close the agentd's sticky-chat cache entry for
    `(chainId, sessionKey)` and trigger memory extraction on the
    closed session id (the agentd's `runExtraction` floor still
    applies — a brand-new session with fewer than
    `autoExtractMinMessages` messages will not extract, which is
    correct for an immediate-on-open `/clear`).

    Mode-aware: only meaningful on `Mode.persistent`. On oneshot or
    legacy bridges this returns a success no-op — there is no sticky
    cache to roll over, and the caller (the wallet daemon's
    `chat.rolloverSession` RPC) should never have to special-case the
    mode.

    Trust: this is bookkeeping. It produces no calldata, never gates
    a signing decision, and ConfirmGate stays the trust anchor. -/
def rolloverChatSession (chainId : Nat) (sessionKey : String) : IO Response := do
  match ← resolveMode with
  | Mode.persistent =>
      let sock ← resolveAgentSocket
      let frame : String :=
        compact <| .obj #[
          ("op", .str "rollover_chat_session"),
          ("chainId", .num (Int.ofNat chainId)),
          ("sessionKey", .str sessionKey)
        ]
      match ← socketCall sock frame with
      | .error e => pure (Response.crash s!"agentd rollover_chat_session: {e}" 0)
      | .ok line =>
          match parse line with
          | .error e => pure (Response.crash s!"agentd rollover_chat_session parse: {e}" 0)
          | .ok j =>
              match getField "ok" j with
              | some (.bool true) =>
                  let r := (getField "result" j).getD .null
                  pure (Response.ok r)
              | _ =>
                  let errJ := (getField "error" j).getD .null
                  let msg := (getField "msg" errJ >>= asString).getD "agent error"
                  pure (Response.err (-32000) msg none)
  | Mode.oneshot | Mode.legacy =>
      -- No sticky cache to roll over in non-persistent modes; report
      -- success with `mode` so the wallet daemon can surface a hint.
      pure (Response.ok (.obj #[
        ("closed",     .bool false),
        ("wasInCache", .bool false),
        ("mode",       .str "non-persistent"),
        ("chainId",    .num (Int.ofNat chainId)),
        ("sessionKey", .str sessionKey)
      ]))

/-- Helper for the read-only history surface: send a single
    pre-built agentd op frame and forward the structured envelope as a
    JSON-RPC `Response`. Mode-aware — non-persistent bridges reject
    with `-32601` because there is no session store to enumerate. -/
private def callHistoryOp (frame : String) : IO Response := do
  match ← resolveMode with
  | Mode.persistent =>
      let sock ← resolveAgentSocket
      match ← socketCall sock frame with
      | .error e => pure (Response.crash s!"agentd transport: {e}" 0)
      | .ok line =>
          match parse line with
          | .error e => pure (Response.crash s!"agentd parse: {e}: {line}" 0)
          | .ok j =>
              match getField "ok" j with
              | some (.bool true) =>
                  let r := (getField "result" j).getD .null
                  pure (Response.ok r)
              | _ =>
                  let errJ := (getField "error" j).getD .null
                  let kind := (getField "kind" errJ >>= asString).getD "agent"
                  let msg  := (getField "msg" errJ >>= asString).getD "agent error"
                  -- Surface the structured kind back to the caller as
                  -- `data.kind` so the TUI can branch on `incognito`
                  -- vs `not_found` vs generic `io` without parsing the
                  -- message.
                  pure (Response.err (-32000) msg
                    (some <| .obj #[("kind", .str kind)]))
  | Mode.oneshot | Mode.legacy =>
      pure (Response.err (-32601) "history available only in persistent mode" none)

/-- Read-only session listing. Forwards `{limit, chainId, sessionKey}`
    (each optional) to the agentd's `list_sessions` op. Wire envelope is
    a `result.sessions` array; see `LeanKohaku/App/AgentDaemonMain.lean`
    for the field set. -/
def listSessions (limit? : Option Nat)
    (chainId? : Option Nat) (sessionKey? : Option String) : IO Response := do
  let limitField : Array (String × Json) :=
    match limit? with
    | some n => #[("limit", .num (Int.ofNat n))]
    | none   => #[]
  let chainField : Array (String × Json) :=
    match chainId? with
    | some n => #[("chainId", .num (Int.ofNat n))]
    | none   => #[]
  let keyField : Array (String × Json) :=
    match sessionKey? with
    | some s => #[("sessionKey", .str s)]
    | none   => #[]
  let frame : String :=
    compact <| .obj <| #[("op", .str "list_sessions")] ++
                       limitField ++ chainField ++ keyField
  callHistoryOp frame

/-- Read-only single-session fetch. Mode-aware. Returns the agentd's
    structured `kind:"incognito"` envelope verbatim (via the
    `Response.err` `data` field) when the session was tagged incognito
    at create time. -/
def getSession (sessionId : Nat) : IO Response := do
  let frame : String :=
    compact <| .obj #[
      ("op", .str "get_session"),
      ("session_id", .num (Int.ofNat sessionId))
    ]
  callHistoryOp frame

/-- Read-only propose_send index. Walks every non-incognito session,
    extracts every `propose_send` tool call, returns newest-first. -/
def listProposedTxs (limit? : Option Nat) (chainId? : Option Nat) :
    IO Response := do
  let limitField : Array (String × Json) :=
    match limit? with
    | some n => #[("limit", .num (Int.ofNat n))]
    | none   => #[]
  let chainField : Array (String × Json) :=
    match chainId? with
    | some n => #[("chainId", .num (Int.ofNat n))]
    | none   => #[]
  let frame : String :=
    compact <| .obj <| #[("op", .str "list_proposed_txs")] ++
                       limitField ++ chainField
  callHistoryOp frame

/-- Dispatch to the chosen mode. Persistent mode that fails to
    contact the agent does NOT silently fall back — an operator who
    asked for persistent would rather see a clear failure than have
    prompts route to a fresh process and lose history. -/
def call (req : Request) : IO Response := do
  match ← resolveMode with
  | Mode.legacy => callOneShot req
  | Mode.persistent =>
      -- Persistent mode was either auto-detected (socket already
      -- pinged ok) or explicitly requested. If we cannot complete
      -- the call, return the structured crash.
      callPersistent req
  | Mode.oneshot => callOneShot req

def responseToJson : Response → Json
  | .ok j => .obj #[("ok", .bool true), ("result", j)]
  | .err code msg data =>
      .obj #[
        ("ok", .bool false),
        ("error", .obj <| #[
          ("code", .num code),
          ("message", .str msg)
        ] ++ (match data with
              | some d => #[("data", d)]
              | none => #[]))
      ]
  | .crash stderr exitCode =>
      .obj #[
        ("ok", .bool false),
        ("crash", .obj #[
          ("stderr", .str stderr),
          ("exitCode", .num (Int.ofNat exitCode.toNat))
        ])
      ]

end LeanKohaku.LlmAgent.Bridge
