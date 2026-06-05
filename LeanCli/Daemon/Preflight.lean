import LeanCli.Daemon.State
import LeanCli.Daemon.TokenMeta
import LeanCli.RPC.Outbound
import LeanCli.Network.Policy
import LeanCli.Encoding.Json
import LeanCli.Crypto.Hex
import LeanCli.Swap.UniV3
import LeanCli.Util.Units

/-!
# Pre-confirm chain probing

Surfaces "what does the chain currently say?" alongside the
deterministic simulate output so the user has the context to spot
silent footguns at confirm time:

* `erc20Approve` — current allowance vs. the new amount the tx will
  set, plus the delta tag (noop / increase / decrease / revoke). Catches
  the "this approval is a no-op" and "you're already approved for more"
  cases that simulate alone cannot flag.
* `erc20Transfer` / native — sender balance, the amount, the post-tx
  balance, and an `insufficient` flag. Catches off-by-zero amounts that
  pass simulation (e.g. sending 10 USDC because the user meant 0.1).
* Both — counterparty prior-interaction probe over a bounded recent
  block window. Surfaces a "first interaction with this address" soft
  warning, scoped by token (Approval / Transfer event logs).

Trust model: results are display-only. The signer never sees this; we
still simulate + canonicalise + decode before any signature lands.
-/

namespace LeanCli.Daemon.Preflight

open LeanCli.Encoding.Json
open LeanCli.Util.Units

/-! ## hex / 4-byte selectors -/

/-- The window of recent blocks scanned for prior-interaction logs.
The lower bound (5_000) matches `chain.scanTransfers`' default chunk;
public RPC providers typically cap eth_getLogs at 10k. Increase via
`LEANCLI_PREFLIGHT_LOOKBACK` for indexed providers. -/
def defaultLookback : Nat := 5000

private def stripHexPrefix (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then (s.drop 2).toString else s

private def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c ∧ c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
  else if 'A' ≤ c ∧ c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
  else none

private def parseHexQuantityDigits : List Char → Nat → Option Nat
  | [], acc => some acc
  | c :: cs, acc => do
      let d ← hexDigit? c
      parseHexQuantityDigits cs (acc * 16 + d)

/-- Parse a `0x...` hex quantity (allowing leading zeros). Returns `none`
on an empty or malformed input. -/
def parseHexQuantity (s : String) : Option Nat :=
  let raw := stripHexPrefix s
  if raw.isEmpty then none
  else parseHexQuantityDigits raw.toList 0

/-- Encode a `Nat` as a `0x`-prefixed hex quantity (no leading zeros,
`0x0` for zero). -/
def natQuantityHex (n : Nat) : String :=
  if n = 0 then "0x0"
  else
    let rec toHex (k : Nat) (acc : String) (fuel : Nat) : String :=
      match fuel with
      | 0 => acc
      | fuel + 1 =>
          if k = 0 then acc
          else
            let d := k % 16
            let c := LeanCli.Crypto.Hex.nibbleToChar (UInt8.ofNat d)
            toHex (k / 16) (String.ofList [c] ++ acc) fuel
    "0x" ++ toHex n "" 256

/-- ERC-20 selectors. -/
def selTransfer : String := "a9059cbb"
def selApprove  : String := "095ea7b3"
def selBalanceOf : String := "0x70a08231"
def selAllowance : String := "0xdd62ed3e"

/-- `keccak256("Transfer(address,address,uint256)")`. -/
def topicTransfer : String :=
  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

/-- `keccak256("Approval(address,address,uint256)")`. -/
def topicApproval : String :=
  "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

/-- 2^256 - 1, the canonical "unlimited" allowance sentinel. -/
def maxUint256 : Nat := LeanCli.Swap.UniV3.maxUint256

/-- 32-byte left-padded topic value for an address. -/
private def paddedAddrTopic (addr : String) : String :=
  "0x" ++ LeanCli.Swap.UniV3.encodeAddress addr

/-! ## Calldata classification -/

inductive CallKind where
  | native  -- value transfer, empty data
  | approve (spender : String) (amount : Nat)
  | transfer (recipient : String) (amount : Nat)
  | other (selector : String)
  deriving Repr

/-- Pull `width` hex chars from `body` starting at nibble offset `off`.
Returns `none` if out of range. -/
private def takeNibbles (body : String) (off width : Nat) : Option String :=
  if off + width > body.length then none
  else some ((body.drop off).take width |>.toString)

/-- The address word is right-aligned in 32 bytes — only the last 20
bytes (40 hex chars) are the address. We surface the lower 40 hex
nibbles as a `0x`-prefixed address with no checksum (downstream
display will checksum-format if needed). -/
private def decodeAddressFromWord (word : String) : Option String := do
  if word.length ≠ 64 then none
  else some ("0x" ++ (word.drop 24).toString)

/-- Try to parse a `Nat` from a 32-byte hex word. -/
private def decodeUintFromWord (word : String) : Option Nat :=
  parseHexQuantityDigits word.toList 0

/-- Classify `(value, data)` into one of the recognised intent kinds.
Native = empty data + nonzero value (or empty data + zero value, which
the daemon canonicalises as `nativeTransfer` to 0 — still safe to show
"balance + amount = 0"). -/
def classify (valueHex : String) (data : String) : CallKind :=
  let body := stripHexPrefix data
  if body.isEmpty then .native
  else if body.length < 8 then .other body
  else
    let _ := valueHex  -- value only matters for the .native branch
    let selector := (body.take 8).toString
    if selector = selTransfer ∧ body.length ≥ 8 + 64 + 64 then
      match takeNibbles body 8 64, takeNibbles body 72 64 with
      | some recipWord, some amtWord =>
          match decodeAddressFromWord recipWord, decodeUintFromWord amtWord with
          | some recip, some amt => .transfer recip amt
          | _, _ => .other selector
      | _, _ => .other selector
    else if selector = selApprove ∧ body.length ≥ 8 + 64 + 64 then
      match takeNibbles body 8 64, takeNibbles body 72 64 with
      | some spenderWord, some amtWord =>
          match decodeAddressFromWord spenderWord, decodeUintFromWord amtWord with
          | some sp, some amt => .approve sp amt
          | _, _ => .other selector
      | _, _ => .other selector
    else .other selector

/-! ## Display helpers -/

/-- Render a base-units amount with a token's symbol. Falls back to the
raw integer + short-address tag when we don't have decimals. -/
private def renderAmount (amt : Nat) (meta? : Option LeanCli.Daemon.TokenMeta.TokenMeta) : String :=
  match meta? with
  | some m => s!"{formatUnits amt m.decimals} {m.symbol}"
  | none   => toString amt

/-- Same as `renderAmount` but yields `"unlimited (max uint256)"` when
the value equals `2^256 - 1` — the conventional infinite-approval
sentinel. -/
private def renderApproveAmount (amt : Nat) (meta? : Option LeanCli.Daemon.TokenMeta.TokenMeta) : String :=
  if amt = maxUint256 then "unlimited (max uint256)"
  else renderAmount amt meta?

/-- Classify the change from `curr` → `new` for an approve call. -/
private def approveDelta (curr new : Nat) : String :=
  if curr = new then "noop (already at this allowance)"
  else if new = 0 then "revoke"
  else if curr = 0 then "first grant"
  else if new > curr then "increase"
  else "decrease"

/-! ## Probes -/

/-- `eth_call(allowance(owner, spender))` on the token contract. -/
private def readAllowance
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia)
    (token owner spender : String) : IO (Option Nat) := do
  let data := selAllowance ++ LeanCli.Swap.UniV3.encodeAddress owner ++ LeanCli.Swap.UniV3.encodeAddress spender
  match ← LeanCli.RPC.Outbound.ethCall policy endpoint token data "latest" via? with
  | .ok j =>
      match asString j with
      | some s => pure (parseHexQuantity s)
      | none => pure none
  | .error _ => pure none

