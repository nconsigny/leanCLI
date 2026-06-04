import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.TokenRegistry
import LeanCli.Swap.Tokens
import LeanCli.Swap.UniV3
import LeanCli.Aave.V3Pool
import LeanCli.Wallet.ExecuteBatch

/-!
# One-shot Aave V3 transaction preparation

Mirrors `LeanCli/Swap/Prepare.lean` for the Aave V3 Pool. A single
Lean-side function per action (supply, withdraw, borrow, repay,
setUseReserveAsCollateral) that bundles the work an agent would
otherwise do as a chain of low-level reads:

  1. resolve the chain (mainnet / sepolia) and the canonical Pool address;
  2. resolve `asset` (symbol or 0x-address) against the token registry;
  3. for token-in actions (supply, repay) read ERC-20 `allowance(sender, Pool)`;
  4. encode the Pool action calldata;
  5. branch on the allowance to produce either `.ready` or `.needsApproval`;
  6. attach a human-readable `summaryForConfirm` string.

This module is read-only — it never signs, never broadcasts. The
resulting `TxFrame`s flow downstream through
`decodeIntent → simulate → ConfirmGate → eoa.send`, identical to every
other calldata-producing surface.

## EOA vs smart-wallet output shape

Today this module emits separate `approve` + `action` frames, identical
to `Swap/Prepare.lean`. EOAs propose them sequentially; the
smart-wallet (4337 / r1 / sphincs) batched path is a follow-up that
will wrap the same two frames into a single `executeBatch` at the
account-abstraction layer. The Pool-side calldata produced here is the
same in either case.

## Trust model

Reads pass through the caller's `ChainEthCallShim`, which the daemon
wires to its policy-gated `Outbound.ethCall` (so `NetworkPolicy`
applies). No signing primitive is referenced.

`autoImplicit := false` clean. No raw `Nat.sub` on balances.
-/

namespace LeanCli.Aave.Prepare

open LeanCli.Encoding.Json (Json)
open LeanCli.Swap
open LeanCli.Aave
open LeanCli.Wallet.ExecuteBatch (AccountKindHint encodeExecuteBatch)

/-! ## Wire types -/

/-- A bare transaction frame: just enough fields for the downstream
    `decodeIntent → simulate → ConfirmGate` pipeline. `value` is in wei;
    `data` is `0x`-prefixed lowercase hex. -/
structure TxFrame where
  to : String
  value : Nat
  data : String
  chainId : Nat
  deriving Repr

/-- Chain-read shim: the daemon supplies a closure that wraps its
    existing policy-gated `chain.ethCall`. Returns either `0x`-prefixed
    return data or a human-readable error. -/
abbrev ChainEthCallShim :=
  (to : String) → (data : String) → (chainId : Nat) → IO (Except String String)

/-- The 2^256-1 "infinite" sentinel used by the Aave Pool for "full
    balance" semantics on `withdraw` and `repay`. -/
def maxUint256 : Nat :=
  115792089237316195423570985008687907853269984665640564039457584007913129639935

/-- Result of any Aave prepare call. Discriminator is identical to the
    Uniswap shape so the agent envelope (`UniV3Swap.envelopeFromDaemon`)
    can be reused. -/
inductive PrepareResult where
  /-- Action does not need an allowance bump (or current allowance is
      already ≥ requested amount). Single `action` tx. -/
  | ready
      (action : TxFrame)
      (summaryForConfirm : String)
  /-- Action requires an ERC-20 approval first. Approve uses
      `maxUint256` so the user does not have to re-approve on the next
      action of the same asset — surfaced loudly in `summaryForConfirm`. -/
  | needsApproval
      (approve : TxFrame)
      (action : TxFrame)
      (currentAllowance : Nat)
      (required : Nat)
      (summaryForConfirm : String)
  /-- Anything that prevents producing the action. `kind` is a stable
      machine-readable tag (`unknown_asset`, `unsupported_chain`,
      `allowance_read_failed`, `invalid_address`, `unknown_pool`,
      `invalid_rate_mode`). -/
  | err (kind : String) (msg : String)
  deriving Repr

