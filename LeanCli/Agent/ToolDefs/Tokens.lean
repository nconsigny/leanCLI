import LeanCli.Agent.Tools
import LeanCli.Ethereum.TokenRegistry
import LeanCli.Encoding.Json

/-!
# Token registry agent tools

Three read-only tools that hand the LLM verified ground truth about
ERC-20 tokens instead of letting it invent addresses and decimals
from training data.

* `token_lookup({chainId, query})` — query is symbol, name, or
  address. Returns `{symbol, name, chainId, address, decimals,
  source}` on a hit, or `kind:"unknown_token"` on a miss.
* `to_base_units({amount, decimals})` — `"13.5", 6` →
  `"13500000"`. Rejects scientific notation, leading signs, and
  fractional parts wider than `decimals`.
* `human_units({baseUnits, decimals})` — `"13000000", 6` →
  `"13.000000"`. Always pads to exactly `decimals` digits.

These are AGENT tools (Surface layer), not daemon RPCs. The
underlying lookup and conversion functions live in
`LeanCli.Ethereum.TokenRegistry` and are pure / no IO.

## Trust model

The hardcoded list in `Ethereum.TokenRegistry` is reviewed in source.
The agent's role is to consume it: addresses and decimals it
produces must come from `token_lookup`, never from the model's
weights. If a future ERC-7730 augmentation path is added, the
hardcoded entry wins on `address` and `decimals` for any conflict
(see `TokenRegistry.lean` docstring).

ERC-7730 augmentation is deliberately deferred — the existing
`Clearsign/Bridge.lean` sidecar surface is a generic JSON-RPC pipe
with no "describe token by address" primitive today. Adding one is
more than the ~50-line plumbing budget set by the design note and
belongs in a follow-up.
-/

namespace LeanCli.Agent.ToolDefs.Tokens

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Encoding.Json
open LeanCli.Ethereum.TokenRegistry

/-- Render a `TokenInfo` as the `data` payload of a successful tool
    response. Field order mirrors the struct so consumers can read
    JSON output deterministically. -/
private def renderToken (t : TokenInfo) : Json :=
  .obj #[
    ("symbol",   .str t.symbol),
    ("name",     .str t.name),
    ("chainId",  .num (Int.ofNat t.chainId)),
    ("address",  .str t.address),
    ("decimals", .num (Int.ofNat t.decimals)),
    ("source",   .str t.source)
  ]

/-- Strict short error envelope: `{ok:false, kind, error}` plus any
    extra keys the caller wants to forward (e.g. a suggestion). -/
private def errResult (kind err : String)
    (extra : Array (String × Json) := #[]) : ToolResult :=
  { ok := false,
    data := .obj <| #[("kind", .str kind), ("error", .str err)] ++ extra }

/-- `token_lookup` — chainId-scoped lookup by symbol, name, or
    address. Tries symbol first (the common case), then address. -/
def tokenLookup : ToolDecl := {
  name := "token_lookup",
  description :=
    "Look up an ERC-20 token by symbol (e.g. \"USDC\") or by 0x \
     address on a specific chainId. Returns the canonical \
     EIP-55-checksummed address and decimals from a hand-audited, \
     compiled-in registry — these fields are the ONLY safe source \
     for token metadata. Do NOT use training-data recall for \
     addresses or decimals. On miss, returns kind:\"unknown_token\" \
     and you must ask the user for the canonical address on that \
     chainId rather than guess.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "query"]),
    ("properties", .obj #[
      ("chainId", .obj #[
        ("type", .str "integer"),
        ("description", .str "EVM chain id (1 = mainnet, 11155111 = sepolia)")
      ]),
      ("query", .obj #[
        ("type", .str "string"),
        ("description", .str "Token symbol (e.g. USDC) or 0x address; case-insensitive")
      ])
    ])
  ],
  classify := .read,
  invoke := fun _cfg args => do
    let some chainJ := getField "chainId" args
      | pure (errResult "bad_request" "token_lookup: missing 'chainId'")
    let some chainId := asNat chainJ
      | pure (errResult "bad_request" "token_lookup: 'chainId' must be a non-negative integer")
    let some queryJ := getField "query" args
      | pure (errResult "bad_request" "token_lookup: missing 'query'")
    let some query := asString queryJ
      | pure (errResult "bad_request" "token_lookup: 'query' must be a string")
    -- Try symbol first (cheap), then address. Both are pure lookups
    -- against the compiled-in `knownTokens` list.
    let hit :=
      match lookupBySymbol chainId query with
      | some t => some t
      | none   => lookupByAddress chainId query
    match hit with
    | some t =>
        pure { ok := true,
               data := renderToken t,
               summary := some s!"{t.symbol} on chain {t.chainId}: {t.address} ({t.decimals} dec)" }
    | none =>
        pure (errResult "unknown_token"
          s!"no hardcoded entry for '{query}' on chainId {chainId}"
          #[("suggest",
             .str s!"ask the user for the canonical address on chainId {chainId}; do not guess")])
}

