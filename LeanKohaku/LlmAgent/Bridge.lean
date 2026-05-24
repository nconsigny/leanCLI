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
    sidecar at `bridge/llm-legacy/bridge.mjs`. -/
def resolveExecutable : IO String := do
  -- Explicit override wins, regardless of any other knob.
  match ← IO.getEnv "LEAN_KOHAKU_LLM_BRIDGE" with
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
    else if !stdout.trim.isEmpty then
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
            match ← IO.getEnv "UID" with
            | some uid => pure s!"/run/user/{uid}"
            | none => pure "/tmp"
      pure s!"{runtime}/leankohaku/agent.sock"

/-- Send a single newline-delimited JSON frame on `socketPath` and
    read the reply line. The peer is `kohaku-agentd`, which always
    closes the connection after one reply. -/
private def socketCall (socketPath : String) (frame : String) :
    IO (Except String String) := do
  try
    let conn ← LeanKohaku.Transport.Uds.connect socketPath
    try
      let _ ← LeanKohaku.Transport.Uds.write conn (frame ++ "\n").toByteArray
      -- One read is sufficient because the peer's response is a
      -- single line followed by close. If the response exceeds 64 KiB
      -- we'd need to loop; Phase 1a runs short reply shapes.
      let bytes ← LeanKohaku.Transport.Uds.read conn
      let txt := String.fromUTF8! bytes
      pure (.ok txt.trimAscii.toString)
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
      -- Create a fresh session per call (Phase 1a divergence — see
      -- docs/PHASE1A_PLAN.md). The session is closed implicitly by
      -- the daemon's lifecycle; Phase 1d will thread the session_id
      -- through chat.draft so the wallet daemon can reuse one
      -- session across many turns.
      let prompt :=
        (getField "prompt" req.params >>= asString).getD ""
      if prompt.isEmpty then
        return Response.crash "llm.parseIntent: missing prompt" 0
      let metadataJson : Json :=
        match getField "chainId" req.params with
        | some j => .obj #[("chainId", j)]
        | none   => .obj #[]
      let createFrame : String :=
        compact <| .obj #[
          ("op", .str "create_session"),
          ("metadata", metadataJson)
        ]
      match ← socketCall sock createFrame with
      | .error e => return Response.crash s!"agentd create_session: {e}" 0
      | .ok line =>
          match parse line with
          | .error e => return Response.crash s!"agentd create_session parse: {e}: {line}" 0
          | .ok (.obj fields) =>
              let okBool := fields.findSome? (fun (k, v) =>
                if k = "ok" then some v else none)
              match okBool with
              | some (Json.bool true) =>
                  let result := (fields.findSome? (fun (k, v) =>
                    if k = "result" then some v else none)).getD .null
                  let sid := (getField "session_id" result >>= asNat).getD 0
                  if sid == 0 then
                    return Response.crash s!"agentd create_session: no session_id in {line}" 0
                  -- Forward the original params, plus our session_id,
                  -- in the run_turn op. The agentd takes prompt out
                  -- of params; the rest is opaque context.
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
                          -- run_turn replies with the same envelope
                          -- shape as a JSON-RPC response we can pass
                          -- to parseResponse — but the wire here is
                          -- {ok, result} not {jsonrpc, id, result}.
                          -- Translate.
                          match getField "ok" j with
                          | some (.bool true) =>
                              let r := (getField "result" j).getD (.null)
                              pure (Response.ok r)
                          | _ =>
                              let errJ := (getField "error" j).getD (.null)
                              let msg := (getField "msg" errJ >>= asString).getD "agent error"
                              pure (Response.err (-32000) msg none)
              | _ =>
                  return Response.crash s!"agentd create_session not ok: {line}" 0
          | _ => return Response.crash s!"agentd create_session shape: {line}" 0
  | other =>
      pure (Response.crash s!"persistent bridge has no opcode for method: {other}" 0)

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