/-! ## Pure helpers -/

/-- Symbol or 0x-prefixed address → resolved lowercase address with
    optional `Token` metadata (decimals + symbol) when known.
    Identical shape to `Swap.Prepare.resolveToken` so summaries can
    re-use the same labeling helpers. -/
def resolveAsset (input : String) (chain : Tokens.ChainId) :
    Option (Option Tokens.Token × String) :=
  let s := input.trimAscii.toString
  if s.startsWith "0x" || s.startsWith "0X" then
    match LeanCli.Ethereum.Address.fromHex s with
    | some _ => some (none, s.toLower)
    | none => none
  else
    Tokens.resolve s chain

/-- Chain-id → `ChainId` enum. `none` for unsupported chains so the
    caller can surface a stable error code rather than dialing an
    unconfigured RPC. -/
def chainIdToEnum? (n : Nat) : Option Tokens.ChainId :=
  if n = 1 then some .mainnet
  else if n = 11155111 then some .sepolia
  else none

/-- Pretty-print an amount in human units. On parse failure falls back
    to the raw base-units integer so the summary still renders. -/
def fmtAmount (n : Nat) (decimals : Nat) : String :=
  match LeanCli.Ethereum.TokenRegistry.humanUnits (toString n) decimals with
  | .ok s => s
  | .error _ => toString n

/-- Display label: prefer the registry symbol, fall back to the short
    address (first 6 + last 4 hex chars). -/
def labelFor (tok? : Option Tokens.Token) (addr : String) : String :=
  match tok? with
  | some t => t.symbol
  | none =>
    let s := addr
    if s.length ≥ 12 then
      (s.take 6).toString ++ "…" ++ (s.drop (s.length - 4)).toString
    else s

/-- Render an amount with the `"MAX"` sentinel highlighted, used for the
    `withdraw` / `repay` full-balance convention. -/
def fmtAmountOrMax (n : Nat) (decimals : Nat) : String :=
  if n = maxUint256 then "MAX (full balance)" else fmtAmount n decimals

/-! ## JSON encoder -/

/-- Encode a `TxFrame` as a JSON object matching the shape the agent's
    `propose_send` tool consumes. -/
def TxFrame.toJson (f : TxFrame) : Json :=
  .obj #[
    ("to",      .str f.to),
    ("value",   .num (Int.ofNat f.value)),
    ("data",    .str f.data),
    ("chainId", .num (Int.ofNat f.chainId))
  ]

/-- Encode a `PrepareResult` as JSON for the `aave.prepare*` RPC family.
    Discriminator `"status"` is `"ready"`, `"needs_approval"`, or
    `"error"` — same shape as `swap.prepareUniswapV3` so the agent
    envelope is reusable. Note: the action TxFrame is exposed as `"action"`
    on both `ready` and `needs_approval` so the agent does not have to
    know which Aave verb produced the result. -/
def PrepareResult.toJson : PrepareResult → Json
  | .ready action summary =>
      .obj #[
        ("status",            .str "ready"),
        ("action",            action.toJson),
        ("summaryForConfirm", .str summary)
      ]
  | .needsApproval approve action currentAllowance required summary =>
      .obj #[
        ("status",            .str "needs_approval"),
        ("approve",           approve.toJson),
        ("action",            action.toJson),
        ("currentAllowance",  .num (Int.ofNat currentAllowance)),
        ("required",          .num (Int.ofNat required)),
        ("summaryForConfirm", .str summary)
      ]
  | .err kind msg =>
      .obj #[
        ("status", .str "error"),
        ("kind",   .str kind),
        ("error",  .str msg)
      ]

/-! ## Common entry-point preamble

Every prepare call goes through `resolveContext` first: validate the
sender / on-behalf-of address shape, resolve the chain enum, find the
canonical Pool address, and resolve the asset. Errors short-circuit
with the matching stable `kind`. -/

