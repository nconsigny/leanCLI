/-!
# Tornado withdrawal tail calls

User-supplied calls appended after the payout call of a Tornado paymaster
withdrawal (parity with kohaku-cli `--tail-calls`, upstream 0df25ce). The Lean
core owns parsing and validation: the CLI parses the flag spec here, the
daemon re-validates the JSON entries with the same predicates, and the sidecar
receives only entries that already passed both (it still re-validates as
defense in depth — sidecars are malicious by assumption).

Spec format: comma-separated `TARGET:CALLDATA[:VALUE]` entries. TARGET is a
0x 20-byte address, CALLDATA is 0x-prefixed byte-aligned hex (`0x` = empty),
VALUE is msg.value in wei — decimal or 0x-hex, default 0. Values are paid out
of the withdrawal amount after the paymaster fee; the sidecar enforces that
bound at quote/execute time (the amount may be the `max` sentinel, so the
bound cannot be checked here).
-/

namespace LeanCli.Ethereum.TornadoTailCalls

structure TailCall where
  to : String
  data : String
  valueWei : Nat
  deriving Repr, DecidableEq, Inhabited

private def isHexDigit (c : Char) : Bool :=
  c.isDigit || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

def isHexAddress (s : String) : Bool :=
  let digits := s.toList.drop 2
  s.startsWith "0x" && digits.length = 40 && digits.all isHexDigit

/-- 0x-prefixed, byte-aligned hex; bare `0x` (empty calldata) is allowed. -/
def isHexBytes (s : String) : Bool :=
  let digits := s.toList.drop 2
  s.startsWith "0x" && digits.length % 2 = 0 && digits.all isHexDigit

private def hexDigitVal (c : Char) : Nat :=
  if c.isDigit then c.toNat - '0'.toNat
  else if 'a' ≤ c && c ≤ 'f' then c.toNat - 'a'.toNat + 10
  else c.toNat - 'A'.toNat + 10

/-- Wei value: decimal digits or 0x-hex; empty/malformed ⇒ `none`. -/
def parseValueWei (s : String) : Option Nat :=
  if s.startsWith "0x" then
    let digits := s.toList.drop 2
    if digits.isEmpty || !digits.all isHexDigit then none
    else some (digits.foldl (fun acc c => acc * 16 + hexDigitVal c) 0)
  else
    s.toNat?

def parseEntry (index : Nat) (entry : String) : Except String TailCall := do
  let parts := (entry.splitOn ":").map (·.trimAscii.toString)
  if parts.length < 2 || parts.length > 3 || parts.any (·.isEmpty) then
    throw s!"invalid tail call at index {index}: expected TARGET:CALLDATA or TARGET:CALLDATA:VALUE"
  let to := parts[0]!
  let data := parts[1]!
  if !isHexAddress to then
    throw s!"invalid tail call target at index {index}: {to}"
  if !isHexBytes data then
    throw s!"invalid tail call calldata at index {index}: expected 0x-prefixed byte-aligned hex"
  let valueWei ← match parts[2]? with
    | none => pure 0
    | some raw =>
        match parseValueWei raw with
        | some v => pure v
        | none => throw s!"invalid tail call value at index {index}: expected decimal or 0x-hex wei ({raw})"
  pure { to, data, valueWei }

/-- Parse a full `--tail-calls` spec (comma-separated entries). -/
def parseSpec (raw : String) : Except String (Array TailCall) :=
  let entries := (raw.splitOn ",").map (·.trimAscii.toString)
  if entries.isEmpty || entries.any (·.isEmpty) then
    .error "tail calls must be comma-separated TARGET:CALLDATA[:VALUE] entries"
  else
    let rec go (i : Nat) (rest : List String) (acc : Array TailCall) :
        Except String (Array TailCall) :=
      match rest with
      | [] => .ok acc
      | e :: rest =>
          match parseEntry i e with
          | .error err => .error err
          | .ok call => go (i + 1) rest (acc.push call)
    go 0 entries #[]

def totalValueWei (calls : Array TailCall) : Nat :=
  calls.foldl (fun acc c => acc + c.valueWei) 0

-- Upstream README example: two calls, second carrying 0x2386f26fc10000 wei (0.01 ETH).
example :
    (match parseSpec "0x1111111111111111111111111111111111111111:0x1234,0x2222222222222222222222222222222222222222:0xabcd:0x2386f26fc10000" with
      | .ok calls =>
          calls.size = 2 &&
          totalValueWei calls = 10000000000000000 &&
          calls[0]!.valueWei = 0
      | .error _ => false) = true := by native_decide

example :
    (match parseSpec "0x1111111111111111111111111111111111111111:0x:25" with
      | .ok calls => calls[0]!.data = "0x" && calls[0]!.valueWei = 25
      | .error _ => false) = true := by native_decide

-- Rejections: short target, odd-nibble calldata, malformed value, empty entry.
example : (parseSpec "0x1111:0x1234").isOk = false := by native_decide
example : (parseSpec "0x1111111111111111111111111111111111111111:0x123").isOk = false := by native_decide
example : (parseSpec "0x1111111111111111111111111111111111111111:0x12:wei").isOk = false := by native_decide
example : (parseSpec "0x1111111111111111111111111111111111111111:0x12,").isOk = false := by native_decide

end LeanCli.Ethereum.TornadoTailCalls
