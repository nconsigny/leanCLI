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

/-- `keccak256("ApprovalForAll(address,address,bool)")` — the blanket
operator approval emitted by both ERC-721 and ERC-1155 ("let this
operator move *all* my NFTs"). Highest-blast-radius NFT approval; the
one Revoke.cash surfaces most prominently. -/
def topicApprovalForAll : String :=
  "0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31"

/-- Permit2 (`0x0000…78BA3`, same address on every chain) allowance
events. `Approval` is the direct on-chain `approve`; `Permit` is the
signature-based grant. Both index `[owner, token, spender]`, so the same
parser handles either. -/
def topicPermit2Approval : String :=
  "0xda9fa7c1b00402c17d0161b249b1ab8bbec047c5a52207b9c112deffd817036b"
def topicPermit2Permit : String :=
  "0xc6a377bfc4eb120024a8ac08eef205be16b817020812c73223e81d1bdb9708ec"

/-- `isApprovedForAll(address owner, address operator)` → bool. -/
def selIsApprovedForAll : String := "0xe985e9c5"

/-- Permit2 `allowance(address owner, address token, address spender)`,
returning packed `(uint160 amount, uint48 expiration, uint48 nonce)` as
three ABI words. -/
def selPermit2Allowance : String := "0x927da105"

/-- Canonical Permit2 deployment address (lowercased for dedup keys). -/
def permit2Address : String := "0x000000000022d473030f116ddee9f6b43ac78ba3"

/-- `type(uint160).max` — Permit2's "unlimited allowance" sentinel
(distinct from the `type(uint256).max` sentinel ERC-20 approvals use). -/
def maxUint160 : Nat := 2 ^ 160 - 1

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

/-- Best-effort human label for a known spender / operator address, the
way Revoke.cash names the contract pulling your tokens. Display-only —
an unknown address returns `none` and the UI falls back to the raw 0x.
Addresses are mainnet-canonical (lowercased); testnet deployments differ
and are intentionally left unlabelled rather than mislabelled. -/
def spenderLabel (addr : String) : Option String :=
  let known : List (String × String) := [
    ("0x000000000022d473030f116ddee9f6b43ac78ba3", "Uniswap Permit2"),
    ("0xe592427a0aece92de3edee1f18e0157c05861564", "Uniswap V3 SwapRouter"),
    ("0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45", "Uniswap V3 SwapRouter02"),
    ("0x3fc91a3afd70395cd496c647d5a6cc9d4b2b7fad", "Uniswap UniversalRouter"),
    ("0x66a9893cc07d91d95644aedd05d03f95e1dba8af", "Uniswap UniversalRouter V2"),
    ("0x7a250d5630b4cf539739df2c5dacb4c659f2488d", "Uniswap V2 Router02"),
    ("0xc36442b4a4522e871399cd717abdd847ab11fe88", "Uniswap V3 NFT Position Manager"),
    ("0x111111125421ca6dc452d289314280a0f8842a65", "1inch Aggregation Router V6"),
    ("0x1111111254eeb25477b68fb85ed929f73a960582", "1inch Aggregation Router V5"),
    ("0xdef1c0ded9bec7f1a1670819833240f027b25eff", "0x Exchange Proxy"),
    ("0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2", "Aave V3 Pool"),
    ("0x7d2768de32b0b80b7a3454c06bdac94a69ddc7a9", "Aave V2 LendingPool"),
    ("0xba12222222228d8ba445958a75a0704d566bf2c8", "Balancer V2 Vault"),
    ("0xd9e1ce17f2641f24ae83637ab66a2cca9c378b9f", "SushiSwap Router")
  ]
  (known.find? (fun p => p.fst == addr.toLower)).map (·.snd)

/-- Attach a `spenderLabel`/`operatorLabel` field iff the address is
known. Keeps the row builders terse. -/
private def labelField (key : String) (addr : String) : Array (String × Json) :=
  match spenderLabel addr with
  | some l => #[(key, .str l)]
  | none   => #[]

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

/-! ## Approvals audit (`daemon.approvals.list`)

Standalone read-only scan: "what ERC-20 allowances does this wallet
currently have outstanding, and to whom?" Backs the chat `audit
approvals` / `show approvals` flow. Same trust posture as the other
probes — display-only, policy-gated, never authorises a signature. The
historical `Approval` log only tells us a spender was *once* approved;
the **current** `allowance(owner, spender)` is re-read live so a stale
event amount is never shown and already-revoked pairs drop out. -/

/-- Block window for the approvals scan. Kept at the same bound as the
preflight lookback because `eth_getLogs` with no contract-address filter
is the heaviest query we issue and public providers cap the range
(commonly 10k blocks). This is a recent-history best-effort, not an
exhaustive audit — the response reports the exact `fromBlock`/`toBlock`
scanned so the user knows the window. Raise via the RPC's `lookback`
param against an indexed provider. -/
def approvalsLookback : Nat := defaultLookback

/-- Parse one `Approval` log into `(token, spender, block)`. Topic layout
is `[sig, owner, spender]` (owner + spender both indexed), so the spender
is the 32-byte word at `topics[2]`. Lowercased so dedup keys are stable
across providers that checksum-case the `address` field. -/
private def parseApprovalLog (log : Json) : Option (String × String × Nat) := do
  let token       ← (getField "address" log) >>= asString
  let ts          ← (getField "topics" log) >>= asArray
  let spenderWord ← ts[2]? >>= asString
  let spender     ← decodeAddressFromWord (stripHexPrefix spenderWord)
  let blk : Nat := (((getField "blockNumber" log) >>= asString) >>= parseHexQuantity).getD 0
  some (token.toLower, spender.toLower, blk)

/-- Fold a `(token, spender, block)` triple into a deduped assoc list
keyed by `(token, spender)`, keeping the highest block seen. O(n²) but
n is the (small) number of distinct approvals. -/
private def upsertLatest
    (acc : List ((String × String) × Nat)) (token spender : String) (blk : Nat)
    : List ((String × String) × Nat) :=
  let key := (token, spender)
  if acc.any (fun e => e.fst == key) then
    acc.map (fun e => if e.fst == key then (e.fst, Nat.max e.snd blk) else e)
  else
    (key, blk) :: acc

/-- The "couldn't scan" response shape. `implemented := false` so the TUI
surfaces the `note` rather than rendering "0 approvals" (which would read
as "you have none" when the truth is "we couldn't look"). -/
private def approvalsUnavailable (chainId : Nat) (owner reason : String) : Json :=
  .obj #[
    ("chainId",     .num (Int.ofNat chainId)),
    ("wallet",      .str owner),
    ("approvals",   .arr #[]),
    ("implemented", .bool false),
    ("note",        .str reason)
  ]

/-- Parse the `i`-th 32-byte word (0-indexed) of an ABI return blob into
a `Nat`. Returns `none` when the blob is too short. -/
private def wordAt (retHex : String) (i : Nat) : Option Nat := do
  let body := stripHexPrefix retHex
  let w ← takeNibbles body (i * 64) 64
  parseHexQuantityDigits w.toList 0

/-- Parse one Permit2 `Approval`/`Permit` log into `(token, spender,
block)`. Topic layout is `[sig, owner, token, spender]` — all three of
owner/token/spender are indexed — so `token = topics[2]`, `spender =
topics[3]`. Lowercased for stable dedup keys. -/
private def parsePermit2Log (log : Json) : Option (String × String × Nat) := do
  let ts          ← (getField "topics" log) >>= asArray
  let tokenWord   ← ts[2]? >>= asString
  let spenderWord ← ts[3]? >>= asString
  let token       ← decodeAddressFromWord (stripHexPrefix tokenWord)
  let spender     ← decodeAddressFromWord (stripHexPrefix spenderWord)
  let blk : Nat := (((getField "blockNumber" log) >>= asString) >>= parseHexQuantity).getD 0
  some (token.toLower, spender.toLower, blk)

/-- `eth_call(isApprovedForAll(owner, operator))` on an ERC-721/1155
contract. Returns the live operator-approval bit (`none` if the call
reverts — e.g. the contract isn't actually an NFT). -/
private def readIsApprovedForAll
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia)
    (token owner operator : String) : IO (Option Bool) := do
  let data := selIsApprovedForAll
    ++ LeanCli.Swap.UniV3.encodeAddress owner
    ++ LeanCli.Swap.UniV3.encodeAddress operator
  match ← LeanCli.RPC.Outbound.ethCall policy endpoint token data "latest" via? with
  | .ok j =>
      match asString j with
      | some s => pure (some ((parseHexQuantity s).getD 0 ≠ 0))
      | none => pure none
  | .error _ => pure none

/-- `eth_call(allowance(owner, token, spender))` on the canonical Permit2
contract. Decodes the packed return into `(amount, expiration)` (the
trailing nonce word is ignored). `none` on revert / malformed data. -/
private def readPermit2Allowance
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia)
    (owner token spender : String) : IO (Option (Nat × Nat)) := do
  let data := selPermit2Allowance
    ++ LeanCli.Swap.UniV3.encodeAddress owner
    ++ LeanCli.Swap.UniV3.encodeAddress token
    ++ LeanCli.Swap.UniV3.encodeAddress spender
  match ← LeanCli.RPC.Outbound.ethCall policy endpoint permit2Address data "latest" via? with
  | .ok j =>
      match asString j with
      | some s =>
          match wordAt s 0, wordAt s 1 with
          | some amt, some exp => pure (some (amt, exp))
          | _, _ => pure none
      | none => pure none
  | .error _ => pure none

/-- Scan ERC-721/1155 `ApprovalForAll` operator approvals for `owner`
across all NFT contracts in the window. Mirrors the ERC-20 scan: discover
via logs, dedupe per `(contract, operator)`, then re-read the live
`isApprovedForAll` so revoked operators drop out. Best-effort — returns
`#[]` (not a failure) when the log query is unavailable. -/
private def scanApprovalForAll
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia)
    (chainId : Nat) (owner : String) (fromBlock head : Nat) : IO (Array Json) := do
  -- ApprovalForAll shares ERC-20 Approval's topic layout for the first
  -- two indexed args (owner, operator), so `parseApprovalLog` reads the
  -- operator out of topics[2] verbatim.
  let topics : Array Json := #[.str topicApprovalForAll, .str (paddedAddrTopic owner)]
  match ← LeanCli.RPC.Outbound.getLogsAnyAddress policy endpoint
      (natQuantityHex fromBlock) (natQuantityHex head) topics with
  | .error _ => pure #[]
  | .ok j =>
      match asArray j with
      | none => pure #[]
      | some logs =>
          let triples := logs.filterMap parseApprovalLog
          let deduped : List ((String × String) × Nat) :=
            triples.foldl (fun acc t => upsertLatest acc t.1 t.2.1 t.2.2) []
          let mut rows : Array Json := #[]
          for entry in deduped do
            let token    := entry.fst.fst
            let operator := entry.fst.snd
            let blk      := entry.snd
            match ← readIsApprovedForAll policy endpoint via? token owner operator with
            | some true =>
                let meta? ← LeanCli.Daemon.TokenMeta.lookupOrFetch
                  state policy endpoint chainId token
                let sym := match meta? with | some m => m.symbol | none => ""
                rows := rows.push <| .obj (#[
                  ("token",         .str token),
                  ("operator",      .str operator),
                  ("approved",      .bool true),
                  ("tokenSymbol",   .str sym),
                  ("standard",      .str "ERC-721/1155 ApprovalForAll"),
                  ("lastSeenBlock", .num (Int.ofNat blk))
                ] ++ labelField "operatorLabel" operator)
            | _ => pure ()  -- false / revoked / not-an-NFT: skip
          pure rows

