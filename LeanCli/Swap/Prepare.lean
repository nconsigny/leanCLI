import Std.Time
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.TokenRegistry
import LeanCli.Swap.Tokens
import LeanCli.Swap.UniV3

/-!
# One-shot Uniswap V3 swap preparation

A single Lean-side function that bundles the work an agent (or any other
calldata-producing surface) used to do as a chain of low-level reads:

  1. resolve `tokenIn` / `tokenOut` (symbol or address) on the requested chain;
  2. read the ERC-20 `allowance(sender, router)`;
  3. read `QuoterV2.quoteExactInputSingle` for `expectedOut`;
  4. apply integer slippage math and compute a wall-clock deadline;
  5. encode `SwapRouter02.exactInputSingle` calldata;
  6. branch on the allowance to produce either `.ready` or `.needsApproval`;
  7. attach a human-readable `summaryForConfirm` string.

This module is read-only. It never signs and never broadcasts: the resulting
`TxFrame`s flow downstream through `decodeIntent → simulate → ConfirmGate`
before any signature, identical to every other calldata-producing surface.

`autoImplicit := false` clean. Pure integer math; `Nat.sub` is only used
where the upstream guard `slippageBps ≤ 10000` rules out underflow.
-/

namespace LeanCli.Swap.Prepare

open LeanCli.Encoding.Json (Json)
open LeanCli.Swap

/-! ## Wire types -/

/-- A bare transaction frame: just enough fields for the downstream
    `decodeIntent → simulate → ConfirmGate` pipeline. `value` is in wei;
    `data` is `0x`-prefixed lowercase hex; `chainId` is the canonical
    decimal chain identifier. -/
structure TxFrame where
  to : String
  value : Nat
  data : String
  chainId : Nat
  deriving Repr

/-- Input to `prepareUniswapV3Swap`. `tokenIn`/`tokenOut` are either
    registered symbols (case-insensitive, `"ETH"` aliased to `WETH`) or
    raw 0x-prefixed addresses. `amountIn` is already in token base units.

    `slippageWasDefault` is sticky metadata: when `true` the resulting
    `summaryForConfirm` flags the slippage value as a daemon default so
    the user sees it at ConfirmGate and can override before signing. -/
structure SwapRequest where
  chainId : Nat
  sender : String
  recipient : String
  tokenIn : String
  tokenOut : String
  amountIn : Nat
  fee : Nat := 3000
  slippageBps : Nat := 50
  slippageWasDefault : Bool := true
  deadlineSeconds : Nat := 1200
  deriving Repr

/-- The chain-read shim. The daemon passes a closure that wraps its
    existing policy-gated `chain.ethCall` path so this pure module can
    stay FFI-free. Returns either `0x`-prefixed return data or a
    human-readable error string. -/
abbrev ChainEthCallShim :=
  (to : String) → (data : String) → (chainId : Nat) → IO (Except String String)

/-- Result of `prepareUniswapV3Swap`. The agent (or any caller) hands
    `ready.swap` / `needsApproval.{approve, swap}` straight to
    `propose_send`, which routes them through the unchanged pre-sign
    gate. `summaryForConfirm` is the one-line ConfirmGate header. -/
inductive PrepareResult where
  /-- Allowance already covers `amountIn`. Single swap tx. -/
  | ready
      (swap : TxFrame)
      (expectedOut : Nat)
      (minOut : Nat)
      (slippageBps : Nat)
      (slippageNote : String)
      (deadline : Nat)
      (summaryForConfirm : String)
  /-- Allowance insufficient. Approve first, then swap. The approve uses
      `maxUint256` so the user does not have to re-approve on the next
      swap of the same token — surfaced loudly in `summaryForConfirm`
      so the ConfirmGate user sees the unlimited grant. -/
  | needsApproval
      (approve : TxFrame)
      (swap : TxFrame)
      (currentAllowance : Nat)
      (required : Nat)
      (expectedOut : Nat)
      (minOut : Nat)
      (slippageBps : Nat)
      (slippageNote : String)
      (deadline : Nat)
      (summaryForConfirm : String)
  /-- Anything that prevents producing a swap. `kind` is a stable
      machine-readable tag (`unknown_token`, `unsupported_chain`,
      `allowance_read_failed`, `quote_failed`, `invalid_address`).
      `msg` is a human-readable explanation. -/
  | err (kind : String) (msg : String)
  deriving Repr

/-! ## Pure helpers -/

/-- Symbol or 0x-prefixed address → resolved lowercase address with
    optional `Token` metadata (decimals + symbol) when known. -/
def resolveToken (input : String) (chain : Tokens.ChainId) :
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

/-- Pretty-print an amount in human units (e.g. `13000000` @ 6 dp →
    `"13.000000"`). On parse failure (impossible for `Nat.toString`)
    falls back to the raw base-units integer so the summary still
    renders. -/
