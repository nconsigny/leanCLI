import LeanKohaku.Agent.Tools
import LeanKohaku.Encoding.Json

/-!
# Chain read tools

`chain_read`, `nonce`, `gas_price` — minimal chain introspection
surface. All three are pure reads routed through the daemon's
policy-gated outbound layer.

* `chain_read` → daemon `chain.ethCall` (general policy-gated
  `eth_call` primitive — no per-protocol RPC needed).
* `nonce` → daemon `chain.nonce` (pending nonce for an address).
* `gas_price` → daemon `chain.gasPrice` (latest base/legacy gas price).
-/

namespace LeanKohaku.Agent.ToolDefs.Chain

open LeanKohaku.Agent
open LeanKohaku.Agent.Tools
open LeanKohaku.Encoding.Json

private def chainGuard (toolName : String) (cfg : AgentConfig) (args : Json) :
    Except String Nat := do
  let some chainJ := getField "chainId" args
    | .error s!"{toolName}: missing required field 'chainId'"
  let some chainId := asNat chainJ
    | .error s!"{toolName}: 'chainId' must be a non-negative integer"
  if cfg.chainWhitelist.contains chainId then .ok chainId
  else .error s!"{toolName}: chainId {chainId} not in whitelist"

/-- Generic policy-gated `eth_call` over arbitrary calldata. -/
def chainRead : ToolDecl := {
  name := "chain_read",
  description :=
    "Generic eth_call against a contract. The daemon enforces network \
     policy on the underlying call. Read-only.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "to", .str "data"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("to",      .obj #[("type", .str "string")]),
      ("data",    .obj #[("type", .str "string")])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard "chain_read" cfg args with
    | .error e => pure { ok := false, data := .obj #[("error", .str e)] }
    | .ok _ => daemonCall cfg "chain.ethCall" args
}

/-- Pending-nonce lookup for a given address. -/
def nonce : ToolDecl := {
  name := "nonce",
  description :=
    "Return the pending nonce for an address on a given chain. Use \
     this to pick the next nonce before drafting a transaction.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "address"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("address", .obj #[("type", .str "string")])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard "nonce" cfg args with
    | .error e => pure { ok := false, data := .obj #[("error", .str e)] }
    | .ok _ => daemonCall cfg "chain.nonce" args
}

/-- Current gas price observation. -/
def gasPrice : ToolDecl := {
  name := "gas_price",
  description :=
    "Return the latest gas price observation (legacy `gasPrice` value, \
     in wei) for the given chain. EIP-1559 callers should pair this \
     with a max priority fee estimate from the simulator.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard "gas_price" cfg args with
    | .error e => pure { ok := false, data := .obj #[("error", .str e)] }
    | .ok _ => daemonCall cfg "chain.gasPrice" args
}

end LeanKohaku.Agent.ToolDefs.Chain
