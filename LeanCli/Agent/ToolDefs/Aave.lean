import LeanCli.Agent.Tools
import LeanCli.Agent.DaemonClient
import LeanCli.Encoding.Json

/-!
# Aave V3 agent tools

Five typed tools wrapping the daemon RPC `aave.prepare`. Each tool
exposes a JSON Schema covering only the arguments its `action` tag
needs, so a small local model gets a strict per-action surface
(`prepare_aave_supply` has no `rateMode` field; `prepare_aave_borrow`
has no `useAsCollateral`).

Every tool resolves to a single `aave.prepare` daemon call with the
appropriate `action` discriminator. The daemon owns address lookup
(Pool, asset registry), allowance reads, ABI encoding, and the
ready/needs_approval branching — see `LeanCli/Aave/Prepare.lean`.

## Why a string `amount`

JSON numbers in chat-completion clients are typically rendered as
IEEE-754 doubles, which silently truncate above `2^53`. A repay or
withdraw of `MAX (2^256 - 1)` is comfortably past that. Each tool
accepts `amount` as a decimal string, parses to `Nat`, and re-serializes
as a JSON number to the daemon (Lean's `Int` is arbitrary-precision so
the wire JSON survives the round-trip). The literal string `"MAX"` /
`"max"` is also accepted for `withdraw` and `repay` and converts to
`2^256 - 1`, matching the Pool's "full balance" sentinel.

## Trust model

Read tools (`ToolClass.read`). Produces calldata for downstream signing,
but signing terminates at the unchanged pre-sign gate
(`tx.decodeIntent → tx.simulate → ConfirmGate → eoa.send`). The wrapper
never invokes a signing primitive directly.
-/

namespace LeanCli.Agent.ToolDefs.Aave

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Agent.DaemonClient
open LeanCli.Encoding.Json

/-- 2^256 - 1, the Aave "MAX (full balance)" sentinel. Mirror of
    `LeanCli.Aave.Prepare.maxUint256` lifted to the agent layer so we
    can keep `LeanCli.Aave.*` out of the agent import set (the
    forbidden-import gate). -/
private def maxUint256 : Nat :=
  115792089237316195423570985008687907853269984665640564039457584007913129639935