/-- Scan Permit2 allowances granted by `owner`. Lighter than the ERC-20
sweep — the logs are address-filtered to the single Permit2 contract.
Matches both the `Approval` and `Permit` event topics, dedupes per
`(token, spender)`, and re-reads the live packed allowance so spent /
expired-to-zero grants drop out. Best-effort — `#[]` on log failure. -/
private def scanPermit2
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia)
    (chainId : Nat) (owner : String) (fromBlock head : Nat) : IO (Array Json) := do
  -- topic0 alternation `[Approval | Permit]`, topic1 = owner.
  let topics : Array Json := #[
    .arr #[.str topicPermit2Approval, .str topicPermit2Permit],
    .str (paddedAddrTopic owner)
  ]
  match ← LeanCli.RPC.Outbound.getLogs policy endpoint
      (natQuantityHex fromBlock) (natQuantityHex head) permit2Address topics via? with
  | .error _ => pure #[]
  | .ok j =>
      match asArray j with
      | none => pure #[]
      | some logs =>
          let triples := logs.filterMap parsePermit2Log
          let deduped : List ((String × String) × Nat) :=
            triples.foldl (fun acc t => upsertLatest acc t.1 t.2.1 t.2.2) []
          let mut rows : Array Json := #[]
          for entry in deduped do
            let token   := entry.fst.fst
            let spender := entry.fst.snd
            let blk     := entry.snd
            match ← readPermit2Allowance policy endpoint via? owner token spender with
            | some (amt, exp) =>
                if amt > 0 then
                  let meta? ← LeanCli.Daemon.TokenMeta.lookupOrFetch
                    state policy endpoint chainId token
                  let sym := match meta? with | some m => m.symbol | none => ""
                  let human :=
                    if amt = maxUint160 then "unlimited (max uint160)"
                    else renderAmount amt meta?
                  rows := rows.push <| .obj (#[
                    ("token",         .str token),
                    ("spender",       .str spender),
                    ("amount",        .str (toString amt)),
                    ("amountHuman",   .str human),
                    ("tokenSymbol",   .str sym),
                    ("expiration",    .num (Int.ofNat exp)),
                    ("via",           .str "Permit2"),
                    ("lastSeenBlock", .num (Int.ofNat blk))
                  ] ++ labelField "spenderLabel" spender)
            | none => pure ()  -- allowance read failed; skip, don't fabricate
          pure rows

