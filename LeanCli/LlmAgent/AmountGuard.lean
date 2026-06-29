/-!
# Output amount re-check (chat-drafted tx)

The verify-at-output half of the hybrid amount-authority design (the
prevent-at-input half is the `amountRef` tool schemas). After the agent
emits a `propose_send` with hand-built `value`/`data`, the daemon
re-decodes the magnitude back out of the draft and asserts it equals a
Lean-derived amount the daemon itself published. A magnitude the model
chose — rather than referenced — is rejected before the draft ever
reaches simulate / ConfirmGate.

This guards the *raw* `propose_send` path specifically: the `prepare_*`
builders resolve an `amountRef` and let the daemon encode the calldata,
so their magnitude is Lean's by construction. The raw path is the only
place an arbitrary number can still appear in calldata, and `revalidate`
is fail-closed there: a non-zero native value or a decodable
transfer/approve amount that matches no published amount is refused.

Pure module — no IO. The accept/reject decision is total and testable;
the proven spec for the underlying set-membership lives in
`LeanCli/Invariants/ChatAmount.lean` (`amountInTable_iff`).
-/

namespace LeanCli.LlmAgent.AmountGuard

/-- The unlimited-approval sentinel `2^256 - 1`. An `approve(spender,
    MAX)` is a fixed marker, not a model-chosen magnitude, so it is
    admitted without a matching amount. -/
def maxUint256 : Nat := 2 ^ 256 - 1

private def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat)
  else
    let lc := c.toLower
    if 'a' ≤ lc ∧ lc ≤ 'f' then some (10 + (lc.toNat - 'a'.toNat))
    else none

/-- Parse a hex string (no `0x`) as a `Nat`; `none` on any non-hex
    character or empty input. -/
def hexToNat? (s : String) : Option Nat :=
  if s.isEmpty then none
  else s.toList.foldl (fun acc c =>
    match acc, hexDigit? c with
    | some n, some d => some (n * 16 + d)
    | _, _           => none) (some 0)

/-- The `idx`-th 32-byte ABI word (0-based, after the 4-byte selector)
    of `data`, decoded as a `Nat`. `none` if the calldata is too short
    to contain a full word at that position. -/
def abiWord? (data : String) (idx : Nat) : Option Nat :=
  let body : String := if data.startsWith "0x" then (data.drop 2).toString else data
  let w : String := ((body.drop (8 + idx * 64)).take 64).toString
  if w.length == 64 then hexToNat? w else none

/-- Decode the amount field a known transfer/approve/supply/withdraw
    selector embeds, with a flag marking the approve selector (whose
    unlimited sentinel is admissible). `none` for calldata whose
    selector we don't model — opaque calldata carries no amount we can
    check here, so the caller still relies on the native-value check and
    on the `prepare_*` builders being Lean-encoded. -/
def decodeAmount? (data : String) : Option (Nat × Bool) :=
  let body : String := if data.startsWith "0x" then (data.drop 2).toString else data
  let sel := (body.take 8).toString.toLower
  let spec : Option (Nat × Bool) :=
    if sel == "a9059cbb" then some (1, false)      -- transfer(to, amount)
    else if sel == "095ea7b3" then some (1, true)  -- approve(spender, amount)
    else if sel == "23b872dd" then some (2, false) -- transferFrom(from, to, amount)
    else if sel == "617ba037" then some (1, false) -- aave supply(asset, amount, ...)
    else if sel == "69328dec" then some (1, false) -- aave withdraw(asset, amount, to)
    else none
  match spec with
  | some (idx, isApprove) => (abiWord? data idx).map (fun amt => (amt, isApprove))
  | none                  => none

/-- Re-check a drafted `{value, data}` against the Lean-derived
    `allowed` base-units amounts.

    * The native `value`, when non-zero, must equal an allowed amount —
      this is always checkable, so an opaque draft that carries value
      the model invented is still refused.
    * A decodable calldata amount must equal an allowed amount; the
      approve selector additionally admits the unlimited sentinel.
    * Selectors we don't decode pass the calldata check (no amount to
      compare) but never bypass the value check.

    Returns the first violation as an error string, or `()` when clean. -/
def revalidate (value : Nat) (data : String) (allowed : List Nat) :
    Except String Unit :=
  if value != 0 && !allowed.contains value then
    .error s!"drafted native value {value} wei matches no Lean-derived amount {allowed}; refusing a magnitude the model chose — reference it via amountRef"
  else
    match decodeAmount? data with
    | some (amt, isApprove) =>
        if isApprove && amt == maxUint256 then .ok ()
        else if amt != 0 && !allowed.contains amt then
          .error s!"drafted calldata amount {amt} matches no Lean-derived amount {allowed}; refusing a magnitude the model chose — reference it via amountRef"
        else .ok ()
    | none => .ok ()

end LeanCli.LlmAgent.AmountGuard