/-- `to_base_units` — decimal string → base-units decimal string.
    Thin wrapper over `Ethereum.TokenRegistry.toBaseUnits`. -/
def toBaseUnitsTool : ToolDecl := {
  name := "to_base_units",
  description :=
    "Convert a human-readable token amount (e.g. \"13.5\") to its \
     base-units integer representation (e.g. \"13500000\" for a \
     6-decimal token). NEVER compute base-unit conversions in your \
     head — always call this. Rejects scientific notation, leading \
     signs, and fractional parts wider than the token's decimals.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "amount", .str "decimals"]),
    ("properties", .obj #[
      ("amount", .obj #[
        ("type", .str "string"),
        ("description", .str "Decimal string, e.g. \"13\", \"13.5\", \"0.000001\"")
      ]),
      ("decimals", .obj #[
        ("type", .str "integer"),
        ("description", .str "Token decimals (call token_lookup first; do not guess)")
      ])
    ])
  ],
  classify := .read,
  invoke := fun _cfg args => do
    let some amountJ := getField "amount" args
      | pure (errResult "bad_request" "to_base_units: missing 'amount'")
    let some amount := asString amountJ
      | pure (errResult "bad_request" "to_base_units: 'amount' must be a string")
    let some decJ := getField "decimals" args
      | pure (errResult "bad_request" "to_base_units: missing 'decimals'")
    let some decimals := asNat decJ
      | pure (errResult "bad_request" "to_base_units: 'decimals' must be a non-negative integer")
    match toBaseUnits amount decimals with
    | .ok base =>
        pure { ok := true,
               data := .obj #[("baseUnits", .str base)],
               summary := some s!"{amount} → {base} ({decimals} dec)" }
    | .error e => pure (errResult "bad_amount" e)
}

/-- `human_units` — base-units decimal string → padded human string.
    Thin wrapper over `Ethereum.TokenRegistry.humanUnits`. -/
def humanUnitsTool : ToolDecl := {
  name := "human_units",
  description :=
    "Convert a base-units integer string (e.g. \"13000000\") back \
     to its human-readable form (e.g. \"13.000000\" for a 6-decimal \
     token). Always pads to exactly `decimals` fractional digits so \
     the output is unambiguous.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "baseUnits", .str "decimals"]),
    ("properties", .obj #[
      ("baseUnits", .obj #[
        ("type", .str "string"),
        ("description", .str "Integer decimal string, e.g. \"13000000\"")
      ]),
      ("decimals", .obj #[
        ("type", .str "integer"),
        ("description", .str "Token decimals (call token_lookup first; do not guess)")
      ])
    ])
  ],
  classify := .read,
  invoke := fun _cfg args => do
    let some baseJ := getField "baseUnits" args
      | pure (errResult "bad_request" "human_units: missing 'baseUnits'")
    let some baseUnits := asString baseJ
      | pure (errResult "bad_request" "human_units: 'baseUnits' must be a string")
    let some decJ := getField "decimals" args
      | pure (errResult "bad_request" "human_units: missing 'decimals'")
    let some decimals := asNat decJ
      | pure (errResult "bad_request" "human_units: 'decimals' must be a non-negative integer")
    match humanUnits baseUnits decimals with
    | .ok human =>
        pure { ok := true,
               data := .obj #[("human", .str human)],
               summary := some s!"{baseUnits} → {human} ({decimals} dec)" }
    | .error e => pure (errResult "bad_amount" e)
}

end LeanCli.Agent.ToolDefs.Tokens
