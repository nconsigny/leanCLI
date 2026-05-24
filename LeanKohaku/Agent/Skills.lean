import LeanKohaku.Encoding.Json

/-!
# Agent-side skills registry

Reads the `skills/<name>/` tree at startup and renders compact
context strings for the LLM system prompt. Trigger-keyword matching
lets the agent load only the protocol knowledge relevant to the
current turn, instead of bloating every prompt with all eleven
skills.

This module is intentionally separate from
`LeanKohaku/Daemon/SkillsStore.lean`. The Daemon module exposes
action-skills (verb-named: `send-native`, `approve-erc20`, …) via
the `skills.list` / `skills.get` RPCs. The Agent module reads the
same `skills/` directory but cares about a different frontmatter
shape (`triggers`, `alwaysOn`, `ofacFlagged`) and never reaches the
wire — its consumers are `Agent/Prompt.lean` and the
`protocol_lookup` / `protocol_function_lookup` agent tools.

## Trust model

Skills ship in the repo, are reviewed in PR, and are read-only at
runtime. They are NOT untrusted input. The agent's LLM is still
untrusted — every calldata-producing decision derived from skill
content flows through the existing decode → simulate → ConfirmGate
pipeline.

This module imports no signing or key-material module; it is on the
forbidden-import gated path documented in `docs/PHASE0_PLAN.md`.

## Layout per skill (Phase 1b)

```
skills/<name>/
├── SKILL.md           # YAML frontmatter + summary
├── overview.md
├── contracts.json     # { "mainnet": {...}, "sepolia": {...} }
├── functions/
│   ├── <fn1>.md
│   └── <fn2>.md
├── security.md
├── interactions.md
└── abi/
    └── <ContractName>.json
```

Only `SKILL.md` and `overview.md` are read eagerly at startup. The
function bodies, full ABIs, and `contracts.json` payload are
fetched on demand by the agent tools.
-/

namespace LeanKohaku.Agent.Skills

open LeanKohaku.Encoding.Json

/-- Frontmatter fields the agent layer cares about. The daemon's
    action-skill reader ignores everything below `triggers`; the agent's
    reader ignores everything above (its `category`/`risk`). The
    overlap is `name` and `description`. -/
structure SkillFrontmatter where
  /-- Skill name; must match the directory basename. -/
  name        : String
  /-- Version stamp the curator bumps when content materially
      changes. Only used in operator-visible logs today. -/
  version     : String := "0.1"
  /-- One-line description surfaced both in the daemon's `skills.list`
      RPC and in the agent's `protocol_lookup` index. -/
  description : String := ""
  /-- Trigger keywords. Word-boundary case-insensitive match for
      alphabetic forms; lowercased hex addresses match by substring
      against lowercased input. -/
  triggers    : List String := []
  /-- Always include in the system prompt when present. Used by the
      meta-skills (`kohaku-wallet`, `web3-security`). -/
  alwaysOn    : Bool := false
  /-- Marks skills covering OFAC-sanctioned infrastructure. The
      renderer surfaces this as a factual statement; it does not
      cause the agent to refuse the turn. -/
  ofacFlagged : Bool := false
  deriving Repr, Inhabited

/-- A parsed skill ready for trigger matching and prompt rendering.
    Body strings are pre-loaded so the `Loop` does not touch disk on
    every turn; the eight files-on-disk per skill is small enough that
    eager load beats per-turn IO. -/
structure Skill where
  frontmatter : SkillFrontmatter
  overview    : String := ""
  security    : String := ""
  interactions: String := ""
  /-- `functions/<fn>.md` → markdown body. Loaded eagerly because the
      agent's `protocol_function_lookup` tool returns one entry at a
      time and we want zero IO from inside the tool dispatch path. -/
  functions   : List (String × String) := []
  /-- Parsed `contracts.json` (empty `Json.obj` if absent). -/
  contracts   : Json := .obj #[]
  /-- Filesystem root for this skill. Kept for diagnostics; the agent
      never reads from it after parse. -/
  root        : System.FilePath

/-- Default `Skill` used by tests and lookup-miss paths. Hand-written
    because `Json` is not `Inhabited`. -/
instance : Inhabited Skill where
  default :=
    { frontmatter := default, overview := "", security := "",
      interactions := "", functions := [], contracts := .obj #[],
      root := System.FilePath.mk "" }

