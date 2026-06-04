import LeanCli.Agent.State
import LeanCli.Agent.Llm
import LeanCli.Agent.MemoryPrompts
import LeanCli.Encoding.Json

/-!
# Long-term memory for the Lean-native agent

Loads, saves, and updates `MEMORY.md` — a small markdown file
included in every new session's system prompt. The file is written
exclusively by the daemon; CLI subcommands assemble new content and
POST it through the agent socket so we keep a single writer (parity
with `sessions.db`).

## File semantics

* Path: `$XDG_DATA_HOME/leancli/MEMORY.md`, with the standard
  fallbacks for unset XDG.
* Mode: `0600`. Parent dir: best-effort `0700`. Same posture as the
  session DB.
* Atomic writes: write to `<path>.tmp` then `rename` so a crash
  mid-write cannot leave a torn file.

## Extraction trust contract

The local LLM is asked to produce a JSON envelope `{"memory": "..."}`
summarising what is worth remembering from a session. Defence in
depth:

1. The prompt (`MemoryPrompts.extractionInstructions`) tells the
   model what to exclude.
2. The Lean side defensively parses the response — if the body is
   not valid JSON or the `memory` field is missing, extraction
   returns `Except.error` and the on-disk file is unchanged.
3. The `postFilter` pass drops any **line** matching a private-key
   shape, a mnemonic shape, or a signing-API name. Filtering is
   line-grained because a single offending line should not nuke the
   whole memory.
4. The output is capped at `MemoryPrompts.memoryByteCap` bytes,
   truncated at the last newline boundary.

This module imports no signing or key-material module and is on
the forbidden-import gated path documented in `docs/PHASE0_PLAN.md`.

## Trust boundary

`MEMORY.md` content is **informational**. It is concatenated into the
next session's system prompt so the model has cross-session context,
but it never feeds a signing decision. Every produced calldata still
flows through the standard `decode → simulate → ConfirmGate` pipeline
in the wallet daemon; a poisoned memory line could at worst nudge the
model toward a draft the user must still confirm. The on-disk file is
mode-0600 and the SQLite session store the extraction reads from is
the same — both inherit the agentd's UDS peer-uid check.
-/

namespace LeanCli.Agent.Memory

open LeanCli.Agent
open LeanCli.Encoding.Json

/-- In-memory representation of MEMORY.md. `raw` is the file content
    verbatim (UTF-8); `path` is where it lives on disk. -/
structure Memory where
  raw  : String
  path : System.FilePath
  deriving Inhabited

/-- Resolve the canonical MEMORY.md path. Honours
    `LEANCLI_AGENT_MEMORY` (testing override) then
    `$XDG_DATA_HOME/leancli/MEMORY.md`, falling back to
    `$HOME/.local/share/leancli/MEMORY.md`, finally `/tmp`. -/
def defaultPath : IO System.FilePath := do
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

/-- Best-effort `chmod 0700` on the parent directory of `path`.
    Shells out to `chmod` because Lean's `IO.FS` lacks a chmod
    primitive at v4.29.1. Silent on missing `chmod`. -/
