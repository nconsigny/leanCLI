/-!
# Revert-reason decoding for pre-sign simulation

Turns raw EVM revert data into a human-readable line for `ConfirmGate`.
A doomed transaction must die at the pre-sign simulate with a reason the
user can read — "batch leg 2 reverted: Aave: SUPPLY_CAP_EXCEEDED (51)" —
not on-chain as an opaque `status: revert` after a slow SPHINCS sign +
bundler round.

Recognized shapes (nested, because a smart account wraps inner reverts):

* `Error(string)`               (`0x08c379a0`) — Solidity `require(_, msg)`.
  Bare-numeric strings additionally get the Aave V3 errors-library name
  appended (Aave reverts with the stringified code, e.g. `"51"`).
* `Panic(uint256)`              (`0x4e487b71`) — Solidity checked-math /
  assert panics, mapped to their conventional names.
* `ExecuteError(uint256,bytes)` (`0x5a154675`) — the ERC-4337 BaseAccount
  `executeBatch` wrapper: which leg failed + the leg's own revert bytes
  (decoded recursively).

Pure module — no IO. Sits in the Domain layer next to the other
Ethereum decoding helpers; the daemon's `tx.simulate` calls `humanize`
on whatever `revertReason` string the backend produced.
-/

namespace LeanCli.Ethereum.RevertDecode

private def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat)
  else
    let lc := c.toLower
    if 'a' ≤ lc ∧ lc ≤ 'f' then some (10 + (lc.toNat - 'a'.toNat))
    else none

/-- Hex string (no `0x`) → bytes. `none` on odd length or non-hex. -/
private def hexToBytes? (s : String) : Option (Array Nat) := do
  let cs := s.toList
  if cs.length % 2 != 0 then none
  else
    let rec go : List Char → Array Nat → Option (Array Nat)
      | [], acc => some acc
      | hi :: lo :: rest, acc => do
          let h ← hexDigit? hi
          let l ← hexDigit? lo
          go rest (acc.push (h * 16 + l))
      | _, _ => none
    go cs #[]

/-- Big-endian bytes → Nat. -/
private def bytesToNat (bs : Array Nat) : Nat :=
  bs.foldl (fun acc b => acc * 256 + b) 0

/-- Word `idx` (32 bytes, 0-based) of `bs` starting at `base`. -/
private def word? (bs : Array Nat) (base idx : Nat) : Option Nat :=
  let lo := base + idx * 32
  if bs.size < lo + 32 then none
  else some (bytesToNat (bs.extract lo (lo + 32)))

/-- Printable-ASCII decode; non-printable bytes become `·` so a garbled
    reason is still visibly a string, not a crash. -/
private def asciiString (bs : Array Nat) : String :=
  String.ofList <| bs.toList.map fun b =>
    if 32 ≤ b ∧ b < 127 then Char.ofNat b else '·'

/-- Aave V3 `Errors` library: numeric revert string → symbolic name.
    Subset covering the codes retail supply/borrow/repay/withdraw flows
    can actually hit (aave-v3-core `Errors.sol`). Unknown codes render
    as `Aave error <n>`. -/
private def aaveErrorName (code : String) : Option String :=
  match code with
  | "26" => some "AMOUNT_ZERO"
  | "27" => some "RESERVE_INACTIVE"
  | "28" => some "RESERVE_FROZEN"
  | "29" => some "RESERVE_PAUSED"
  | "30" => some "BORROWING_NOT_ENABLED"
  | "32" => some "COLLATERAL_BALANCE_IS_ZERO"
  | "33" => some "HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD"
  | "34" => some "COLLATERAL_CANNOT_COVER_NEW_BORROW"
  | "35" => some "COLLATERAL_SAME_AS_BORROWING_CURRENCY"
  | "36" => some "NO_DEBT_OF_SELECTED_TYPE"
  | "39" => some "INCONSISTENT_FLASHLOAN_PARAMS"
  | "43" => some "UNDERLYING_BALANCE_ZERO"
  | "45" => some "HEALTH_FACTOR_NOT_BELOW_THRESHOLD"
  | "46" => some "INVALID_AMOUNT"
  | "50" => some "BORROW_CAP_EXCEEDED"
  | "51" => some "SUPPLY_CAP_EXCEEDED"
  | "57" => some "LTV_VALIDATION_FAILED"
  | "58" => some "INCONSISTENT_EMODE_CATEGORY"
  | "59" => some "PRICE_ORACLE_SENTINEL_CHECK_FAILED"
  | _    => none