def fmtAmount (n : Nat) (decimals : Nat) : String :=
  match LeanCli.Ethereum.TokenRegistry.humanUnits (toString n) decimals with
  | .ok s => s
  | .error _ => toString n

/-- Display label for a resolved token: prefer the registry symbol, fall
    back to the short address (first 6 + last 4 hex chars). -/
def labelFor (tok? : Option Tokens.Token) (addr : String) : String :=
  match tok? with
  | some t => t.symbol
  | none =>
    let s := addr
    if s.length ≥ 12 then
      (s.take 6).toString ++ "…" ++ (s.drop (s.length - 4)).toString
    else s

/-- Format a slippage value in bps as a `"0.50%"`-style string with two
    fractional digits. Integer-only — no floats. -/
def fmtSlippagePct (bps : Nat) : String :=
  let whole := bps / 100
  let frac := bps % 100
  let pad := if frac < 10 then "0" ++ toString frac else toString frac
  toString whole ++ "." ++ pad ++ "%"

/-- Apply integer slippage: `expectedOut * (10000 - bps) / 10000`. The
    guard `bps ≤ 10000` keeps `Nat.sub` from clamping silently. When
    out-of-range we treat the request as if `bps = 10000` (i.e. accept
    zero output) — the caller will have already errored on the request
    via `validateSlippage`, but the guard means even if someone calls
    this directly the math stays well-defined. -/
def applySlippage (expectedOut bps : Nat) : Nat :=
  let cappedBps := if bps > 10000 then 10000 else bps
  expectedOut * (10000 - cappedBps) / 10000

/-- Build the human-readable ConfirmGate header. Mentions both the
    expected and minimum amounts in human units so the user can sanity-
    check the slippage floor before signing. -/
def buildSummary
    (req : SwapRequest)
    (tokenIn? tokenOut? : Option Tokens.Token)
    (tinAddr toutAddr : String)
    (expectedOut minOut : Nat) : String :=
  let inDecimals  := (tokenIn?.map (·.decimals)).getD 18
  let outDecimals := (tokenOut?.map (·.decimals)).getD 18
  let inLabel  := labelFor tokenIn?  tinAddr
  let outLabel := labelFor tokenOut? toutAddr
  let amountInStr := fmtAmount req.amountIn inDecimals
  let expectedStr := fmtAmount expectedOut outDecimals
  let minStr := fmtAmount minOut outDecimals
  let slipStr := fmtSlippagePct req.slippageBps
  let slipNote :=
    if req.slippageWasDefault then
      slipStr ++ " slippage (default — user did not specify)"
    else
      slipStr ++ " slippage"
  s!"Swap {amountInStr} {inLabel} → ~{expectedStr} {outLabel} (min {minStr} {outLabel}, {slipNote})"

/-- The "slippage was default" suffix is duplicated in the structured
    `slippageNote` field so consumers that do not parse the summary can
    still render the warning. -/
def buildSlippageNote (req : SwapRequest) : String :=
  if req.slippageWasDefault then
    fmtSlippagePct req.slippageBps ++ " (default — user did not specify)"
  else
    fmtSlippagePct req.slippageBps

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

/-- Encode a `PrepareResult` as JSON for the `swap.prepareUniswapV3`
    RPC response. Discriminator `"status"` is `"ready"`,
    `"needs_approval"`, or `"error"`. -/
def PrepareResult.toJson : PrepareResult → Json
  | .ready swap expectedOut minOut slippageBps slippageNote deadline summary =>
      .obj #[
        ("status",            .str "ready"),
        ("swap",              swap.toJson),
        ("expectedOut",       .num (Int.ofNat expectedOut)),
        ("minOut",            .num (Int.ofNat minOut)),
        ("slippageBps",       .num (Int.ofNat slippageBps)),
        ("slippageNote",      .str slippageNote),
        ("deadline",          .num (Int.ofNat deadline)),
        ("summaryForConfirm", .str summary)
      ]
  | .needsApproval approve swap currentAllowance required
        expectedOut minOut slippageBps slippageNote deadline summary =>
      .obj #[
        ("status",            .str "needs_approval"),
        ("approve",           approve.toJson),
        ("swap",              swap.toJson),
        ("currentAllowance",  .num (Int.ofNat currentAllowance)),
        ("required",          .num (Int.ofNat required)),
        ("expectedOut",       .num (Int.ofNat expectedOut)),
        ("minOut",            .num (Int.ofNat minOut)),
        ("slippageBps",       .num (Int.ofNat slippageBps)),
        ("slippageNote",      .str slippageNote),
        ("deadline",          .num (Int.ofNat deadline)),
        ("summaryForConfirm", .str summary)
      ]
  | .err kind msg =>
      .obj #[
        ("status", .str "error"),
        ("kind",   .str kind),
        ("error",  .str msg)
      ]

/-! ## Headline action -/

/-- Wall-clock epoch seconds. We use `Std.Time.Timestamp.now` rather
    than `IO.monoMsNow` (monotonic-only); the deadline rides on-chain
    so a small clock skew is enforced there. -/