private def errResult (kind err : String)
    (extra : Array (String × Json) := #[]) : ToolResult :=
  { ok := false,
    data := .obj <| #[("kind", .str kind), ("error", .str err)] ++ extra }

/-- Parse a non-empty ASCII decimal string into a `Nat`. Returns
    `none` on empty input or any non-`0-9` character. -/
private def parseDecimalNat (s : String) : Option Nat := Id.run do
  if s.isEmpty then return none
  let mut acc : Nat := 0
  for c in s.toList do
    if '0' ≤ c ∧ c ≤ '9' then
      acc := acc * 10 + (c.toNat - '0'.toNat)
    else
      return none
  return some acc

/-- Accept either a decimal string or the literal `"MAX"`/`"max"`
    sentinel (translated to `2^256 - 1`). Used by `withdraw` and `repay`
    where the Pool documents `MAX` as the full-balance convention. -/
private def parseAmountOrMax (s : String) : Option Nat :=
  match s.toLower with
  | "max" => some maxUint256
  | _ => parseDecimalNat s

/-- Reuse the same envelope mapping as the Uniswap tool: the daemon's
    `PrepareResult.toJson` shape is identical (`status` ∈ {ready,
    needs_approval, error}). On `ready` / `needs_approval` we pass the
    payload through verbatim; on `error` we surface `{kind, error}`. -/
private def envelopeFromDaemon (j : Json) : ToolResult :=
  match getField "status" j >>= asString with
  | some "ready" | some "needs_approval" =>
      let summary := getField "summaryForConfirm" j >>= asString
      { ok := true, data := j, summary := summary }
  | some "error" =>
      let kind := (getField "kind" j >>= asString).getD "error"
      let msg  := (getField "error" j >>= asString).getD "aave preparation failed"
      errResult kind msg
  | _ =>
      errResult "protocol_error"
        s!"aave.prepare: unrecognised status field in {compact j}"

/-! ## Shared argument extractors

Each tool needs the same `chainId`, `sender`, `asset` triple; the
amount and per-action extras vary. These helpers pull the common bits
once. -/

private structure CommonArgs where
  chainId : Nat
  sender : String
  asset : String

private def extractCommon (name : String) (args : Json) :
    Except ToolResult CommonArgs := do
  let some chainJ := getField "chainId" args
    | .error (errResult "bad_request" s!"{name}: missing 'chainId'")
  let some chainId := asNat chainJ
    | .error (errResult "bad_request" s!"{name}: 'chainId' must be a non-negative integer")
  let some senderJ := getField "sender" args
    | .error (errResult "bad_request" s!"{name}: missing 'sender'")
  let some sender := asString senderJ
    | .error (errResult "bad_request" s!"{name}: 'sender' must be a string")
  let some assetJ := getField "asset" args
    | .error (errResult "bad_request" s!"{name}: missing 'asset'")
  let some asset := asString assetJ
    | .error (errResult "bad_request" s!"{name}: 'asset' must be a string")
  pure { chainId := chainId, sender := sender, asset := asset }

private def extractAmount (name : String) (args : Json) (allowMax : Bool) :
    Except ToolResult Nat := do
  let some amountJ := getField "amount" args
    | .error (errResult "bad_request" s!"{name}: missing 'amount'")
  let some amountStr := asString amountJ
    | .error (errResult "bad_request"
        s!"{name}: 'amount' must be a decimal STRING (e.g. \"1000000\") to avoid JSON number truncation")
  let parsed := if allowMax then parseAmountOrMax amountStr else parseDecimalNat amountStr
  match parsed with
  | some n => .ok n
  | none =>
      let suffix := if allowMax then " or 'MAX'" else ""
      .error (errResult "bad_amount"
        s!"{name}: 'amount' is not a non-negative decimal integer{suffix}: {amountStr}")

private def optString (args : Json) (k : String) : Option String :=
  getField k args >>= asString

/-- Build the JSON-RPC params for an `aave.prepare` call. The action
    discriminator is supplied by the wrapping tool; per-action extras
    are passed in `extras` so each tool can stay declarative. -/
private def buildParams
    (action : String) (c : CommonArgs) (extras : Array (String × Json)) : Json :=
  .obj <| #[
    ("action",   .str action),
    ("chainId",  .num (Int.ofNat c.chainId)),
    ("sender",   .str c.sender),
    ("asset",    .str c.asset)
  ] ++ extras

/-- Shared invoke body: ship `params` to the daemon, translate the
    envelope, surface transport / protocol errors uniformly. -/
private def callDaemon (cfg : AgentConfig) (name : String) (params : Json) :
    IO ToolResult := do
  match ← DaemonClient.call cfg.daemonSocket "aave.prepare" params with
  | .error e =>
      let msg := match e with
        | .transport m => s!"daemon transport ({name}): {m}"
        | .protocol  m => s!"daemon protocol ({name}): {m}"
        | .appError code m _ => s!"daemon {name} error {code}: {m}"
      pure (errResult "daemon_error" msg)
  | .ok j => pure (envelopeFromDaemon j)

/-! ## JSON Schema helpers (kept verbose so each tool is self-readable) -/

private def chainIdProp : Json := .obj #[
  ("type", .str "integer"),
  ("description", .str "EVM chain id (1 = mainnet, 11155111 = sepolia)")
]
private def senderProp : Json := .obj #[
  ("type", .str "string"),
  ("description", .str "0x-prefixed sender address (msg.sender of the action)")
]
private def assetProp : Json := .obj #[
  ("type", .str "string"),
  ("description", .str "Asset address (0x-prefixed) or registered symbol (USDC, WETH, DAI, ...) on the requested chain")
]
private def onBehalfOfProp : Json := .obj #[
  ("type", .str "string"),
  ("description", .str "0x-prefixed account on whose behalf the action is taken; defaults to sender")
]
private def recipientProp : Json := .obj #[
  ("type", .str "string"),
  ("description", .str "0x-prefixed recipient of withdrawn tokens; defaults to sender")
]
private def amountStringProp (allowMax : Bool) : Json :=
  let base : String :=
    "Base-units integer as a decimal string (e.g. \"1000000\" for 1 USDC). "
      ++ "Use to_base_units to compute."
  let maxNote : String :=
    if allowMax then " Pass \"MAX\" for the Pool's full-balance sentinel." else ""
  .obj #[
    ("type", .str "string"),
    ("description", .str (base ++ maxNote))
  ]
