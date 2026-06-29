import LeanCli.Agent.Tools
import LeanCli.Agent.DaemonClient
import LeanCli.Encoding.Json

/-!
# `prepare_uniswap_v3_swap` agent tool

Thin agent-side wrapper over the daemon RPC `swap.prepareUniswapV3`.
The daemon does the actual chain reads (allowance + quoter), slippage
math, and calldata encoding (see `LeanCli/Swap/Prepare.lean`); this
module's job is to:

* expose an OpenAI-compatible JSON Schema so the LLM emits the right
  argument shape on the first try, and
* translate the daemon's `PrepareResult.toJson` envelope into the
  agent's `ToolResult` shape (`{ok, data, summary?}`), so the model
  sees a successful `data` payload it can forward directly to
  `propose_send` or a structured `{ok:false, kind, error}` on failure.

There is NO business logic here. Every field on the success path
comes verbatim from the daemon — the agent never recomputes a quote,
allowance, or slippage by hand. That contract is what lets us swap
the daemon's encoder out (or add Quoter caching, or move to V4)
without touching the LLM surface.

## Why a string `amountIn`

JSON numbers in chat-completion clients are typically rendered as
IEEE-754 doubles, which silently truncate above `2^53`. A swap of
1 ETH (`10^18` base units) is comfortably past that. The wrapper
accepts `amountIn` as a decimal string from the model, parses it as
`Nat`, and re-serializes as a JSON number to the daemon — which
already calls `asNat`. No precision is lost in the Lean side.

## Trust model

Read tool by classification (`ToolClass.read`). Produces calldata for
downstream signing, but signing terminates at the unchanged pre-sign
gate (`tx.decodeIntent → tx.simulate → ConfirmGate → eoa.send`).
The wrapper never invokes a signing primitive directly.
-/

namespace LeanCli.Agent.ToolDefs.UniV3Swap

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Agent.DaemonClient
open LeanCli.Encoding.Json

/-- Strict short error envelope used for bad-request and daemon-error
    paths so the model sees a uniform `{kind, error}` shape. -/