/-- Top-level registry. `skills` is an `Array` because we render
    deterministically in declaration order; `root` is kept for
    `reload`. -/
structure Registry where
  root   : System.FilePath
  skills : Array Skill

instance : Inhabited Registry where
  default := { root := System.FilePath.mk "", skills := #[] }

/-- ASCII lowercase. Lean's `String.toLower` works on full Unicode,
    which is correct for natural-language matching but overkill for
    hex addresses — and for plain alphabetic triggers ASCII is
    equivalent. -/
private def asciiLower (s : String) : String :=
  String.ofList (s.toList.map (fun c =>
    if 'A' ≤ c && c ≤ 'Z' then Char.ofNat (c.toNat + 32) else c))

/-- Word-boundary substring match. Scans `haystackLower` once,
    checking at each position whether `needle` matches *and* both
    sides of the match are at a word boundary (non-alphanumeric or
    end-of-string). `needle` is assumed already lowercase ASCII. -/
private def wordMatch (haystackLower : String) (needle : String) : Bool :=
  if needle.isEmpty then false
  else
    let nChars := needle.toList
    let nLen := nChars.length
    let hChars := haystackLower.toList
    let isWordChar (c : Char) : Bool := c.isAlpha || c.isDigit || c == '_'
    -- One-pass: at each index, check the boundary condition + prefix.
    let positions := List.range hChars.length
    positions.any (fun i =>
      let leftOk := if i = 0 then true
                    else match hChars[i - 1]? with
                         | some c => !isWordChar c
                         | none   => true
      let slice := (hChars.drop i).take nLen
      let prefixOk := slice = nChars
      let rightOk := match hChars[i + nLen]? with
                     | some c => !isWordChar c
                     | none   => true
      leftOk && prefixOk && rightOk)

/-- Substring match — used for hex address triggers (no word boundary
    because hex strings sit inside calldata or JSON quotes). -/
private def hexMatch (haystackLower : String) (needle : String) : Bool :=
  if needle.isEmpty then false else (haystackLower.splitOn needle).length > 1

/-- A trigger that starts with `0x` and is all hex is matched by
    substring; otherwise by word boundary. -/
private def matchOne (haystackLower : String) (trigger : String) : Bool :=
  let t := asciiLower trigger
  if t.startsWith "0x" then hexMatch haystackLower t
  else wordMatch haystackLower t

/-- Return true iff any trigger of `s` matches `input`. -/
def hasMatch (s : Skill) (input : String) : Bool :=
  let lo := asciiLower input
  s.frontmatter.triggers.any (matchOne lo)

-- Tiny YAML parser sufficient for our frontmatter shape: top-level
-- `key: value` plus a `triggers:` block of `- item` lines. No
-- nested maps. Anything we cannot parse is ignored — the curator
-- sees a missing field, not a crashed daemon.
namespace Yaml

private def stripLeadingSpaces (s : String) : String :=
  (s.dropWhile (fun c => c = ' ' || c = '\t')).toString

private def trimQuotes (s : String) : String :=
  let t := s.trimAscii.toString
  if (t.startsWith "\"" && t.endsWith "\"") ||
     (t.startsWith "'"  && t.endsWith "'") then
    ((t.drop 1).dropEnd 1).toString
  else t

private def isListItem (s : String) : Bool :=
  (stripLeadingSpaces s).startsWith "- "

private def listItemValue (s : String) : String :=
  trimQuotes (((stripLeadingSpaces s).drop 2).toString)

/-- Match a top-level `key:` line. Returns the optional inline value
    (everything after the colon) if any. -/
private def matchKey (line key : String) : Option String :=
  let keyCol := key ++ ":"
  if line.startsWith keyCol then
    let v := (line.drop keyCol.length).toString
    some (trimQuotes (v.trimAscii.toString))
  else none

/-- Pull a scalar string for `key` from the frontmatter lines, defaulting
    to the empty string. Strings appearing on the same line as the key
    win; otherwise we leave the value empty (curator should fix). -/
private def scalar (lines : List String) (key : String) : Option String :=
  lines.foldl (fun acc line =>
    match acc with
    | some _ => acc
    | none =>
        match matchKey line key with
        | some v => if v.isEmpty then none else some v
        | none   => none) none

/-- Pull a list-of-strings under `key:` (each `- item` indented). Stops
    at the next top-level key. -/
private def listUnder (lines : List String) (key : String) : List String :=
  let rec collect (rest : List String) (started : Bool) (out : List String) : List String :=
    match rest with
    | [] => out.reverse
    | l :: ls =>
        let trimmed := l.trimAscii.toString
        if !started then
          if trimmed.startsWith (key ++ ":") then collect ls true out
          else collect ls started out
        else
          if isListItem l then collect ls true (listItemValue l :: out)
          else if trimmed.isEmpty then collect ls true out
          else if l.length > 0 && !(l.startsWith " ") && !(l.startsWith "\t")
                 && trimmed.contains ':' then
            out.reverse   -- next top-level key — stop
          else collect ls true out
  collect lines false []

/-- True/false scalar with sensible defaults. -/
private def boolScalar (lines : List String) (key : String) (default : Bool := false) : Bool :=
  match scalar lines key with
  | some v =>
      let lo := v.trimAscii.toString
      lo = "true" || lo = "yes" || lo = "on" ||
        (lo != "false" && lo != "no" && lo != "off" && default)
  | none => default

/-- Public-facing parser: takes a `SKILL.md` body, returns the parsed
    frontmatter. Missing `name` causes the skill to be rejected at the
    registry layer. -/
def parseFrontmatter (content : String) : Option SkillFrontmatter :=
  let lines := content.splitOn "\n"
  -- Frontmatter is delimited by `---` on the first non-empty line.
  match lines with
  | first :: rest =>
      if first.trimAscii.toString = "---" then
        let fm := rest.takeWhile (fun l => l.trimAscii.toString != "---")
        match scalar fm "name" with
        | none => none
        | some name =>
            some {
              name        := name,
              version     := (scalar fm "version").getD "0.1",
              description := (scalar fm "description").getD "",
              triggers    := listUnder fm "triggers",
              alwaysOn    := boolScalar fm "alwaysOn",
              ofacFlagged := boolScalar fm "ofacFlagged"
            }
      else none
  | [] => none

end Yaml

/-- Best-effort read; returns empty string on missing or unreadable
    file. Skill bodies are part of the trusted code base — a missing
    file is curator debt, not an attack. -/
private def readMaybe (path : System.FilePath) : IO String := do
  if (← path.pathExists) then
    try IO.FS.readFile path catch _ => pure ""
  else pure ""

/-- Read every `<name>.md` under `<dir>/functions/`. Returns a list of
    `(stem, body)` in directory-listing order. -/
private def loadFunctionsDir (dir : System.FilePath) : IO (List (String × String)) := do
  if !(← dir.pathExists) then return []
  let entries ← System.FilePath.readDir dir
  let mut out : List (String × String) := []
  for entry in entries do
    let p := entry.path
    if !(← p.isDir) then
      let name := entry.fileName
      if name.endsWith ".md" then
        let body ← readMaybe p
        let stem := (name.dropEnd 3).toString
        out := out ++ [(stem, body)]
  pure out

/-- Parse `contracts.json` if present; empty object otherwise. -/
private def loadContracts (dir : System.FilePath) : IO Json := do
  let p := dir / "contracts.json"
  if !(← p.pathExists) then return .obj #[]
  let raw ← readMaybe p
  if raw.isEmpty then return .obj #[]
  match parse raw with
  | .ok j => pure j
  | .error _ => pure (.obj #[])

/-- Parse one skill directory. Returns `none` when `SKILL.md` is
    missing or its frontmatter fails to parse — the caller logs a
    warning so the curator sees which skill was skipped. -/
def loadSkill (dir : System.FilePath) : IO (Option Skill) := do
  let skillMd := dir / "SKILL.md"
  if !(← skillMd.pathExists) then return none
  let content ← readMaybe skillMd
  match Yaml.parseFrontmatter content with
  | none => pure none
  | some fm =>
      let overview     ← readMaybe (dir / "overview.md")
      let security     ← readMaybe (dir / "security.md")
      let interactions ← readMaybe (dir / "interactions.md")
      let functions    ← loadFunctionsDir (dir / "functions")
      let contracts    ← loadContracts dir
      pure (some {
        frontmatter := fm,
        overview := overview,
        security := security,
        interactions := interactions,
        functions := functions,
        contracts := contracts,
        root := dir
      })

/-- Walk `root` one level deep; each subdir whose `SKILL.md` parses
    becomes a `Skill`. Subdirs missing the file are skipped silently;
    parse failures emit a `stderr` warning so the curator sees them. -/
def loadRegistry (root : System.FilePath) : IO Registry := do
  if !(← root.pathExists) then
    return { root := root, skills := #[] }
  let entries ← System.FilePath.readDir root
  let mut acc : Array Skill := #[]
  for entry in entries do
    let p := entry.path
    if (← p.isDir) then
      match ← loadSkill p with
      | some s => acc := acc.push s
      | none =>
          let skillMd := p / "SKILL.md"
          if (← skillMd.pathExists) then
            IO.eprintln s!"[skills] WARN: {entry.fileName}/SKILL.md frontmatter parse failed; skipping"
  pure { root := root, skills := acc }

/-- Re-walk the same `root`. Convenience for SIGHUP-style reload — see
    `docs/PHASE1B_PLAN.md` for why we use a `reload` op rather than a
    real POSIX signal handler. -/
def reload (r : Registry) : IO Registry :=
  loadRegistry r.root

/-- Always-on skills (the meta-skills). Returned in registry order. -/
def alwaysOn (r : Registry) : Array Skill :=
  r.skills.filter (fun s => s.frontmatter.alwaysOn)

/-- Trigger-matched skills against `input`. Excludes always-on skills —
    those are returned separately so the caller can de-dup deterministically
    and apply a different ordering. -/
def matchTriggers (r : Registry) (input : String) : Array Skill :=
  r.skills.filter (fun s => !s.frontmatter.alwaysOn && hasMatch s input)

/-- Cap a multiline body to roughly `maxChars`, breaking at the
    nearest newline so a renderer never emits a half-truncated word.
    Adds an explicit ellipsis line so the model sees the body was cut.
    Char-based truncation (not byte) — good enough for ASCII-heavy
    skill content and avoids the v4.29.1 `String.Pos` two-field
    constructor churn. -/
private def capBody (body : String) (maxChars : Nat) : String :=
  if body.length <= maxChars then body
  else
    let chars := body.toList
    let head := chars.take maxChars
    -- Find the last newline position so we don't truncate mid-line.
    let lastNlIdx :=
      ((head.zipIdx).foldl
        (fun acc (c, i) => if c = '\n' then i else acc) 0)
    let truncated := if lastNlIdx > 0 then head.take lastNlIdx else head
    String.ofList truncated ++ "\n…[truncated]…"

/-- Render one skill as a compact context block for the system prompt.
    Caps the overview to ~6 KiB and lists at most three function names
    inline — the model fetches full function bodies via the
    `protocol_function_lookup` tool. -/
def renderForPrompt (s : Skill) : String :=
  let fm := s.frontmatter
  let header := s!"# Skill: {fm.name} (v{fm.version})"
  let summary := if fm.description.isEmpty then "" else "\n" ++ fm.description
  let ofac := if fm.ofacFlagged then
                "\nNOTE: This skill covers OFAC-sanctioned infrastructure. \
                 Surface the legal status to the user; the agent does not \
                 refuse on sanctions grounds."
              else ""
  let overview :=
    if s.overview.isEmpty then "\n(overview: TODO — curator)"
    else "\n\n## Overview\n" ++ capBody s.overview 6144
  let secBlock :=
    if s.security.isEmpty then ""
    else "\n\n## Security\n" ++ capBody s.security 2048
  let interBlock :=
    if s.interactions.isEmpty then ""
    else "\n\n## Interactions\n" ++ capBody s.interactions 2048
  let fnNames := (s.functions.map Prod.fst).take 3
  let fnHint :=
    if fnNames.isEmpty then ""
    else
      "\n\n## Functions (call `protocol_function_lookup` for bodies)\n" ++
      String.intercalate "\n" (fnNames.map (fun n => "- " ++ n))
  header ++ summary ++ ofac ++ overview ++ secBlock ++ interBlock ++ fnHint

/-- Find a skill by name. -/
def findSkill (r : Registry) (name : String) : Option Skill :=
  r.skills.find? (fun s => s.frontmatter.name = name)

/-- Find a function body by `(skill, function)` name. -/
def findFunction (r : Registry) (skill function : String) : Option String :=
  (findSkill r skill).bind (fun s =>
    s.functions.find? (fun (n, _) => n = function) |>.map Prod.snd)

end LeanKohaku.Agent.Skills