/-- `eth_call(balanceOf(owner))` on the token contract. -/
private def readErc20Balance
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia)
    (token owner : String) : IO (Option Nat) := do
  let data := selBalanceOf ++ LeanCli.Swap.UniV3.encodeAddress owner
  match ← LeanCli.RPC.Outbound.ethCall policy endpoint token data "latest" via? with
  | .ok j =>
      match asString j with
      | some s => pure (parseHexQuantity s)
      | none => pure none
  | .error _ => pure none

/-- `eth_getBalance(owner)`. -/
private def readNativeBalance
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia)
    (owner : String) : IO (Option Nat) := do
  match ← LeanCli.RPC.Outbound.getBalance policy endpoint owner "latest" via? with
  | .ok j =>
      match asString j with
      | some s => pure (parseHexQuantity s)
      | none => pure none
  | .error _ => pure none

/-- `eth_blockNumber`. -/
private def readBlockNumber
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia) : IO (Option Nat) := do
  match ← LeanCli.RPC.Outbound.blockNumber policy endpoint via? with
  | .ok j =>
      match asString j with
      | some s => pure (parseHexQuantity s)
      | none => pure none
  | .error _ => pure none

/-- Count prior `Approval(owner, spender)` or `Transfer(from, to)`
events on `tokenAddr` within the last `lookback` blocks. The window is
deliberately small (default 5000 blocks ≈ 17h on mainnet) because
public RPCs cap eth_getLogs ranges; this is a best-effort signal
("first-ever interaction" warning), not a complete audit. Returns the
event count and the inclusive block range scanned. -/
private def countPriorEvents
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia)
    (tokenAddr topic0 partyA partyB : String)
    (lookback : Nat) : IO (Option (Nat × Nat × Nat)) := do
  match ← readBlockNumber policy endpoint via? with
  | none => pure none
  | some head =>
      let fromBlock := if head ≤ lookback then 0 else head - lookback
      let topics : Array Json := #[
        .str topic0,
        .str (paddedAddrTopic partyA),
        .str (paddedAddrTopic partyB)
      ]
      match ← LeanCli.RPC.Outbound.getLogs policy endpoint
          (natQuantityHex fromBlock) (natQuantityHex head)
          tokenAddr topics via? with
      | .ok j =>
          match asArray j with
          | some logs => pure (some (logs.size, fromBlock, head))
          | none => pure none
      | .error _ => pure none

