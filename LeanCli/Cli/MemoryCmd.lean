import LeanCli.Encoding.Json
import LeanCli.Transport.Uds

/-!
# `leancli memory` CLI subcommands

Four read/write entrypoints that talk to the running `leancli-agentd`
over its UDS socket. The agent daemon is the sole writer of
MEMORY.md (parity with `sessions.db`); the CLI's role is to
assemble new content and POST it via `update_memory`, or to ask
for fresh extraction via `extract_memory`.

Direct file reads happen only as a fallback when the daemon is
unreachable. The on-disk path resolution mirrors the daemon's own
(`LeanCli.Agent.Memory.defaultPath`) — kept in sync by hand,
which is acceptable because the resolution rules rarely change.

This module deliberately does NOT import `LeanCli.Agent.*`: the
CLI surface stays decoupled from the agent's in-process types so
the agent module tree remains a self-contained subsystem.
-/

namespace LeanCli.Cli.MemoryCmd

open LeanCli.Encoding.Json
open LeanCli.Transport.Uds

/-- Minimum length for a `forget` pattern. Refuses anything below
    this to prevent operator-error wipeouts (`leancli memory forget
    "the"` would delete most prose). -/
def forgetMinPatternLen : Nat := 4

/-- Resolve the on-disk MEMORY.md path. Mirrors
    `LeanCli.Agent.Memory.defaultPath`; kept in sync by hand. -/
private def memoryPath : IO System.FilePath := do
  match ← IO.getEnv "LEANCLI_AGENT_MEMORY" with
  | some s => pure (System.FilePath.mk s)
  | none =>
      let data ← match ← IO.getEnv "XDG_DATA_HOME" with
        | some d => pure (System.FilePath.mk d)
        | none =>
            match ← IO.getEnv "HOME" with
            | some h => pure ((System.FilePath.mk h) / ".local" / "share")
            | none => pure (System.FilePath.mk "/tmp")
      pure (data / "leancli" / "MEMORY.md")

/-- Best-effort direct read of MEMORY.md. Returns "" when the
    file does not exist. -/
private def readMemoryFile : IO String := do
  let p ← memoryPath
  if (← p.pathExists) then
    try IO.FS.readFile p catch _ => pure ""
  else pure ""

/-- Drop every line of `content` that contains `pattern`. Returns
    the new string and the count of dropped lines. -/
private def forgetLines (content pattern : String) : String × Nat :=
  let lines := content.splitOn "\n"
  let kept := lines.filter (fun l => (l.splitOn pattern).length = 1)
  let dropped := lines.length - kept.length
  (String.intercalate "\n" kept, dropped)

/-- Resolve the agent socket path. Mirrors the daemon's
    `resolveAgentSocket`. -/
def resolveAgentSocket : IO String := do
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

/-- Send a single newline-delimited JSON frame on `socketPath`
    and read the reply line. -/
private def socketCall (socketPath : String) (frame : String) :
    IO (Except String String) := do
  try
    let conn ← connect socketPath
    try
      let _ ← write conn (frame ++ "\n").toByteArray
      let bytes ← read conn
      let txt := String.fromUTF8! bytes
      pure (.ok txt.trimAscii.toString)
    finally
      close conn
  catch e =>
    pure (.error (toString e))

/-- Parse a `{ok:bool, ...}` envelope. Returns `Except.ok` carrying
    the `result` object on success, `Except.error msg` otherwise. -/
private def decodeEnvelope (raw : String) : Except String Json :=
  match parse raw with
  | .error e => .error s!"agentd reply parse: {e}: {raw}"
  | .ok j =>
      match getField "ok" j with
      | some (.bool true) => .ok ((getField "result" j).getD .null)
      | some (.bool false) =>
          let msg :=
            (getField "error" j >>= getField "msg" >>= asString).getD
              "agent error"
          .error msg
      | _ => .error s!"agentd reply not an envelope: {raw}"

/-- `leancli memory show` — print MEMORY.md to stdout. Reads
    through the daemon's `show_memory` op so we always reflect
    the daemon's live view (which matches the on-disk file
    courtesy of the daemon's atomic writes). -/