private def chmodParent0700 (path : System.FilePath) : IO Unit := do
  match path.parent with
  | some parent =>
      try IO.FS.createDirAll parent catch _ => pure ()
      try
        let _ ← IO.Process.run { cmd := "chmod", args := #["700", parent.toString] }
      catch _ => pure ()
  | none => pure ()

/-- Best-effort `chmod 0600` on `path`. -/
private def chmod0600 (path : System.FilePath) : IO Unit := do
  try
    let _ ← IO.Process.run { cmd := "chmod", args := #["600", path.toString] }
  catch _ => pure ()

/-- Load MEMORY.md from `path`. Returns an empty `Memory` when the
    file does not exist; surfaces other IO errors. -/
def load (path : System.FilePath) : IO Memory := do
  if !(← path.pathExists) then
    pure { raw := "", path := path }
  else
    let raw ← IO.FS.readFile path
    pure { raw := raw, path := path }

/-- Atomic write: write to `<path>.tmp`, then `rename` to `path`.
    Best-effort enforces parent dir `0700` and file `0600` after
    the rename. -/
def save (m : Memory) : IO Unit := do
  chmodParent0700 m.path
  let tmp := System.FilePath.mk (m.path.toString ++ ".tmp")
  IO.FS.writeFile tmp m.raw
  -- Make sure the tmp file is itself 0600 before we expose its
  -- final name; that way a peer racing against the rename never
  -- sees a wider-mode file.
  chmod0600 tmp
  IO.FS.rename tmp m.path
  chmod0600 m.path

/-- Whitespace word count. ASCII-friendly; treats any of
    space/tab/newline/CR as a separator. -/
private def wordCount (text : String) : Nat :=
  let isSep (c : Char) : Bool := c = ' ' || c = '\n' || c = '\t' || c = '\r'
  let step (state : Nat × Bool) (c : Char) : Nat × Bool :=
    let (n, inWord) := state
    if isSep c then (n, false)
    else if inWord then (n, true)
    else (n + 1, true)
  let (count, _) := text.toList.foldl step ((0 : Nat), false)
  count

/-- Cheap token estimator: word count × 1.4, with an env override
    for model-specific drift. We never use Mathlib floats; the
    integer formulation `words * num / den` is enough. Default
    ratio is 14/10 = 1.4. -/
def estimateTokens (text : String) : IO Nat := do
  let (num, den) ← do
    match ← IO.getEnv "LEANCLI_TOKEN_RATIO" with
    | none => pure (14, 10)
    | some s =>
        -- Accept formats: "1.4", "14/10", or a bare integer ratio.
        match s.splitOn "/" with
        | [n, d] =>
            match n.toNat?, d.toNat? with
            | some n, some d => if d = 0 then pure (14, 10) else pure (n, d)
            | _, _ => pure (14, 10)
        | _ =>
            match s.splitOn "." with
            | [whole, frac] =>
                match whole.toNat?, frac.toNat? with
                | some w, some f =>
                    -- Reconstruct as fraction over 10^len(frac).
                    let den := (List.range frac.length).foldl (fun a _ => a * 10) 1
                    pure (w * den + f, den)
                | _, _ => pure (14, 10)
            | _ =>
                match s.toNat? with
                | some n => pure (n, 1)
                | none => pure (14, 10)
  pure ((wordCount text * num) / den)

/-- Render the memory block for inclusion in a system prompt.
    Returns the empty string when memory is empty so callers can
    omit the section entirely; otherwise emits a labelled block
    capped at roughly `maxTokens` tokens (best-effort, char-based
    truncation at the last newline). -/
def renderForPrompt (m : Memory) (maxTokens : Nat := 1024) : String :=
  if m.raw.trimAscii.toString.isEmpty then ""
  else
    -- Convert maxTokens back to a rough character budget. Using the
    -- inverse of the default 1.4 multiplier is fine — this cap is
    -- advisory; the source of truth for hard bounds is the on-disk
    -- 8 KiB cap.
    let charBudget := (maxTokens * 10) / 14 * 6 -- ~6 chars per word average
    let body :=
      if m.raw.length ≤ charBudget then m.raw
      else
        let chars := m.raw.toList
        let head := chars.take charBudget
        -- Truncate at last newline so we never cut mid-line.
        let lastNl : Nat :=
          ((head.zipIdx).foldl
            (fun acc (c, i) => if c = '\n' then i else acc) 0)
        let kept := if lastNl > 0 then head.take lastNl else head
        String.ofList kept ++ "\n... (truncated)"
    "# Long-term memory (curated by the agent across sessions)\n\n" ++ body

/-! ## Post-extraction filter -/

/-- True iff `s` contains a `0x`-prefixed 64-hex-character run
    (private-key shape). Scans each tail position once; the
    structural recursion peels one `Char` per step so termination
    is obvious. -/
private partial def hasHexRunAt : List Char → Nat → Bool
  | [], _ => false
  | _, 0 => true
  | c :: rest, n =>
      let isHex :=
        ('0' ≤ c && c ≤ '9') ||
        ('a' ≤ c && c ≤ 'f') ||
        ('A' ≤ c && c ≤ 'F')
      if isHex then hasHexRunAt rest (n - 1) else false

private def containsPrivateKeyHex (s : String) : Bool :=
  let rec scan : List Char → Bool
    | [] => false
    | '0' :: 'x' :: rest => if hasHexRunAt rest 64 then true else scan rest
    | '0' :: 'X' :: rest => if hasHexRunAt rest 64 then true else scan rest
    | _ :: rest => scan rest
  scan s.toList

/-- Split `s` on ASCII whitespace into a list of non-empty
    tokens. v4.29.1's `String.split` returns a slice iterator
    that's awkward to traverse, so we lower to `List Char` and
    accumulate by hand. -/
private def splitOnAsciiWs (s : String) : List String :=
  let isSep (c : Char) : Bool := c = ' ' || c = '\n' || c = '\t' || c = '\r'
  let step (state : List String × List Char) (c : Char) : List String × List Char :=
    let (acc, cur) := state
    if isSep c then
      if cur.isEmpty then (acc, [])
      else (acc ++ [String.ofList cur.reverse], [])
    else (acc, c :: cur)
  let (acc, current) :=
    s.toList.foldl step (([] : List String), ([] : List Char))
  if current.isEmpty then acc else acc ++ [String.ofList current.reverse]

/-- True iff `s` contains 12 or more consecutive whitespace-
    separated lowercase ASCII alphabetic words. Belt-and-braces
    for the BIP-39 mnemonic shape; over-cautious by design. -/
private def containsMnemonicShape (s : String) : Bool :=
  let isLowerAlpha (c : Char) : Bool := 'a' ≤ c && c ≤ 'z'
  let words := splitOnAsciiWs s
  -- Sliding window: how many consecutive words are all-lower-alpha?
  let step (state : Nat × Nat) (w : String) : Nat × Nat :=
    let (mx, cur) := state
    let allLower := w.toList.all isLowerAlpha && w.length ≥ 2
    let cur' := if allLower then cur + 1 else 0
    (Nat.max mx cur', cur')
  let (best, _) := words.foldl step ((0 : Nat), (0 : Nat))
  best ≥ 12

/-- Forbidden signing-API names we never want to record in
    long-term memory. -/
private def signingApiNames : List String :=
  ["eth_sendRawTransaction", "signTransaction", "signTypedData",
   "personal_sign", "eth_sign"]

/-- True iff `s` mentions any of the forbidden signing API names. -/
private def containsSigningApi (s : String) : Bool :=
  signingApiNames.any (fun name => (s.splitOn name).length > 1)

/-- Per-line drop predicate. Public for tests. -/
def shouldDropLine (line : String) : Bool :=
  containsPrivateKeyHex line ||
  containsMnemonicShape line ||
  containsSigningApi line

/-- Truncate `content` to `cap` bytes at the last newline boundary,
    appending a marker. Byte-cap rather than char-cap because the
    on-disk file is mode 0600 and we want a tight upper bound on
    its size. -/
def capToBytes (content : String) (cap : Nat) : String :=
  if content.utf8ByteSize ≤ cap then content
  else
    -- Walk lines, summing byte sizes until we'd exceed cap.
    let lines := content.splitOn "\n"
    let (kept, _) := lines.foldl
      (fun (acc, used) line =>
        let added := line.utf8ByteSize + 1   -- +1 for the newline
        if used + added > cap then (acc, used)
        else (acc ++ [line], used + added))
      (([] : List String), 0)
    String.intercalate "\n" kept ++ "\n... (truncated)\n"

/-- Apply the post-extraction filter and the byte cap. Returns the
    filtered string plus the count of dropped lines (callers log
    only the count, never the content). -/
def postFilter (content : String) : String × Nat :=
  let lines := content.splitOn "\n"
  let kept := lines.filter (fun l => !shouldDropLine l)
  let dropped := lines.length - kept.length
  let body := String.intercalate "\n" kept
  (capToBytes body MemoryPrompts.memoryByteCap, dropped)

/-! ## Extraction -/

/-- Build the chat transcript we send to the LLM for extraction.
    The system message carries the policy, the user message
    carries the existing MEMORY.md and the session transcript. -/
private def buildExtractionMessages
    (existing : Memory) (sessionMessages : Array AgentMessage) :
    Array AgentMessage :=
  let roleLine : Role → String
    | .system => "system"
    | .user => "user"
    | .assistant => "assistant"
    | .tool => "tool"
  let transcript : String :=
    String.intercalate "\n\n" <|
      sessionMessages.toList.map fun m =>
        let content := m.content.getD ""
        s!"[{roleLine m.role}] {content}"
  let userBody :=
    "Existing MEMORY.md (may be empty):\n\n" ++
    "---\n" ++ existing.raw ++ "\n---\n\n" ++
    "Session transcript (most recent at bottom):\n\n" ++
    "---\n" ++ transcript ++ "\n---\n\n" ++
    "Now emit the JSON envelope per the system instructions."
  #[ AgentMessage.system MemoryPrompts.extractionInstructions,
     AgentMessage.user userBody ]

/-- Try to pull a `memory` string field from a parsed Json
    envelope. -/
private def parseMemoryEnvelope (raw : String) : Except String String :=
  match parse raw.trimAscii.toString with
  | .error e => .error s!"memory envelope JSON parse failed: {e}"
  | .ok j =>
      match getField "memory" j with
      | some (.str s) => .ok s
      | some _ => .error "memory envelope: 'memory' field is not a string"
      | none => .error "memory envelope: missing 'memory' field"

/-- Defensive JSON extraction: find the first balanced `{ ... }` in
    `raw` and try to parse it. Lets us survive llama-server runs
    that prefix a "Sure, here you go:" preamble. -/
private def findFirstJsonObject (raw : String) : Option String :=
  let chars := raw.toList
  -- Find first '{' then walk to its matching '}' (depth-1).
  let rec loop (cs : List Char) (depth : Nat) (acc : List Char) (started : Bool) :
      Option String :=
    match cs with
    | [] => none
    | c :: rest =>
        if !started && c = '{' then
          loop rest 1 ['{'] true
        else if !started then
          loop rest 0 [] false
        else
          let acc' := c :: acc
          match c with
          | '{' => loop rest (depth + 1) acc' true
          | '}' =>
              if depth = 1 then some (String.ofList acc'.reverse)
              else loop rest (depth - 1) acc' true
          | _ => loop rest depth acc' true
  loop chars 0 [] false

/-- Drive the local LLM to produce a new MEMORY.md from the
    session transcript. Failure modes (returned as `Except.error`):
    transport / protocol errors, malformed JSON, missing `memory`
    field. Success: the **filtered, capped** new content as a
    fresh `Memory` value (caller persists it). -/
def extract
    (cfg : AgentConfig) (existing : Memory)
    (sessionMessages : Array AgentMessage) :
    IO (Except String Memory) := do
  let msgs := buildExtractionMessages existing sessionMessages
  let s : AgentState := { messages := msgs, cfg := cfg }
  match ← Llm.chat s [] with
  | .error e =>
      pure (.error s!"extract: llm error: {repr e}")
  | .ok (assistant, _) =>
      let content := assistant.content.getD ""
      let candidate : Except String String :=
        match parseMemoryEnvelope content with
        | .ok s => .ok s
        | .error _ =>
            match findFirstJsonObject content with
            | some block => parseMemoryEnvelope block
            | none => .error s!"extract: no JSON envelope in response: {content}"
      match candidate with
      | .error e => pure (.error e)
      | .ok newRaw =>
          let (filtered, dropped) := postFilter newRaw
          if dropped > 0 then
            IO.eprintln s!"[memory] post-filter dropped {dropped} line(s)"
          pure (.ok { raw := filtered, path := existing.path })

/-- Apply a `forget` pattern: drop every line in `m.raw` that
    contains `pattern`. Caller is responsible for the length
    check (CLI refuses patterns shorter than 4 chars). Returns
    the new content + the count of dropped lines. -/
def forgetLinesMatching (m : Memory) (pattern : String) : Memory × Nat :=
  let lines := m.raw.splitOn "\n"
  let kept := lines.filter (fun l => (l.splitOn pattern).length = 1)
  let dropped := lines.length - kept.length
  let newRaw := String.intercalate "\n" kept
  ({ m with raw := newRaw }, dropped)

end LeanCli.Agent.Memory
