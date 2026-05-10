/-!
# `.env` autoloader

Reads `KEY=VALUE` pairs from a dotenv file and surfaces them through
`IO.getEnv` for the rest of the process. Real process env always wins:
the FFI uses `setenv(..., overwrite=0)`, so explicit shell exports are
never silently shadowed by a `.env` line.

Search order at startup:

1. `./.env` in the daemon's CWD (typical `git clone` workflow).
2. `${XDG_CONFIG_HOME:-$HOME/.config}/leankohaku/.env`.

Both are loaded if both exist, with CWD taking precedence (it loads
first; entries already in the env are skipped at the second site).

Disable entirely with `LEANKOHAKU_NO_DOTENV=1`.

The parser is intentionally minimal — no shell expansion, no escape
sequences, no command substitution. Variable expansion in a config file
read by the daemon is a footgun, not a feature.
-/

namespace LeanKohaku.Util.DotEnv

@[extern "lk_setenv_if_absent"]
private opaque setenvIfAbsentRaw (name : @& String) (value : @& String) : IO Unit

/-- Trim leading/trailing ASCII whitespace via the stable `Substring` API,
    which doesn't shift between releases the way `String.trim` did. -/
private def trimS (s : String) : String :=
  s.toSubstring.trim.toString

/-- Strip a single layer of matching surrounding quotes (`"..."` or `'...'`).
    No escape processing — value taken literally between the quotes. -/
private def stripQuotes (s : String) : String :=
  if s.length < 2 then s
  else if (s.startsWith "\"" && s.endsWith "\"") ||
          (s.startsWith "'"  && s.endsWith "'") then
    ((s.drop 1).dropRight 1).toString
  else s

/-- Parse a single `.env` line. Returns `none` for blank lines, comment
    lines, and malformed entries (no `=`, empty key). -/
def parseLine (raw : String) : Option (String × String) :=
  let line := trimS raw
  if line.isEmpty then none
  else if line.startsWith "#" then none
  else
    -- Strip optional `export ` prefix.
    let line :=
      if line.startsWith "export " then trimS (line.drop 7).toString
      else line
    match line.splitOn "=" with
    | [] => none
    | [_] => none
    | k :: rest =>
        let key := trimS k
        if key.isEmpty then none
        else
          -- Re-join everything after the first `=` so values containing
          -- `=` survive parsing intact.
          let value := trimS (String.intercalate "=" rest)
          some (key, stripQuotes value)

/-- Apply every parsed `KEY=VALUE` pair to the process env, skipping any
    that are already set. Errors from `setenv` are non-fatal: we log to
    stderr and continue, since a malformed dotenv must never prevent the
    daemon from starting. -/
def applyLines (path : System.FilePath) (lines : List String) : IO Unit := do
  for line in lines do
    match parseLine line with
    | none => pure ()
    | some (key, value) =>
        try setenvIfAbsentRaw key value
        catch e =>
          IO.eprintln s!"[dotenv] {path}: skipped {key}: {e}"

def loadFile (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then
    try
      let text ← IO.FS.readFile path
      applyLines path (text.splitOn "\n")
    catch e =>
      IO.eprintln s!"[dotenv] {path}: read failed: {e}"

private def configHome : IO String := do
  match ← IO.getEnv "XDG_CONFIG_HOME" with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "HOME" with
      | some home => pure s!"{home}/.config"
      | none => pure "/tmp"

/-- Load `.env` from the standard locations unless `LEANKOHAKU_NO_DOTENV=1`.
    Idempotent: real env wins, so calling twice is a no-op for any key
    populated by the first call. -/
def autoload : IO Unit := do
  match ← IO.getEnv "LEANKOHAKU_NO_DOTENV" with
  | some s =>
      let s := trimS s
      if s = "1" || s.toLower = "true" then return ()
  | none => pure ()
  -- 1) CWD `.env` wins. Loading it first means the user-config site can
  --    never overwrite a CWD entry (setenvIfAbsent skips already-set keys).
  loadFile (System.FilePath.mk ".env")
  -- 2) User config dir.
  let home ← configHome
  loadFile (System.FilePath.mk s!"{home}/leankohaku/.env")

end LeanKohaku.Util.DotEnv