/-- Solidity `Panic(uint256)` code → conventional name. -/
private def panicName (code : Nat) : String :=
  match code with
  | 0x01 => "assert failed"
  | 0x11 => "arithmetic overflow/underflow"
  | 0x12 => "division by zero"
  | 0x21 => "invalid enum value"
  | 0x31 => "pop on empty array"
  | 0x32 => "array index out of bounds"
  | 0x41 => "out of memory"
  | 0x51 => "call to uninitialized function"
  | n    => s!"panic 0x{Nat.toDigits 16 n |> String.ofList}"

/-- Decode one ABI-encoded revert blob (bytes AFTER `0x`). `depth`
    bounds the `ExecuteError` recursion (a hostile blob could nest). -/
private def decodeBytes : Nat → Array Nat → Option String
  | 0, _ => none
  | depth + 1, bs =>
    if bs.size < 4 then none
    else
      let sel := bytesToNat (bs.extract 0 4)
      let args := bs.extract 4 bs.size
      if sel = 0x08c379a0 then
        -- Error(string): word0 = offset, then length + data.
        (word? args 0 0).bind fun off =>
        (word? args off 0).bind fun len =>
          if args.size < off + 32 + len then none
          else
            let s := asciiString (args.extract (off + 32) (off + 32 + len))
            match aaveErrorName s with
            | some name => some s!"Aave: {name} ({s})"
            | none      => some s
      else if sel = 0x4e487b71 then
        (word? args 0 0).map fun code => s!"Panic: {panicName code}"
      else if sel = 0x5a154675 then
        -- ExecuteError(uint256 index, bytes result) — BaseAccount
        -- executeBatch's per-leg wrapper. Legs are 0-based on-chain;
        -- report 1-based to match the confirm screen's "1) … 2) …".
        (word? args 0 0).bind fun idx =>
        (word? args 0 1).bind fun off =>
        (word? args off 0).bind fun len =>
          if args.size < off + 32 + len then none
          else
            let inner := args.extract (off + 32) (off + 32 + len)
            let innerMsg := (decodeBytes depth inner).getD
              (if inner.isEmpty then "no revert data" else s!"raw 0x{asciiString inner}")
            some s!"batch leg {idx + 1} reverted: {innerMsg}"
      else none

/-- Longest `0x…` hex run found in a backend's error/revert message.
    JSON-RPC errors embed the revert data as `"data":"0x08c379a0…"`
    inside the stringified error object; helios/viem messages embed it
    mid-sentence. 8+ hex chars filters out bare addresses' prefixes
    being cut short and plain `0x` markers. -/
private def extractBlob? (msg : String) : Option String := Id.run do
  let cs := msg.toList
  let mut best : List Char := []
  let mut i := cs
  while !i.isEmpty do
    match i with
    | '0' :: 'x' :: rest =>
        let run := rest.takeWhile (fun c => (hexDigit? c).isSome)
        if run.length > best.length then best := run
        i := rest.drop run.length
    | _ :: rest => i := rest
    | [] => pure ()
  if best.length ≥ 8 then return some (String.ofList best)
  return none

/-- Human-readable revert line from a backend's revert/error message,
    or `none` when the message carries no decodable revert data. -/
def humanize (msg : String) : Option String := do
  let blob ← extractBlob? msg
  let bs ← hexToBytes? blob
  decodeBytes 4 bs

end LeanCli.Ethereum.RevertDecode