/-- Context resolved once per prepare call: enum chain id, Pool address,
    asset registry hit (if any), and the lowercased 0x asset address. -/
structure Context where
  chain : Tokens.ChainId
  pool : String
  asset? : Option Tokens.Token
  assetAddr : String

/-- Resolve the per-action shared context. `sender` must be a valid
    20-byte address (we sanity-check the format here; chain-side
    validation happens at simulate time). `secondAddr` is the
    `onBehalfOf` / `recipient` argument that varies by action. -/
def resolveContext
    (chainId : Nat) (sender secondAddr : String) (asset : String) :
    Except PrepareResult Context := do
  let some chain := chainIdToEnum? chainId
    | .error <| .err "unsupported_chain"
        s!"chainId {chainId} is not supported (only 1 / 11155111 today)"
  let some _ := LeanCli.Ethereum.Address.fromHex sender
    | .error <| .err "invalid_address"
        s!"sender is not a 0x-prefixed 20-byte address: {sender}"
  let some _ := LeanCli.Ethereum.Address.fromHex secondAddr
    | .error <| .err "invalid_address"
        s!"second address (onBehalfOf/recipient/to) is not a 20-byte address: {secondAddr}"
  let some pool := V3Pool.poolForChainId chainId
    | .error <| .err "unknown_pool"
        s!"Aave V3 Pool address unknown on chainId {chainId}"
  let some (asset?, assetAddr) := resolveAsset asset chain
    | .error <| .err "unknown_asset"
        s!"asset {asset} is not a registered symbol on this chain and is not a valid 0x address"
  pure { chain := chain, pool := pool, asset? := asset?, assetAddr := assetAddr }

/-- Read `allowance(owner, spender)` via the shim and decode the first
    32-byte word. Surfaces `allowance_read_failed` on transport or
    malformed return data. -/
def readAllowance
    (shim : ChainEthCallShim) (chainId : Nat)
    (assetAddr owner spender : String) : IO (Except PrepareResult Nat) := do
  let data := LeanCli.Swap.UniV3.encodeAllowance owner spender
  match ← shim assetAddr data chainId with
  | .error e => pure (.error (.err "allowance_read_failed" e))
  | .ok hex =>
    match LeanCli.Swap.UniV3.decodeWordAt hex 0 with
    | none =>
        pure <| .error <| .err "allowance_read_failed"
          s!"allowance() returned malformed data: {hex}"
    | some current => pure (.ok current)

/-- Branch on the allowance: if `current ≥ required` return `.ready`,
    else attach a `maxUint256` approval to the asset and return
    `.needsApproval`. Common to `supply` and `repay`. -/
def attachAllowance
    (action : TxFrame)
    (currentAllowance required : Nat)
    (assetAddr pool : String)
    (chainId : Nat)
    (summary : String) : PrepareResult :=
  if currentAllowance ≥ required then
    .ready action summary
  else
    let approveData :=
      LeanCli.Swap.UniV3.encodeApprove pool LeanCli.Swap.UniV3.maxUint256
    let approve : TxFrame :=
      { to := assetAddr, value := 0, data := approveData, chainId := chainId }
    .needsApproval approve action currentAllowance required summary

/-! ## Action: supply -/

/-- `Pool.supply(asset, amount, onBehalfOf, 0)`. Reads `allowance(sender,
    Pool)`; emits `approve` first when needed. -/
def prepareSupply
    (chainId : Nat) (sender onBehalfOf asset : String) (amount : Nat)
    (shim : ChainEthCallShim) : IO PrepareResult := do
  match resolveContext chainId sender onBehalfOf asset with
  | .error r => pure r
  | .ok ctx =>
    match ← readAllowance shim chainId ctx.assetAddr sender ctx.pool with
    | .error r => pure r
    | .ok current =>
      let data := V3Pool.encodeSupply ctx.assetAddr amount onBehalfOf 0
      let action : TxFrame :=
        { to := ctx.pool, value := 0, data := data, chainId := chainId }
      let decimals := (ctx.asset?.map (·.decimals)).getD 18
      let label := labelFor ctx.asset? ctx.assetAddr
      let amountStr := fmtAmount amount decimals
      let onBehalfNote :=
        if onBehalfOf.toLower = sender.toLower then ""
        else s!" on behalf of {onBehalfOf}"
      let summary := s!"Aave V3 supply {amountStr} {label} → Pool{onBehalfNote}"
      pure <| attachAllowance action current amount
        ctx.assetAddr ctx.pool chainId summary