private def nowEpochSeconds : IO Nat := do
  let ts ← Std.Time.Timestamp.now
  let secs := ts.toSecondsSinceUnixEpoch.toInt
  pure secs.toNat

/-- Prepare a Uniswap V3 swap end-to-end: resolve tokens, read
    allowance + quote, compute slippage and deadline, encode calldata,
    return either a single-tx `.ready` or a two-tx `.needsApproval`.

    All chain reads go through `chainEthCall`, which the daemon wires
    to its policy-gated `Outbound.ethCall` (so `NetworkPolicy` applies
    automatically). No signing primitive is referenced. The resulting
    calldata is consumed by the unchanged pre-sign pipeline. -/
def prepareUniswapV3Swap
    (req : SwapRequest) (chainEthCall : ChainEthCallShim) : IO PrepareResult := do
  -- 1. Validate slippage range up front so the math is total.
  if req.slippageBps > 10000 then
    return .err "invalid_slippage"
      s!"slippageBps must be ≤ 10000 (100%), got {req.slippageBps}"
  -- 2. Resolve chain.
  match chainIdToEnum? req.chainId with
  | none =>
      return .err "unsupported_chain"
        s!"chainId {req.chainId} is not supported (only 1 / 11155111 today)"
  | some chain =>
    -- 3. Sanity-check sender + recipient as 20-byte hex.
    match LeanCli.Ethereum.Address.fromHex req.sender,
          LeanCli.Ethereum.Address.fromHex req.recipient with
    | none, _ =>
        return .err "invalid_address" s!"sender is not a 0x-prefixed 20-byte address: {req.sender}"
    | _, none =>
        return .err "invalid_address" s!"recipient is not a 0x-prefixed 20-byte address: {req.recipient}"
    | some _, some _ =>
      -- 4. Resolve tokenIn / tokenOut.
      match resolveToken req.tokenIn chain, resolveToken req.tokenOut chain with
      | none, _ =>
          return .err "unknown_token"
            s!"tokenIn {req.tokenIn} is not a registered symbol on this chain and is not a valid 0x address"
      | _, none =>
          return .err "unknown_token"
            s!"tokenOut {req.tokenOut} is not a registered symbol on this chain and is not a valid 0x address"
      | some (tokenIn?, tinAddr), some (tokenOut?, toutAddr) =>
        let router := UniV3.routerFor chain
        let quoter := UniV3.quoterFor chain
        -- 5. Read allowance.
        let allowanceData := UniV3.encodeAllowance req.sender router
        match ← chainEthCall tinAddr allowanceData req.chainId with
        | .error e =>
            return .err "allowance_read_failed" e
        | .ok allowanceHex =>
          match UniV3.decodeWordAt allowanceHex 0 with
          | none =>
              return .err "allowance_read_failed"
                s!"allowance() returned malformed data: {allowanceHex}"
          | some currentAllowance =>
            -- 6. Read quote (QuoterV2.quoteExactInputSingle, selector 0xc6a5026a).
            let quoteData := UniV3.encodeQuoteExactInputSingle
              { tokenIn  := tinAddr,
                tokenOut := toutAddr,
                amountIn := req.amountIn,
                fee      := req.fee }
            match ← chainEthCall quoter quoteData req.chainId with
            | .error e =>
                return .err "quote_failed" e
            | .ok quoteHex =>
              match UniV3.decodeQuoteAmountOut quoteHex with
              | none =>
                  return .err "quote_failed"
                    s!"quoter returned malformed data: {quoteHex}"
              | some expectedOut =>
                -- 7. Slippage + deadline.
                let minOut := applySlippage expectedOut req.slippageBps
                let now ← nowEpochSeconds
                let deadline := now + req.deadlineSeconds
                -- 8. Encode swap calldata.
                let swapData := UniV3.encodeExactInputSingle
                  { tokenIn          := tinAddr,
                    tokenOut         := toutAddr,
                    fee              := req.fee,
                    recipient        := req.recipient,
                    amountIn         := req.amountIn,
                    amountOutMinimum := minOut }
                let swap : TxFrame :=
                  { to := router, value := 0, data := swapData, chainId := req.chainId }
                let summary := buildSummary req tokenIn? tokenOut?
                  tinAddr toutAddr expectedOut minOut
                let slipNote := buildSlippageNote req
                -- 9. Branch on allowance.
                if currentAllowance ≥ req.amountIn then
                  return .ready swap expectedOut minOut req.slippageBps slipNote deadline summary
                else
                  let approveData := UniV3.encodeApprove router UniV3.maxUint256
                  let approve : TxFrame :=
                    { to := tinAddr, value := 0, data := approveData, chainId := req.chainId }
                  return .needsApproval approve swap
                    currentAllowance req.amountIn
                    expectedOut minOut req.slippageBps slipNote deadline summary

end LeanCli.Swap.Prepare