/-! ## Top-level run

`run` is the only public entry point. It accepts the same shape as
`tx.simulate` (chainId / from / to / value / data) and returns a JSON
object the TUI renders into a "chain context" block. The shape varies
by `kind` so the UI can render slot-by-slot — every variant carries
`{"kind": <tag>}` plus the action-specific fields. -/
def run
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (chainId : Nat) (fromAddr to valueHex data : String)
    (lookback : Nat) : IO Json := do
  let via? ← LeanCli.Daemon.State.buildColibriVia state chainId
  let kind := classify valueHex data
  match kind with
  | .native =>
      let value := (parseHexQuantity valueHex).getD 0
      let balOpt ← readNativeBalance policy endpoint via? fromAddr
      let balField : Array (String × Json) :=
        match balOpt with
        | some b => #[
            ("senderBalance", .str (natQuantityHex b)),
            ("senderBalanceHuman", .str (formatUnits b 18 ++ " ETH")),
            ("amountHuman", .str (formatUnits value 18 ++ " ETH")),
            ("afterHuman",
              .str ((if value ≤ b then formatUnits (b - value) 18 else "—") ++ " ETH")),
            ("insufficient", .bool (value > b))
          ]
        | none => #[("probeError", .str "eth_getBalance failed")]
      pure <| .obj <| #[
        ("kind", .str "native"),
        ("priorInteractions", .obj #[
          ("available", .bool false),
          ("reason", .str "native ETH transfers are not indexed by eth_getLogs")
        ])
      ] ++ balField
  | .transfer recipient amount =>
      let metaOpt ← LeanCli.Daemon.TokenMeta.lookupOrFetch state policy endpoint chainId to
      let balOpt ← readErc20Balance policy endpoint via? to fromAddr
      let priorOpt ← countPriorEvents policy endpoint via? to topicTransfer fromAddr recipient lookback
      let balField : Array (String × Json) :=
        match balOpt with
        | some b => #[
            ("senderBalance", .str (natQuantityHex b)),
            ("senderBalanceHuman", .str (renderAmount b metaOpt)),
            ("insufficient", .bool (amount > b)),
            ("afterHuman", .str
              (if amount ≤ b then renderAmount (b - amount) metaOpt else "—"))
          ]
        | none => #[("probeError", .str "balanceOf failed")]
      let priorField : Array (String × Json) :=
        match priorOpt with
        | some (n, fb, tb) => #[
            ("priorInteractions", .obj #[
              ("available", .bool true),
              ("count", .num (Int.ofNat n)),
              ("fromBlock", .num (Int.ofNat fb)),
              ("toBlock", .num (Int.ofNat tb)),
              ("scope", .str "Transfer event on this token between sender and recipient")
            ])]
        | none => #[("priorInteractions", .obj #[
            ("available", .bool false),
            ("reason", .str "eth_getLogs unavailable on this RPC")
          ])]
      pure <| .obj <| #[
        ("kind", .str "transfer"),
        ("token", .str to),
        ("recipient", .str recipient),
        ("amount", .str (natQuantityHex amount)),
        ("amountHuman", .str (renderAmount amount metaOpt))
      ] ++ balField ++ priorField
  | .approve spender newAmount =>
      let metaOpt ← LeanCli.Daemon.TokenMeta.lookupOrFetch state policy endpoint chainId to
      let allowOpt ← readAllowance policy endpoint via? to fromAddr spender
      let priorOpt ← countPriorEvents policy endpoint via? to topicApproval fromAddr spender lookback
      let allowField : Array (String × Json) :=
        match allowOpt with
        | some curr => #[
            ("currentAllowance", .str (natQuantityHex curr)),
            ("currentAllowanceHuman", .str (renderApproveAmount curr metaOpt)),
            ("delta", .str (approveDelta curr newAmount))
          ]
        | none => #[("probeError", .str "allowance() failed")]
      let priorField : Array (String × Json) :=
        match priorOpt with
        | some (n, fb, tb) => #[
            ("priorInteractions", .obj #[
              ("available", .bool true),
              ("count", .num (Int.ofNat n)),
              ("fromBlock", .num (Int.ofNat fb)),
              ("toBlock", .num (Int.ofNat tb)),
              ("scope", .str "Approval event on this token between owner and spender")
            ])]
        | none => #[("priorInteractions", .obj #[
            ("available", .bool false),
            ("reason", .str "eth_getLogs unavailable on this RPC")
          ])]
      pure <| .obj <| #[
        ("kind", .str "approve"),
        ("token", .str to),
        ("spender", .str spender),
        ("newAmount", .str (natQuantityHex newAmount)),
        ("newAmountHuman", .str (renderApproveAmount newAmount metaOpt))
      ] ++ allowField ++ priorField
  | .other selector =>
      pure <| .obj #[
        ("kind", .str "other"),
        ("selector", .str ("0x" ++ selector))
      ]

end LeanCli.Daemon.Preflight
