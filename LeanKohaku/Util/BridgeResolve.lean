/-!
# Shared bridge-executable resolver

Every sidecar (`Privacy.Bridge`, `Clearsign.Bridge`, `LlmAgent.Bridge`,
`Colibri.Persistent`) needs to answer the same question at spawn time:
"where on disk is `bridge/<name>/bridge.mjs`?" Each used to ship its own
copy of the lookup logic, which diverged over time — `Colibri.Persistent`
had the most complete fallback chain (env → cwd-walk → recorded
checkout), while `Privacy.Bridge` and `LlmAgent.Bridge` only checked the
exact cwd. That meant a daemon launched outside the checkout (systemd
unit, or any shell where the user `cd`-ed away from the source tree)
silently failed every sidecar except colibri.

This module factors the Colibri pattern into a single helper used by all
four resolvers. The resolution order is:

  1. Explicit env-var override (`envVar`).
  2. Walk upward from the daemon's `IO.currentDir` looking for
     `<ancestor>/<relPath>`. Up to 8 hops. Covers monorepo dev runs.
  3. `$KOHAKU_HOME/checkout` (default `$HOME/.kohaku/checkout`) — a
     marker file `script/kohakuspawn` writes that records the absolute
     path of the checkout it was installed from. Covers systemd-managed
     daemons running with cwd outside the checkout.
  4. `defaultExe` — a PATH-resolved fallback name like
     `leankohaku-clearsign-bridge`. `script/kohakuspawn` installs
     wrapper shims under `$KOHAKU_HOME/bin/` for this case.
-/

namespace LeanKohaku.Util.BridgeResolve

/-- Walk upward from `start` looking for `<dir>/<relPath>`. Returns the
    first match within `maxHops` parents, or `none`. -/
private partial def walkUpward
    (relPath : System.FilePath) (start : System.FilePath) (maxHops : Nat) :
    IO (Option String) := do
  let candidate := start / relPath
  if (← candidate.pathExists) then
    pure (some candidate.toString)
  else
    match maxHops, start.parent with
    | 0, _ => pure none
    | _ + 1, none => pure none
    | n + 1, some parent =>
        if parent == start then pure none else walkUpward relPath parent n

/-- Read the checkout path that `script/kohakuspawn` writes to
    `$KOHAKU_HOME/checkout` (default `$HOME/.kohaku/checkout`) and return
    `<checkout>/<relPath>` if it exists. Both lookups (marker file +
    target script) must succeed; otherwise returns `none`. -/
private def fromRecordedCheckout (relPath : System.FilePath) : IO (Option String) := do
  let kohakuHome ← match (← IO.getEnv "KOHAKU_HOME") with
    | some s => pure (System.FilePath.mk s)
    | none =>
        match (← IO.getEnv "HOME") with
        | some h => pure ((System.FilePath.mk h) / ".kohaku")
        | none   => pure (System.FilePath.mk ".kohaku")
  let indexFile := kohakuHome / "checkout"
  if !(← indexFile.pathExists) then return none
  let raw ← IO.FS.readFile indexFile
  let checkout := System.FilePath.mk raw.trimAscii.toString
  let candidate := checkout / relPath
  if (← candidate.pathExists) then pure (some candidate.toString) else pure none

/-- A "path-like" value is anything that contains a `/`. PATH-resolved
    bare names (e.g. `kohaku-agent`, `leankohaku-clearsign-bridge`) are
    NOT path-like — they're handed straight to `execvp(3)` and resolved
    by libc against `$PATH`, so we must not stat them as filesystem
    paths. Anything with at least one `/` we treat as an absolute or
    relative file path and validate by existence. -/
private def looksLikeFilesystemPath (s : String) : Bool :=
  s.contains '/'

/-- Resolve a sidecar executable. See module-level doc for the resolution
    order. `envVar` is the operator override env-var name (e.g.
    `LEAN_KOHAKU_CLEARSIGN_BRIDGE`). `relPath` is the path under the
    checkout root (e.g. `bridge/clearsign/bridge.mjs`). `defaultExe` is
    the PATH-resolved fallback name (e.g. `leankohaku-clearsign-bridge`).

    Stale-override behavior: when the env override is a filesystem path
    that no longer exists on disk (e.g. a `daemon.env` carrying a
    pre-rename `bridge/llm/bridge.mjs` after the package renamed it to
    `bridge/llm-legacy/`), we emit a one-shot warning to stderr and
    fall through to the normal lookup chain rather than handing the
    spawn a path that will ENOENT. PATH-resolved bare names pass
    through unchanged. -/
def resolveExecutable
    (envVar : String) (relPath : System.FilePath) (defaultExe : String) :
    IO String := do
  match (← IO.getEnv envVar) with
  | some s =>
      if looksLikeFilesystemPath s ∧ !(← System.FilePath.pathExists (System.FilePath.mk s)) then do
        IO.eprintln s!"[{envVar}] override points at missing file ({s}); falling back to default lookup chain"
        let cwd ← IO.currentDir
        match ← walkUpward relPath cwd 8 with
        | some p => pure p
        | none =>
            match ← fromRecordedCheckout relPath with
            | some p => pure p
            | none => pure defaultExe
      else
        pure s
  | none =>
      let cwd ← IO.currentDir
      match ← walkUpward relPath cwd 8 with
      | some p => pure p
      | none =>
          match ← fromRecordedCheckout relPath with
          | some p => pure p
          | none => pure defaultExe

end LeanKohaku.Util.BridgeResolve