private def errResult (kind err : String)
    (extra : Array (String × Json) := #[]) : ToolResult :=
  { ok := false,
    data := .obj <| #[("kind", .str kind), ("error", .str err)] ++ extra }

/-- Parse a non-empty ASCII decimal string into a `Nat`. Returns
    `none` on empty input or any non-`0-9` character. Lifted here
    rather than imported from `TokenRegistry` to keep the agent layer
    free of `Ethereum.*` imports (the forbidden-import gate). -/
private def parseDecimalNat (s : String) : Option Nat := Id.run do
  if s.isEmpty then return none
  let mut acc : Nat := 0
  for c in s.toList do
    if '0' ≤ c ∧ c ≤ '9' then
      acc := acc * 10 + (c.toNat - '0'.toNat)
    else
      return none
  return some acc

/-- Forward the daemon's `PrepareResult.toJson` to the agent
    `ToolResult` envelope. Status discriminator drives the mapping:

    * `"ready"` / `"needs_approval"` → `{ok:true, data, summary}`
      (summary comes from the daemon's `summaryForConfirm`).
    * `"error"` → `{ok:false, data:{kind, error}}` with both fields
      lifted from the daemon envelope.
    * anything else → `protocol_error`. -/
private def envelopeFromDaemon (j : Json) : ToolResult :=
  match getField "status" j >>= asString with
  | some "ready" | some "needs_approval" =>
      let summary := getField "summaryForConfirm" j >>= asString
      { ok := true, data := j, summary := summary }
  | some "error" =>
      let kind := (getField "kind" j >>= asString).getD "error"
      let msg  := (getField "error" j >>= asString).getD "swap preparation failed"
      errResult kind msg
  | _ =>
      errResult "protocol_error"
        s!"swap.prepareUniswapV3: unrecognised status field in {compact j}"

/-- Build the JSON-RPC params object the daemon expects. The model
    sends `amountIn` as a string; we parse it to `Nat` and re-emit
    as `.num` so the daemon's `asNat` consumes it without truncation.

    Optional fields (`fee`, `slippageBps`, `deadlineSeconds`) are
    only forwarded when present, preserving the daemon's defaulting
    AND its `slippageWasDefault` metadata (the daemon flags the
    default only when `slippageBps` is absent — surfaced loudly in
    the ConfirmGate header). -/
private def buildParams
    (chainId : Nat) (sender recipient tokenIn tokenOut : String)
    (amountIn : Nat) (fee slippageBps deadlineSeconds : Option Nat) : Json :=
  let optField (k : String) : Option Nat → Array (String × Json)
    | some n => #[(k, .num (Int.ofNat n))]
    | none   => #[]
  let core : Array (String × Json) := #[
    ("chainId",   .num (Int.ofNat chainId)),
    ("sender",    .str sender),
    ("recipient", .str recipient),
    ("tokenIn",   .str tokenIn),
    ("tokenOut",  .str tokenOut),
    ("amountIn",  .num (Int.ofNat amountIn))
  ]
  .obj <| core
    ++ optField "fee" fee
    ++ optField "slippageBps" slippageBps
    ++ optField "deadlineSeconds" deadlineSeconds

/-- The single tool exposed to the LLM. -/
def prepareUniswapV3Swap : ToolDecl := {
  name := "prepare_uniswap_v3_swap",
  description :=
    "Build a Uniswap V3 swap end-to-end. Resolves token addresses, \
     checks allowance against SwapRouter02, calls the on-chain \
     Quoter, applies slippage (default 0.5%), and encodes the swap \
     (and approve if needed) calldata. Returns ready-to-broadcast \
     TxFrames. The model must NOT compute quote, allowance, or \
     calldata by hand — call this tool once with resolved addresses \
     + base-unit amount and feed the result to propose_send.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[
      .str "chainId", .str "sender", .str "recipient",
      .str "tokenIn", .str "tokenOut"
    ]),
    ("properties", .obj #[
      ("chainId", .obj #[
        ("type", .str "integer"),
        ("description", .str "EVM chain id (1 = mainnet, 11155111 = sepolia)")
      ]),
      ("sender", .obj #[
        ("type", .str "string"),
        ("description", .str "0x-prefixed sender address (the wallet doing the swap)")
      ]),
      ("recipient", .obj #[
        ("type", .str "string"),
        ("description", .str "0x-prefixed recipient of tokenOut; typically the sender")
      ]),
      ("tokenIn", .obj #[
        ("type", .str "string"),
        ("description", .str "0x-prefixed token-in address (resolve via token_lookup first)")
      ]),
      ("tokenOut", .obj #[
        ("type", .str "string"),
        ("description", .str "0x-prefixed token-out address (resolve via token_lookup first)")
      ]),
      ("amountRef", .obj #[
        ("type", .str "string"),
        ("description",
          .str "PREFERRED: a handle from the `amounts` table (e.g. \"amt1\"). The daemon already converted the user's amount to base units — reference it here, never type a magnitude.")
      ]),
      ("amountIn", .obj #[
        ("type", .str "string"),
        ("description",
          .str "Legacy literal base-units string. PREFER `amountRef`; a literal here is REJECTED when an `amounts` table is present.")
      ]),
      ("fee", .obj #[
        ("type", .str "integer"),
        ("description", .str "Uniswap V3 pool fee tier in hundredths of a bp (default 3000 = 0.30%)")
      ]),
      ("slippageBps", .obj #[
        ("type", .str "integer"),
        ("description", .str "Slippage tolerance in basis points (default 50 = 0.50%); pass only if the user specified one")
      ]),
      ("deadlineSeconds", .obj #[
        ("type", .str "integer"),
        ("description", .str "Seconds-from-now deadline (default 1200 = 20 minutes)")
      ])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    -- Required fields — fail closed on any missing or mistyped input.
    let some chainJ := getField "chainId" args
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: missing 'chainId'")
    let some chainId := asNat chainJ
      | pure (errResult "bad_request"
          "prepare_uniswap_v3_swap: 'chainId' must be a non-negative integer")
    let some senderJ := getField "sender" args
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: missing 'sender'")
    let some sender := asString senderJ
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: 'sender' must be a string")
    let some recipientJ := getField "recipient" args
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: missing 'recipient'")
    let some recipient := asString recipientJ
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: 'recipient' must be a string")
    let some tokenInJ := getField "tokenIn" args
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: missing 'tokenIn'")
    let some tokenIn := asString tokenInJ
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: 'tokenIn' must be a string")
    let some tokenOutJ := getField "tokenOut" args
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: missing 'tokenOut'")
    let some tokenOut := asString tokenOutJ
      | pure (errResult "bad_request" "prepare_uniswap_v3_swap: 'tokenOut' must be a string")
    -- `amountIn` is a signing-relevant magnitude → Lean's authority.
    -- Prefer the `amountRef` handle the daemon published; a literal
    -- `amountIn` is rejected when a table is present so the model can't
    -- type a magnitude. No table (one-shot CLI) keeps the legacy path.
    let amountInRes : Except String Nat :=
      match getField "amountRef" args >>= asString with
      | some ref =>
          match findAmount cfg.amountTable ref with
          | some e => .ok e.base
          | none   => .error s!"prepare_uniswap_v3_swap: unknown amountRef '{ref}'; reference one from `amounts`"
      | none =>
          match getField "amountIn" args >>= asString with
          | some s =>
              if cfg.amountTable.isEmpty then
                match parseDecimalNat s with
                | some n => .ok n
                | none   => .error s!"prepare_uniswap_v3_swap: 'amountIn' is not a non-negative decimal integer: {s}"
              else .error "prepare_uniswap_v3_swap: pass amountIn via `amountRef` (a handle from `amounts`); do not type a magnitude"
          | none => .error "prepare_uniswap_v3_swap: provide `amountRef` (a handle from `amounts`)"
    match amountInRes with
    | .error e => pure (errResult "bad_amount" e)
    | .ok amountIn =>
      -- Optional fields: only forwarded when present, so the daemon's
      -- own defaults (and `slippageWasDefault` metadata) stay correct.
      let fee := getField "fee" args >>= asNat
      let slippageBps := getField "slippageBps" args >>= asNat
      let deadlineSeconds := getField "deadlineSeconds" args >>= asNat
      let params := buildParams chainId sender recipient tokenIn tokenOut amountIn
                      fee slippageBps deadlineSeconds
      match ← DaemonClient.call cfg.daemonSocket "swap.prepareUniswapV3" params with
      | .error e =>
          let msg := match e with
            | .transport m => s!"daemon transport (swap.prepareUniswapV3): {m}"
            | .protocol  m => s!"daemon protocol (swap.prepareUniswapV3): {m}"
            | .appError code m _ => s!"daemon swap.prepareUniswapV3 error {code}: {m}"
          pure (errResult "daemon_error" msg)
      | .ok j => pure (envelopeFromDaemon j)
}

end LeanCli.Agent.ToolDefs.UniV3Swap
