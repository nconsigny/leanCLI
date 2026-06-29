import LeanCli.Encoding.Json

/-!
# Address-integrity gate

A defence against an **untrusted model corrupting an address**. When the
LLM hand-encodes calldata (e.g. an ERC-20 `approve`) it writes a 20-byte
address into a 32-byte word — and it can transpose or fat-finger a nibble
while doing so, producing a *different but valid-looking* address. The
human at the ConfirmGate cannot catch a two-nibble swap in a 40-char hex
string, so the approval silently lands on the wrong spender.

The daemon, however, knows its own addresses exactly (wallet slots,
SPHINCS accounts). So before signing we decode every address embedded in
the proposed calldata (plus the top-level `to`) and compare each against
that known set. An address that is a **near-miss** — not an exact match,
but within a few nibbles — to a known address is almost certainly a typo
of it, and we refuse to sign.

The probability of an *intended* unrelated address landing within a
handful of nibbles of a known 20-byte address is astronomically small
(~`C(40,k)·15^k / 16^40`), so a near-miss is signal, not noise. This is
pure logic; the IO wrapper (gathering known addresses, raising the RPC
error) lives in `Daemon/Server/AddrGuard.lean`.
-/

namespace LeanCli.Daemon.AddressIntegrity

open LeanCli.Encoding.Json

/-- A suspected address typo: a calldata/field address that is a near (but
inexact) match to a known wallet/registry address. -/
structure Warning where
  /-- Where the address appeared — `"to"`, `"calldata.byte[4]"`, etc. -/
  field    : String
  /-- The suspicious address, normalized `0x` + 40 lowercase hex. -/
  got      : String
  /-- The known address it nearly matches (`0x` + 40 lowercase hex). -/
  suspect  : String
  /-- Human label of the known address (e.g. `"mainEOA/0"`). -/
  label    : String
  /-- Number of nibble positions that differ from `suspect`. -/
  distance : Nat
  deriving Repr

private def isHexNibble (c : Char) : Bool :=
  ('0' ≤ c ∧ c ≤ '9') ∨ ('a' ≤ c ∧ c ≤ 'f') ∨ ('A' ≤ c ∧ c ≤ 'F')

private def stripHex (s : String) : String :=
  if s.startsWith "0x" ∨ s.startsWith "0X" then (s.drop 2).toString else s

/-- Normalize to a bare 40-char lowercase hex address, or `none` if `s`
isn't a 20-byte address. -/
def normAddr (s : String) : Option String :=
  let b := stripHex s
  if b.length = 40 ∧ b.toList.all isHexNibble then some b.toLower else none

/-- Count differing positions between two equal-length char lists. -/
def hamming : List Char → List Char → Nat
  | x :: xs, y :: ys => (if x = y then 0 else 1) + hamming xs ys
  | _, _ => 0

/-- The nearest known address within `[1, threshold]` nibbles of `cand`,
if any. Returns `none` when `cand` is malformed, exactly matches some
known address (a legitimate self-send, never a typo), or is too far from
everything known (a genuinely different, intended address). -/
def nearestTypo (known : List (String × String)) (cand : String) (threshold : Nat)
    : Option (String × String × Nat) := Id.run do
  let some c := normAddr cand | return none
  -- Exact match to ANY known address ⇒ legitimate, short-circuit.
  for (kAddr, _) in known do
    if (normAddr kAddr) = some c then return none
  let mut best : Option (String × String × Nat) := none
  for (kAddr, kLabel) in known do
    match normAddr kAddr with
    | some k =>
        let d := hamming c.toList k.toList
        if 0 < d ∧ d ≤ threshold then
          match best with
          | some (_, _, bd) => if d < bd then best := some ("0x" ++ k, kLabel, d)
          | none            => best := some ("0x" ++ k, kLabel, d)
    | none => pure ()
  return best

/-- Address-shaped 32-byte word: 24 leading zero-nibbles then 40 hex whose
low 20 bytes aren't all zero. Yields the low-40-hex address (`0x`). -/
private def addrFromWord (w : List Char) : Option String :=
  if w.length = 64 ∧ (w.take 24).all (· = '0') then
    let lo := w.drop 24
    if lo.all isHexNibble ∧ lo.any (· ≠ '0') then some ("0x" ++ String.ofList lo)
    else none
  else none

private def scanAddressWords : Nat → Nat → List Char → List (String × String)
  | 0,        _,          _  => []
  | _,        _,          [] => []
  | fuel + 1, byteOffset, cs =>
      let here :=
        if cs.length ≥ 64 then
          match addrFromWord (cs.take 64) with
          | some a => [(s!"calldata.byte[{byteOffset}]", a)]
          | none   => []
        else []
      here ++ scanAddressWords fuel byteOffset.succ (cs.drop 2)

/-- Every candidate address worth checking in a proposal: the top-level
`to`, plus each address-shaped ABI word anywhere in the calldata. The
scan walks byte offsets rather than only top-level 32-byte argument slots
because smart-account batches and other wrappers can place an inner
function's calldata inside a dynamic `bytes` field, shifting the inner
address words off the outer ABI grid. -/
def candidateAddresses (to dataHex : String) : List (String × String) := Id.run do
  let mut cands : List (String × String) := [("to", to)]
  let body := stripHex dataHex
  if body.length ≥ 64 then
    cands := cands ++ scanAddressWords (body.length / 2 + 1) 0 body.toList
  return cands

/-- Decode every candidate address out of `(to, dataHex)` and return one
`Warning` per near-miss to a known address. Empty when clean. -/
def check (known : List (String × String)) (to dataHex : String) (threshold : Nat)
    : List Warning := Id.run do
  let mut ws : List Warning := []
  for (field, cand) in candidateAddresses to dataHex do
    match nearestTypo known cand threshold, normAddr cand with
    | some (suspect, label, d), some c =>
        ws := ws ++ [{ field, got := "0x" ++ c, suspect, label, distance := d }]
    | _, _ => pure ()
  return ws

end LeanCli.Daemon.AddressIntegrity
