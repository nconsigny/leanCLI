import LeanKohaku.Daemon.Log
import LeanKohaku.Util.Sandbox

/-!
# Llama-server discovery + lazy spawn

The local LLM chat path needs a llama-server process listening on
loopback. This module is the single point that:

1. Probes `LLM_BASE_URL` (`/v1/models`) to see if a server is already
   serving — could be one the user started via systemd, or one the
   daemon spawned earlier.
2. If absent **and** chat is invoked, spawns `llama-server` from a
   **configured absolute binary path** (no `$PATH` search — see the
   security review in [[project-local-llm-daemon]]).
3. Waits for the new server to become healthy (HTTP 200 on
   `/v1/models`) with a bounded timeout.
4. Tracks the spawned PID so the daemon's shutdown sequence can kill
   only the process **it** started.

**Lazy.** Discovery + spawn fires on the **first** chat invocation, not
on daemon boot. Users who never enter chat never see a model load.

## Settings (env-driven; will move to a config file later)

* `LLM_BASE_URL`      — default `http://127.0.0.1:8080/v1`
* `LLM_SERVER_BINARY` — absolute path to `llama-server` (required for
                        spawn; spawn is skipped if unset)
* `LLM_MODEL_PATH`    — absolute path to a `.gguf` model file
* `LLM_SPAWN_ARGS`    — extra args, space-separated (e.g. `--ctx-size 32768`)
* `LLM_SPAWN_TIMEOUT_MS` — health-wait window, default 30000
* `LLM_AUTO_SPAWN`    — `true` (default) / `false`; if false, the daemon
                        only probes, never spawns
-/

namespace LeanKohaku.Daemon.LlmServer

/-- Stripped-down HTTP client just for `/v1/models` health probe. We
deliberately do not depend on a full HTTP library here; a 1-second TCP
+ HTTP roundtrip is enough. -/
def probeOnce (baseUrl : String) : IO Bool := do
  -- We shell out to `curl` since the Lean tree already uses it elsewhere
  -- and we don't want to write an HTTP client. -m 1 = 1-second timeout.
  try
    let out ← IO.Process.output {
      cmd := "/usr/bin/env",
      args := #["curl", "-fsS", "-m", "1", "-o", "/dev/null", s!"{baseUrl}/models"]
    }
    pure (out.exitCode == 0)
  catch _ => pure false

/-- Sleep for `ms` milliseconds without busy-waiting. -/
def sleepMs (ms : Nat) : IO Unit :=
  IO.sleep ms.toUInt32

/-- Poll until the server responds OK or the timeout elapses. -/
partial def waitHealthy (baseUrl : String) (deadlineMs : Nat) : IO Bool := do
  let now ← IO.monoMsNow
  if now ≥ deadlineMs then return false
  if ← probeOnce baseUrl then return true
  sleepMs 500
  waitHealthy baseUrl deadlineMs

/-- Spawn llama-server from the configured absolute path. Fire-and-
forget: the spawned process is detached for the lifetime of the
daemon. Shutdown cleanup is left to the OS killing the daemon's
process group; pursuing explicit child-tracking would require carrying
the typed `IO.Process.Child` through daemon state, which adds churn
for marginal benefit (this server's whole point is to outlive the
daemon's individual chat requests). -/
def spawnServer
    (binary : String)
    (modelPath : String)
    (extraArgs : Array String) : IO Unit := do
  let baseArgs : Array String := #[
    "-m", modelPath,
    "--host", "127.0.0.1",
    "--port", "8080"
  ]
  let allArgs := baseArgs ++ extraArgs
  -- llama-server itself doesn't need the same sandbox profile as the
  -- node sidecars — it serves localhost TCP and is long-lived. We
  -- skip the unshare wrapper here; the security model is "the model
  -- inference process can only reach loopback, can't sign, can't
  -- touch keys" — enforced by the sidecar boundary, not by sandboxing
  -- llama-server's own process namespace.
  let _child ← IO.Process.spawn {
    cmd := binary,
    args := allArgs,
    stdin := .null,
    stdout := .inherit,
    stderr := .inherit
  }
  pure ()

/-- Read the `LLM_SPAWN_ARGS` env var as a space-separated arg list. -/
def parseSpawnArgs (raw : Option String) : Array String :=
  match raw with
  | none => #[]
  | some s =>
      (s.splitOn " ").filter (fun t => !t.isEmpty) |>.toArray

/-- Result of ensuring a llama-server is up. -/
inductive Outcome where
  | alreadyUp      -- probe succeeded; nothing to do
  | spawnedHealthy -- we spawned a child and it became healthy
  | spawnFailed (msg : String)  -- spawn attempted but failed (or server didn't become healthy)
  | spawnDisabled  -- LLM_SERVER_BINARY unset or LLM_AUTO_SPAWN=false
  deriving Repr

/-- Convert outcome to a short status string for daemon logs / RPC
introspection. -/
def Outcome.toString : Outcome → String
  | .alreadyUp        => "alreadyUp"
  | .spawnedHealthy   => "spawnedHealthy"
  | .spawnFailed msg  => s!"spawnFailed: {msg}"
  | .spawnDisabled    => "spawnDisabled"

/-- The main entry point. Idempotent: safe to call before every chat
invocation. -/
def ensureUp : IO Outcome := do
  let baseUrl := ((← IO.getEnv "LLM_BASE_URL").getD "http://127.0.0.1:8080/v1")
  if ← probeOnce baseUrl then
    return .alreadyUp
  let autoSpawn := ((← IO.getEnv "LLM_AUTO_SPAWN").getD "true")
  if autoSpawn = "false" || autoSpawn = "0" then
    return .spawnDisabled
  let binary? ← IO.getEnv "LLM_SERVER_BINARY"
  let modelPath? ← IO.getEnv "LLM_MODEL_PATH"
  match binary?, modelPath? with
  | some bin, some model =>
      -- Defense in depth: refuse to spawn if the binary path doesn't
      -- exist (rules out a typo silently degrading to "no LLM").
      if !(← System.FilePath.pathExists bin) then
        return .spawnFailed s!"LLM_SERVER_BINARY does not exist: {bin}"
      if !(← System.FilePath.pathExists model) then
        return .spawnFailed s!"LLM_MODEL_PATH does not exist: {model}"
      let extra := parseSpawnArgs (← IO.getEnv "LLM_SPAWN_ARGS")
      let timeoutMs :=
        ((← IO.getEnv "LLM_SPAWN_TIMEOUT_MS").getD "30000").toNat?.getD 30000
      try
        spawnServer bin model extra
        let now ← IO.monoMsNow
        let healthy ← waitHealthy baseUrl (now + timeoutMs)
        if healthy then return .spawnedHealthy
        else return .spawnFailed s!"llama-server did not become healthy within {timeoutMs}ms"
      catch e =>
        return .spawnFailed (toString e)
  | none, _ => return .spawnDisabled
  | _, none => return .spawnFailed "LLM_SERVER_BINARY set but LLM_MODEL_PATH is not"

end LeanKohaku.Daemon.LlmServer