/-- Scan outgoing approvals for `owner` over the last `lookback` blocks
and return the TUI-shaped audit JSON. Covers the three approval surfaces
Revoke.cash discovers, each in its own array:

* `approvals` — ERC-20 `allowance(owner, spender)` (token, spender,
  amount, amountHuman, tokenSymbol, lastSeenBlock, +spenderLabel).
* `nftApprovals` — ERC-721/1155 `ApprovalForAll` operator grants
  (token, operator, approved, +operatorLabel).
* `permit2Approvals` — Uniswap Permit2 `allowance(owner, token, spender)`
  packed grants (token, spender, amount, expiration, via, +spenderLabel).

Each surface discovers via its event logs across **all** contracts
(owner-filtered topic1; Permit2 additionally address-filtered to the
canonical contract), dedupes to the latest event per pair, **re-reads
the live on-chain state**, and drops zero/revoked/false entries — so a
stale event amount is never shown. ERC-20 unlimited renders as
`"unlimited (max uint256)"`, Permit2 as `"unlimited (max uint160)"`.
NFT and Permit2 scans are additive and best-effort (empty on provider
failure); only an ERC-20 head/log failure yields the `implemented :=
false` shape. -/
def auditApprovals
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (chainId : Nat) (owner : String) (lookback : Nat) : IO Json := do
  let via? ← LeanCli.Daemon.State.buildColibriVia state chainId
  match ← readBlockNumber policy endpoint via? with
  | none =>
      pure <| approvalsUnavailable chainId owner
        "eth_blockNumber unavailable on this provider; cannot scan approvals"
  | some head =>
      let fromBlock := if head ≤ lookback then 0 else head - lookback
      -- topic0 = Approval, topic1 = owner (left-padded). topic2 (spender)
      -- is left unconstrained so every spender is caught.
      let topics : Array Json := #[.str topicApproval, .str (paddedAddrTopic owner)]
      match ← LeanCli.RPC.Outbound.getLogsAnyAddress policy endpoint
          (natQuantityHex fromBlock) (natQuantityHex head) topics with
      | .error e =>
          pure <| approvalsUnavailable chainId owner
            s!"eth_getLogs failed on this provider: {e}"
      | .ok j =>
          match asArray j with
          | none =>
              pure <| approvalsUnavailable chainId owner
                "eth_getLogs returned a non-array result"
          | some logs =>
              let triples := logs.filterMap parseApprovalLog
              let deduped : List ((String × String) × Nat) :=
                triples.foldl (fun acc t => upsertLatest acc t.1 t.2.1 t.2.2) []
              let mut rows : Array Json := #[]
              for entry in deduped do
                let token   := entry.fst.fst
                let spender := entry.fst.snd
                let blk     := entry.snd
                match ← readAllowance policy endpoint via? token owner spender with
                | some amt =>
                    -- Drop pairs whose live allowance is 0: already
                    -- revoked or spent down — nothing actionable to show.
                    if amt > 0 then
                      let meta? ← LeanCli.Daemon.TokenMeta.lookupOrFetch
                        state policy endpoint chainId token
                      let sym := match meta? with | some m => m.symbol | none => ""
                      rows := rows.push <| .obj (#[
                        ("token",         .str token),
                        ("spender",       .str spender),
                        ("amount",        .str (toString amt)),
                        ("amountHuman",   .str (renderApproveAmount amt meta?)),
                        ("tokenSymbol",   .str sym),
                        ("lastSeenBlock", .num (Int.ofNat blk))
                      ] ++ labelField "spenderLabel" spender)
                | none => pure ()  -- allowance read failed; skip, don't fabricate
              -- Additive coverage: NFT operator approvals + Permit2 grants.
              -- Both are best-effort and return #[] on provider failure, so
              -- the ERC-20 result is never blocked on them.
              let nftRows ← scanApprovalForAll state policy endpoint via? chainId owner fromBlock head
              let permit2Rows ← scanPermit2 state policy endpoint via? chainId owner fromBlock head
              pure <| .obj #[
                ("chainId",          .num (Int.ofNat chainId)),
                ("wallet",           .str owner),
                ("approvals",        .arr rows),
                ("nftApprovals",     .arr nftRows),
                ("permit2Approvals", .arr permit2Rows),
                ("implemented",      .bool true),
                ("fromBlock",        .num (Int.ofNat fromBlock)),
                ("toBlock",          .num (Int.ofNat head)),
                ("note",             .str s!"scanned blocks {fromBlock}–{head}: {rows.size} ERC-20 allowance(s), {nftRows.size} NFT operator approval(s), {permit2Rows.size} Permit2 grant(s); zero/revoked omitted, all amounts re-read live")
              ]

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