def cmdShow : IO UInt32 := do
  let sock ← resolveAgentSocket
  let frame := compact (.obj #[("op", .str "show_memory")])
  match ← socketCall sock frame with
  | .error e =>
      -- Fall back to a direct file read so `memory show` is useful
      -- even when the agentd is down.
      IO.eprintln s!"warning: agentd unreachable ({e}); reading MEMORY.md directly"
      let raw ← readMemoryFile
      IO.print raw
      pure 0
  | .ok line =>
      match decodeEnvelope line with
      | .error e =>
          IO.eprintln s!"error: {e}"
          pure 2
      | .ok result =>
          let raw := (getField "raw" result >>= asString).getD ""
          IO.print raw
          pure 0

/-- `leancli memory edit` — open MEMORY.md in `$EDITOR` (fallback
    `vi`); on a clean exit, POST the new content to the daemon
    via `update_memory`. -/
def cmdEdit : IO UInt32 := do
  let sock ← resolveAgentSocket
  -- Pull the current content (prefer daemon, fall back to file).
  let initial ← do
    let frame := compact (.obj #[("op", .str "show_memory")])
    match ← socketCall sock frame with
    | .ok line =>
        match decodeEnvelope line with
        | .ok result =>
            pure ((getField "raw" result >>= asString).getD "")
        | .error _ => readMemoryFile
    | .error _ => readMemoryFile
  -- Stage the editable copy under the runtime dir so it inherits
  -- the same mode posture as the socket dir.
  let runtime ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
    | some d => pure d
    | none =>
        match ← IO.getEnv "TMPDIR" with
        | some d => pure d
        | none => pure "/tmp"
  let stageDir : System.FilePath := (System.FilePath.mk runtime) / "leancli"
  try IO.FS.createDirAll stageDir catch _ => pure ()
  -- Suffix the file with the PID for a per-invocation work area;
  -- collisions between concurrent invocations are unlikely but
  -- not impossible without it.
  let stageFile := stageDir / s!"memory.edit.{← IO.Process.getPID}.md"
  IO.FS.writeFile stageFile initial
  let editor ← match ← IO.getEnv "EDITOR" with
    | some e => pure e
    | none => pure "vi"
  let exit ←
    try
      let child ← IO.Process.spawn {
        cmd := editor,
        args := #[stageFile.toString],
        stdin := .inherit, stdout := .inherit, stderr := .inherit
      }
      child.wait
    catch e =>
      IO.eprintln s!"error: failed to launch editor {editor}: {e}"
      pure 2
  if exit ≠ 0 then
    IO.eprintln s!"editor exited with status {exit}; MEMORY.md unchanged"
    try IO.FS.removeFile stageFile catch _ => pure ()
    return 2
  let newContent ← IO.FS.readFile stageFile
  try IO.FS.removeFile stageFile catch _ => pure ()
  if newContent = initial then
    IO.println "memory: no changes"
    return 0
  let frame := compact (.obj #[
    ("op",      .str "update_memory"),
    ("content", .str newContent)
  ])
  match ← socketCall sock frame with
  | .error e =>
      IO.eprintln s!"error: agentd update_memory: {e}"
      pure 2
  | .ok line =>
      match decodeEnvelope line with
      | .error e =>
          IO.eprintln s!"error: {e}"
          pure 2
      | .ok result =>
          let bytes := (getField "bytes" result >>= asNat).getD 0
          let dropped := (getField "dropped" result >>= asNat).getD 0
          let dropTag :=
            if dropped = 0 then "" else s!" ({dropped} line(s) dropped by filter)"
          IO.println s!"memory: updated ({bytes} bytes){dropTag}"
          pure 0

/-- `leancli memory refresh [--session N]` — force-extract from
    the given session, or the latest closed session. -/
def cmdRefresh (sessionId? : Option Nat) : IO UInt32 := do
  let sock ← resolveAgentSocket
  let sid :=
    match sessionId? with
    | some n => n
    | none => 0    -- daemon interprets 0 as "latest closed" (Phase 1d will widen)
  -- For now, an explicit session_id is required because the daemon
  -- does not yet implement "latest closed" resolution.
  if sid = 0 then
    IO.eprintln "memory refresh: --session N is required (Phase 1c does not implement 'latest closed' yet)"
    return 2
  let frame := compact (.obj #[
    ("op",         .str "extract_memory"),
    ("session_id", .num (Int.ofNat sid))
  ])
  match ← socketCall sock frame with
  | .error e =>
      IO.eprintln s!"error: agentd extract_memory: {e}"
      pure 2
  | .ok line =>
      match decodeEnvelope line with
      | .error e =>
          IO.eprintln s!"error: {e}"
          pure 2
      | .ok result =>
          let updated := (getField "updated" result >>= asBool).getD false
          let bytes   := (getField "bytes" result >>= asNat).getD 0
          if updated then
            IO.println s!"memory: refreshed from session {sid} ({bytes} bytes)"
          else
            IO.println s!"memory: extraction returned no update ({bytes} bytes unchanged)"
          pure 0

/-- `leancli memory forget <pattern>` — drop every line containing
    `pattern`. Refuses patterns shorter than
    `forgetMinPatternLen` to prevent over-broad wipes. -/
def cmdForget (pattern : String) : IO UInt32 := do
  if pattern.length < forgetMinPatternLen then
    IO.eprintln s!"memory forget: refusing pattern shorter than {forgetMinPatternLen} chars \
('{pattern}' is {pattern.length})"
    return 2
  let sock ← resolveAgentSocket
  -- Pull current content via the daemon for consistency.
  let initial ← do
    let frame := compact (.obj #[("op", .str "show_memory")])
    match ← socketCall sock frame with
    | .ok line =>
        match decodeEnvelope line with
        | .ok r => pure ((getField "raw" r >>= asString).getD "")
        | .error _ => pure ""
    | .error _ => pure ""
  let (newContent, dropped) := forgetLines initial pattern
  if dropped = 0 then
    IO.println s!"memory: no lines matched '{pattern}'"
    return 0
  let frame := compact (.obj #[
    ("op",      .str "update_memory"),
    ("content", .str newContent)
  ])
  match ← socketCall sock frame with
  | .error e =>
      IO.eprintln s!"error: agentd update_memory: {e}"
      pure 2
  | .ok line =>
      match decodeEnvelope line with
      | .error e =>
          IO.eprintln s!"error: {e}"
          pure 2
      | .ok _ =>
          IO.println s!"memory: removed {dropped} line(s) matching '{pattern}'"
          pure 0

end LeanCli.Cli.MemoryCmd