private def rateModeProp : Json := .obj #[
  ("type", .str "string"),
  ("enum", .arr #[.str "stable", .str "variable"]),
  ("description", .str "Interest-rate mode. Defaults to 'variable' for fresh borrows; pick the matching one when repaying.")
]
private def useAsCollateralProp : Json := .obj #[
  ("type", .str "boolean"),
  ("description", .str "true to enable the asset as collateral, false to disable")
]
private def accountKindProp : Json := .obj #[
  ("type", .str "string"),
  ("enum", .arr #[.str "eoa", .str "r1Smart", .str "sphincsHybrid"]),
  ("description",
    .str ("Account kind hint. When 'r1Smart' or 'sphincsHybrid', a "
            ++ "needs_approval result is collapsed into a single executeBatch "
            ++ "call targeting the sender (one user confirmation, atomic on-chain). "
            ++ "Defaults to 'eoa' (two sequential propose_send legs)."))
]

/-- Forward an optional `accountKind` from the model into the daemon
    params. Skipped when absent so the daemon's default ("eoa") wins. -/
private def accountKindExtra (args : Json) : Array (String × Json) :=
  match optString args "accountKind" with
  | some s => #[("accountKind", .str s)]
  | none   => #[]

/-! ## The five tools -/

def prepareAaveSupply : ToolDecl := {
  name := "prepare_aave_supply",
  description :=
    "Build an Aave V3 supply transaction end-to-end. Resolves the Pool \
     address, reads the ERC-20 allowance against the Pool, encodes the \
     supply (and an unlimited approve if needed). Returns ready-to-broadcast \
     TxFrames. The model must NOT compute calldata by hand — call this \
     tool once with resolved address + base-unit amount and feed the \
     result to propose_send.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "sender", .str "asset", .str "amount"]),
    ("properties", .obj #[
      ("chainId",     chainIdProp),
      ("sender",      senderProp),
      ("asset",       assetProp),
      ("amount",      amountStringProp false),
      ("onBehalfOf",  onBehalfOfProp),
      ("accountKind", accountKindProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match extractCommon "prepare_aave_supply" args with
    | .error e => pure e
    | .ok c =>
      match extractAmount "prepare_aave_supply" args false with
      | .error e => pure e
      | .ok amount =>
          let extras : Array (String × Json) :=
            #[("amount", .num (Int.ofNat amount))]
              ++ (match optString args "onBehalfOf" with
                  | some s => #[("onBehalfOf", .str s)]
                  | none => #[])
              ++ accountKindExtra args
          callDaemon cfg "prepare_aave_supply" (buildParams "supply" c extras)
}

def prepareAaveWithdraw : ToolDecl := {
  name := "prepare_aave_withdraw",
  description :=
    "Build an Aave V3 withdraw transaction. No approval needed — the Pool \
     operates on the user's aToken balance. Pass amount=\"MAX\" to withdraw \
     the full balance (the Pool's documented 2^256-1 sentinel).",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "sender", .str "asset", .str "amount"]),
    ("properties", .obj #[
      ("chainId",     chainIdProp),
      ("sender",      senderProp),
      ("asset",       assetProp),
      ("amount",      amountStringProp true),
      ("recipient",   recipientProp),
      ("accountKind", accountKindProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match extractCommon "prepare_aave_withdraw" args with
    | .error e => pure e
    | .ok c =>
      match extractAmount "prepare_aave_withdraw" args true with
      | .error e => pure e
      | .ok amount =>
          let extras : Array (String × Json) :=
            #[("amount", .num (Int.ofNat amount))]
              ++ (match optString args "recipient" with
                  | some s => #[("recipient", .str s)]
                  | none => #[])
              ++ accountKindExtra args
          callDaemon cfg "prepare_aave_withdraw" (buildParams "withdraw" c extras)
}

def prepareAaveBorrow : ToolDecl := {
  name := "prepare_aave_borrow",
  description :=
    "Build an Aave V3 borrow transaction. No approval needed (the Pool \
     mints debt tokens to msg.sender). The borrower must already have \
     collateral with enough health-factor headroom — tx.simulate will \
     surface a revert otherwise. rateMode defaults to 'variable'.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "sender", .str "asset", .str "amount"]),
    ("properties", .obj #[
      ("chainId",     chainIdProp),
      ("sender",      senderProp),
      ("asset",       assetProp),
      ("amount",      amountStringProp false),
      ("rateMode",    rateModeProp),
      ("onBehalfOf",  onBehalfOfProp),
      ("accountKind", accountKindProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match extractCommon "prepare_aave_borrow" args with
    | .error e => pure e
    | .ok c =>
      match extractAmount "prepare_aave_borrow" args false with
      | .error e => pure e
      | .ok amount =>
          let extras : Array (String × Json) :=
            #[("amount", .num (Int.ofNat amount))]
              ++ (match optString args "rateMode" with
                  | some s => #[("rateMode", .str s)]
                  | none => #[])
              ++ (match optString args "onBehalfOf" with
                  | some s => #[("onBehalfOf", .str s)]
                  | none => #[])
              ++ accountKindExtra args
          callDaemon cfg "prepare_aave_borrow" (buildParams "borrow" c extras)
}

def prepareAaveRepay : ToolDecl := {
  name := "prepare_aave_repay",
  description :=
    "Build an Aave V3 repay transaction end-to-end. Reads ERC-20 allowance \
     against the Pool, emits an unlimited approve when needed. Pass \
     amount=\"MAX\" to repay the full debt for the given rateMode. rateMode \
     must match the debt being repaid ('variable' or 'stable').",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "sender", .str "asset", .str "amount"]),
    ("properties", .obj #[
      ("chainId",     chainIdProp),
      ("sender",      senderProp),
      ("asset",       assetProp),
      ("amount",      amountStringProp true),
      ("rateMode",    rateModeProp),
      ("onBehalfOf",  onBehalfOfProp),
      ("accountKind", accountKindProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match extractCommon "prepare_aave_repay" args with
    | .error e => pure e
    | .ok c =>
      match extractAmount "prepare_aave_repay" args true with
      | .error e => pure e
      | .ok amount =>
          let extras : Array (String × Json) :=
            #[("amount", .num (Int.ofNat amount))]
              ++ (match optString args "rateMode" with
                  | some s => #[("rateMode", .str s)]
                  | none => #[])
              ++ (match optString args "onBehalfOf" with
                  | some s => #[("onBehalfOf", .str s)]
                  | none => #[])
              ++ accountKindExtra args
          callDaemon cfg "prepare_aave_repay" (buildParams "repay" c extras)
}

def prepareAaveSetCollateral : ToolDecl := {
  name := "prepare_aave_set_collateral",
  description :=
    "Build an Aave V3 setUserUseReserveAsCollateral transaction — a pure \
     flag operation that enables (true) or disables (false) the given asset \
     as collateral for the sender's position. No allowance needed.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[
      .str "chainId", .str "sender", .str "asset", .str "useAsCollateral"
    ]),
    ("properties", .obj #[
      ("chainId",         chainIdProp),
      ("sender",          senderProp),
      ("asset",           assetProp),
      ("useAsCollateral", useAsCollateralProp)
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match extractCommon "prepare_aave_set_collateral" args with
    | .error e => pure e
    | .ok c =>
      let useAsCollateral : Bool :=
        match getField "useAsCollateral" args with
        | some (.bool b) => b
        | _ => true
      let extras : Array (String × Json) :=
        #[("useAsCollateral", .bool useAsCollateral)]
      callDaemon cfg "prepare_aave_set_collateral"
        (buildParams "setCollateral" c extras)
}

end LeanCli.Agent.ToolDefs.Aave