/-! ## Action: withdraw -/

/-- `Pool.withdraw(asset, amount, to)`. No allowance needed (it operates
    on the user's aToken balance). `amount = 2^256 - 1` is the Pool's
    documented "withdraw full balance" sentinel. -/
def prepareWithdraw
    (chainId : Nat) (sender recipient asset : String) (amount : Nat)
    (_shim : ChainEthCallShim) : IO PrepareResult := do
  match resolveContext chainId sender recipient asset with
  | .error r => pure r
  | .ok ctx =>
    let data := V3Pool.encodeWithdraw ctx.assetAddr amount recipient
    let action : TxFrame :=
      { to := ctx.pool, value := 0, data := data, chainId := chainId }
    let decimals := (ctx.asset?.map (·.decimals)).getD 18
    let label := labelFor ctx.asset? ctx.assetAddr
    let amountStr := fmtAmountOrMax amount decimals
    let toNote :=
      if recipient.toLower = sender.toLower then ""
      else s!" → {recipient}"
    let summary := s!"Aave V3 withdraw {amountStr} {label} from Pool{toNote}"
    pure (.ready action summary)

/-! ## Action: borrow -/

/-- `Pool.borrow(asset, amount, rateMode, 0, onBehalfOf)`. No ERC-20
    approval needed (the Pool mints debt tokens to msg.sender); credit
    delegation is required when `onBehalfOf ≠ msg.sender` but the Pool
    will revert at simulate time if it is missing. -/
def prepareBorrow
    (chainId : Nat) (sender onBehalfOf asset : String) (amount : Nat)
    (rateMode : V3Pool.InterestRateMode)
    (_shim : ChainEthCallShim) : IO PrepareResult := do
  match resolveContext chainId sender onBehalfOf asset with
  | .error r => pure r
  | .ok ctx =>
    let data := V3Pool.encodeBorrow ctx.assetAddr amount rateMode onBehalfOf 0
    let action : TxFrame :=
      { to := ctx.pool, value := 0, data := data, chainId := chainId }
    let decimals := (ctx.asset?.map (·.decimals)).getD 18
    let label := labelFor ctx.asset? ctx.assetAddr
    let amountStr := fmtAmount amount decimals
    let rateStr := match rateMode with
      | .stable => "stable"
      | .variable => "variable"
    let onBehalfNote :=
      if onBehalfOf.toLower = sender.toLower then ""
      else s!" on behalf of {onBehalfOf}"
    let summary :=
      s!"Aave V3 borrow {amountStr} {label} ({rateStr} rate){onBehalfNote}"
    pure (.ready action summary)

/-! ## Action: repay -/

/-- `Pool.repay(asset, amount, rateMode, onBehalfOf)`. Requires ERC-20
    allowance of `asset` → Pool. `amount = 2^256 - 1` repays the full
    debt of `onBehalfOf` for the given rate mode — but for allowance
    purposes we still gate on the *requested* amount; setting `MAX` will
    always trigger the `needsApproval` branch unless the user has
    already granted unlimited. -/
def prepareRepay
    (chainId : Nat) (sender onBehalfOf asset : String) (amount : Nat)
    (rateMode : V3Pool.InterestRateMode)
    (shim : ChainEthCallShim) : IO PrepareResult := do
  match resolveContext chainId sender onBehalfOf asset with
  | .error r => pure r
  | .ok ctx =>
    match ← readAllowance shim chainId ctx.assetAddr sender ctx.pool with
    | .error r => pure r
    | .ok current =>
      let data := V3Pool.encodeRepay ctx.assetAddr amount rateMode onBehalfOf
      let action : TxFrame :=
        { to := ctx.pool, value := 0, data := data, chainId := chainId }
      let decimals := (ctx.asset?.map (·.decimals)).getD 18
      let label := labelFor ctx.asset? ctx.assetAddr
      let amountStr := fmtAmountOrMax amount decimals
      let rateStr := match rateMode with
        | .stable => "stable"
        | .variable => "variable"
      let onBehalfNote :=
        if onBehalfOf.toLower = sender.toLower then ""
        else s!" on behalf of {onBehalfOf}"
      let summary :=
        s!"Aave V3 repay {amountStr} {label} ({rateStr} debt){onBehalfNote}"
      pure <| attachAllowance action current amount
        ctx.assetAddr ctx.pool chainId summary

/-! ## Action: setUseReserveAsCollateral -/

/-- `Pool.setUserUseReserveAsCollateral(asset, useAsCollateral)`. Pure
    flag operation — no token transfer, no allowance required.
    Re-uses `resolveContext` with `sender` as the `secondAddr` because
    there is no second address argument to the call. -/
def prepareSetCollateral
    (chainId : Nat) (sender asset : String) (useAsCollateral : Bool)
    (_shim : ChainEthCallShim) : IO PrepareResult := do
  match resolveContext chainId sender sender asset with
  | .error r => pure r
  | .ok ctx =>
    let data := V3Pool.encodeSetUserUseReserveAsCollateral
                  ctx.assetAddr useAsCollateral
    let action : TxFrame :=
      { to := ctx.pool, value := 0, data := data, chainId := chainId }
    let label := labelFor ctx.asset? ctx.assetAddr
    let verb := if useAsCollateral then "enable" else "disable"
    let summary := s!"Aave V3 {verb} {label} as collateral"
    pure (.ready action summary)

/-! ## Smart-wallet batching

When the caller's account is a smart wallet (`r1Smart`, `sphincsHybrid`)
and the prepare result is `needsApproval`, the two legs collapse into a
single `executeBatch` call targeted at the sender (the smart wallet
itself). The on-chain semantics are atomic: the approve and the action
either both land or both revert.

For a plain EOA the result passes through unchanged — the LLM still
emits two sequential `propose_send` calls, one per leg.

`ready` results (no approval needed) pass through in both cases. -/

/-- Convert an `Aave.Prepare.TxFrame` to a `ExecuteBatch.Call` for batching. -/
private def txFrameToCall (f : TxFrame) :
    LeanCli.Wallet.ExecuteBatch.Call :=
  { target := f.to, value := f.value, data := f.data }

/-- Wrap a list of TxFrames into a single batched TxFrame targeted at
    `sender` (the smart wallet itself) on the given chain. Calldata is
    `executeBatch(Call[])` per the project's `BaseAccount.sol`. -/
def batchTxFrames (sender : String) (chainId : Nat) (txs : List TxFrame) :
    TxFrame :=
  let calls := txs.map txFrameToCall
  { to := sender, value := 0, data := encodeExecuteBatch calls, chainId := chainId }

/-- Conditionally batch a `needsApproval` result for smart-wallet
    accounts. The `summaryForConfirm` is augmented with the account-kind
    label so the user sees at ConfirmGate that this is a batched op.

    Pure (no IO) — batching is a calldata rewrite, not a chain read. -/
def maybeBatch (sender : String) (chainId : Nat) (kind : AccountKindHint)
    (r : PrepareResult) : PrepareResult :=
  match r with
  | .needsApproval approve action _currentAllowance _required summary =>
      if kind.isSmartWallet then
        let batched := batchTxFrames sender chainId [approve, action]
        let suffix := s!" [batched via executeBatch on {kind.label}]"
        .ready batched (summary ++ suffix)
      else r
  | _ => r

end LeanCli.Aave.Prepare
