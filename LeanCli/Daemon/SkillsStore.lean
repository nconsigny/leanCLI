import LeanCli.Encoding.Json

/-!
# Skills pack reader

Reads the leancli skills pack at `<project root>/skills/` so the daemon
can list available skills and fetch individual skill bodies.

Skills are markdown files (`SKILL.md`) with YAML frontmatter at the top.
We do **not** parse the YAML strictly — just lift the `name`,
`description`, `category`, `risk` lines as strings — because Lean does
not have a YAML parser and we don't want to depend on one for read-only
introspection.

Layout: `skills/<skill-name>/SKILL.md` per skill plus a top-level
`skills/SKILL.md` as the entry-point manifest.

## Where the skills directory lives

Default: `<cwd>/skills/`. Override with `LEANCLI_SKILLS_DIR`. This
makes the path explicit during dev (just run from the repo root) and
configurable when the binary is installed elsewhere.

## Trust model note

Skills are part of the trusted code base — they ship in the repo and
are reviewed in PRs. They are NOT untrusted user input. So we read them
verbatim without sandboxing. The *output* of an LLM that has been given
a skill in its context is still untrusted; the trust boundary is the
Lean validator, not the skills.
-/

namespace LeanCli.Daemon.SkillsStore

open LeanCli.Encoding.Json

structure SkillMeta where
  name        : String
  description : String
  category    : String
  risk        : String
  path        : String  -- relative path from skills root
  deriving Repr

private def trimLead (s : String) : String :=
  (s.dropWhile (fun c => c == ' ' || c == '\t')).toString

/-- Extract a simple `key: value` line from the YAML frontmatter.
Tolerant: ignores indentation, quotes, and trailing whitespace. -/
private def yamlScalar (lines : List String) (key : String) : Option String :=
  let kw := key ++ ":"
  lines.foldl (fun acc line =>
    match acc with
    | some _ => acc
    | none =>
        let l := trimLead line
        if l.startsWith kw then
          let raw := (l.drop kw.length).toString
          let v := raw.trimAscii.toString
          -- Strip optional surrounding quotes.
          let v := if v.startsWith "\"" && v.endsWith "\"" then
                     ((v.drop 1).dropEnd 1).toString
                   else v
          some v
        else none) none

/-- Pull frontmatter lines from `--- ... ---` at file top. -/
private def frontmatterLines (content : String) : List String :=
  let allLines := content.splitOn "\n"
  match allLines with
  | first :: rest =>
      if first.trimAscii.toString = "---" then
        rest.takeWhile (fun l => l.trimAscii.toString ≠ "---")
      else
        []
  | [] => []

/-- Resolve the skills directory. Env override takes precedence; default
is `<cwd>/skills`. -/
def skillsRoot : IO System.FilePath := do
  match ← IO.getEnv "LEANCLI_SKILLS_DIR" with
  | some d => pure d
  | none => pure ((← IO.currentDir) / "skills")

/-- List all top-level skill directories (entries containing a SKILL.md).
Returns `(name, fullPath)` pairs. Skips the root SKILL.md — that's the
pack manifest, not a leaf skill. -/
def listSkillDirs : IO (List (String × System.FilePath)) := do
  let root ← skillsRoot
  if !(← root.pathExists) then return []
  let entries ← System.FilePath.readDir root
  let mut out : List (String × System.FilePath) := []
  for entry in entries do
    let p := entry.path
    if ← p.isDir then
      let skillFile := p / "SKILL.md"
      if ← skillFile.pathExists then
        out := out ++ [(entry.fileName, p)]
  pure out

/-- Read a skill's frontmatter and return the parsed metadata. Returns
`none` for skills missing required `name` / `description`. -/
def readMeta (dir : System.FilePath) : IO (Option SkillMeta) := do
  let skillFile := dir / "SKILL.md"
  let content ← IO.FS.readFile skillFile
  let fm := frontmatterLines content
  let name ← pure (yamlScalar fm "name")
  let desc ← pure (yamlScalar fm "description")
  match name, desc with
  | some n, some d =>
      pure (some {
        name := n,
        description := d,
        category := (yamlScalar fm "category").getD "uncategorized",
        risk := (yamlScalar fm "risk").getD "unknown",
        path := dir.toString
      })
  | _, _ => pure none

/-- List all skills with metadata. -/
def listAll : IO (List SkillMeta) := do
  let dirs ← listSkillDirs
  let mut out : List SkillMeta := []
  for (_, dir) in dirs do
    match ← readMeta dir with
    | some m => out := out ++ [m]
    | none => pure ()
  pure out

/-- Read the full body of one skill by name. Returns `none` if the
named skill isn't found. -/
def readBody (name : String) : IO (Option String) := do
  let dirs ← listSkillDirs
  match dirs.find? (fun (dirName, _) => dirName = name) with
  | none => pure none
  | some (_, dir) =>
      let f := dir / "SKILL.md"
      let content ← IO.FS.readFile f
      pure (some content)

/-- Read the root manifest (`skills/SKILL.md`). -/
def readRootManifest : IO (Option String) := do
  let root ← skillsRoot
  let f := root / "SKILL.md"
  if ← f.pathExists then
    let content ← IO.FS.readFile f
    pure (some content)
  else pure none

end LeanCli.Daemon.SkillsStore
