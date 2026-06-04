import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address

/-!
# Address book

Local label↔address store. Users type "alice" instead of
`0xC0deDeAD...`; ENS resolutions get cached here so the second send to
`niard.eth` is instant; the LLM chat path can see the labels as
aliases in its seed so the model can substitute names without
inventing addresses.

## Storage

`$XDG_DATA_HOME/leancli/addressbook.json` (else
`~/.local/share/leancli/addressbook.json`). Same parent dir as the
EOA store (`Wallet/EoaStore.lean`). Single JSON file — not a per-entry
file like wallets — because entries are small and the whole book is
re-read on every lookup, and we never have so many entries that a
streaming read matters.

## Trust model

The address book is **not** a security boundary. Wrong entries cause
the user to send funds to the wrong place — bad — but no key is
exposed and no signing happens here. The trusted Send/Swap path
displays the looked-up `address` in the confirm step exactly as it is
stored, so the user can spot a mismatch.

The LLM chat path receives book entries as aliases in the seed; the
model is told it MAY substitute aliases for addresses. Aliases the
user added to a wrong address are the user's responsibility — same as
a typed wrong 0x.
-/

namespace LeanCli.Daemon.AddressBook

open LeanCli.Encoding.Json

/-- A single entry in the book. `source` tracks where the entry came
from for surfacing in UI (manual vs auto-cached ENS). `ensName`
populated when `source = "ens"`. `tag` is a free-form category
("personal", "protocol", "exchange") for grouping in the UI. -/
structure Entry where
  label    : String
  address  : String       -- 0x-prefixed; stored exactly as the user / resolver gave it
  source   : String := "manual"
  ensName  : Option String := none
  tag      : Option String := none
  addedAt  : Nat := 0     -- unix-ish second; 0 = unknown
  deriving Repr

private def dataHome : IO System.FilePath := do
  match ← IO.getEnv "XDG_DATA_HOME" with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "HOME" with
      | some home => pure (home ++ "/.local/share")
      | none => pure ".leancli"

def bookPath : IO System.FilePath := do
  pure ((← dataHome) / "leancli" / "addressbook.json")

private def ensureParent : IO Unit := do
  let p ← bookPath
  match p.parent with
  | some parent => IO.FS.createDirAll parent
  | none => pure ()

private def entryToJson (e : Entry) : Json :=
  .obj <| #[
    ("label",   .str e.label),
    ("address", .str e.address),
    ("source",  .str e.source),
    ("addedAt", .num (Int.ofNat e.addedAt))
  ]
  ++ (match e.ensName with | some n => #[("ensName", .str n)] | none => #[])
  ++ (match e.tag     with | some t => #[("tag",     .str t)] | none => #[])

private def entryFromJson (j : Json) : Option Entry := do
  let label ← asString (← getField "label" j)
  let address ← asString (← getField "address" j)
  let source := (asString (← getField "source" j) <|> some "manual").getD "manual"
  let ensName := getField "ensName" j >>= asString
  let tag := getField "tag" j >>= asString
  let addedAt := ((getField "addedAt" j) >>= asNat).getD 0
  pure { label, address, source, ensName, tag, addedAt }

/-- Load the book. Missing file → empty list (not an error). Malformed
file → error so a typo doesn't silently nuke the user's entries. -/
def loadIO : IO (Except String (List Entry)) := do
  let p ← bookPath
  if !(← p.pathExists) then return .ok []
  let content ← IO.FS.readFile p
  match LeanCli.Encoding.Json.parse content with
  | .error e => return .error s!"address book at {p} is malformed JSON: {e}"
  | .ok json =>
      match getField "entries" json with
      | none => return .error s!"address book at {p} missing `entries` field"
      | some arr =>
          match asArray arr with
          | none => return .error s!"address book at {p}: `entries` is not an array"
          | some xs =>
              let entries := xs.toList.filterMap entryFromJson
              return .ok entries

/-- Save the full book. Atomic-ish: write to a temp file, rename. -/
def saveIO (entries : List Entry) : IO (Except String Unit) := do
  try
    ensureParent
    let p ← bookPath
    let tmp := p.toString ++ ".tmp"
    let body : Json :=
      .obj #[
        ("version", .num 1),
        ("entries", .arr ((entries.map entryToJson).toArray))
      ]
    IO.FS.writeFile tmp (LeanCli.Encoding.Json.pretty body)
    IO.FS.rename tmp p
    pure (.ok ())
  catch e => pure (.error (toString e))

/-- Add or replace an entry by label. Returns the new list. -/
def addIO (entry : Entry) : IO (Except String (List Entry)) := do
  match ← loadIO with
  | .error e => pure (.error e)
  | .ok existing =>
      let filtered := existing.filter (fun e => e.label ≠ entry.label)
      let next := filtered ++ [entry]
      match ← saveIO next with
      | .ok () => pure (.ok next)
      | .error e => pure (.error e)

/-- Remove by label. Returns `(removed?, new list)`. -/
def removeIO (label : String) : IO (Except String (Bool × List Entry)) := do
  match ← loadIO with
  | .error e => pure (.error e)
  | .ok existing =>
      let next := existing.filter (fun e => e.label ≠ label)
      let removed := next.length < existing.length
      match ← saveIO next with
      | .ok () => pure (.ok (removed, next))
      | .error e => pure (.error e)

/-- Look up by label first, then by address (case-insensitive on the
0x...). Returns `none` if no match. -/
def lookupIO (needle : String) : IO (Except String (Option Entry)) := do
  match ← loadIO with
  | .error e => pure (.error e)
  | .ok entries =>
      -- Exact label match first.
      match entries.find? (fun e => e.label = needle) with
      | some hit => pure (.ok (some hit))
      | none =>
          let lneed := needle.toLower
          pure (.ok (entries.find? (fun e => e.address.toLower = lneed)))

end LeanCli.Daemon.AddressBook
