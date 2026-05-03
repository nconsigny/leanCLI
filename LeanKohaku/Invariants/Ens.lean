/-!
# ENS name normalization (ASCII-only)

Pure helpers for splitting and validating an ENS name.

We deliberately do not implement UTS-46 / IDNA. Inputs containing any byte
above ASCII 0x7E or below 0x20, leading/trailing dots, empty labels, or
non-`a-z 0-9 - _` characters are rejected. Callers must downcase before
namehashing — uppercase ASCII is also accepted by the parser and lowercased
in place.
-/

namespace LeanKohaku.Invariants.Ens

private def isLowerAlpha (c : Char) : Bool := 'a' ≤ c ∧ c ≤ 'z'
private def isDigit (c : Char) : Bool := '0' ≤ c ∧ c ≤ '9'
private def isUpperAlpha (c : Char) : Bool := 'A' ≤ c ∧ c ≤ 'Z'

/-- Accept `[a-z0-9-_]` and uppercase letters (which the caller will lowercase). -/
def labelCharOk (c : Char) : Bool :=
  isLowerAlpha c || isDigit c || isUpperAlpha c || c = '-' || c = '_'

private def lowerChar (c : Char) : Char :=
  if isUpperAlpha c then Char.ofNat (c.toNat + 32) else c

/-- Split, lowercase, and validate an ENS name into its label list (left-to-right).
    Returns `none` for empty input, leading/trailing dot, double dot, or any
    label character that fails `labelCharOk`. -/
def normalizeLabels (name : String) : Option (List String) :=
  let chars := name.toList
  if chars.isEmpty then none
  else if chars.head? = some '.' then none
  else if chars.getLast? = some '.' then none
  else
    let lowered := chars.map lowerChar
    let labels := (String.ofList lowered).splitOn "."
    let allOk := labels.all (fun lbl =>
      !lbl.isEmpty && lbl.toList.all labelCharOk)
    if allOk then some labels else none

/-- A name "looks like an ENS name" if it parses successfully through
    `normalizeLabels` and has at least one dot. Single labels (no dot) are
    treated as names too — we keep that for the daemon helper but the CLI
    requires a dot to disambiguate from raw flags. -/
def looksLikeEnsName (s : String) : Bool :=
  s.contains '.' && (normalizeLabels s).isSome

example : normalizeLabels "vitalik.eth" = some ["vitalik", "eth"] := by native_decide
example : normalizeLabels "Vitalik.ETH" = some ["vitalik", "eth"] := by native_decide
example : normalizeLabels "" = none := by native_decide
example : normalizeLabels ".eth" = none := by native_decide
example : normalizeLabels "eth." = none := by native_decide
example : normalizeLabels "a..b" = none := by native_decide
example : normalizeLabels "a.b" = some ["a", "b"] := by native_decide

end LeanKohaku.Invariants.Ens
