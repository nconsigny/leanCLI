import LeanCli.Agent.Tools
import LeanCli.Encoding.Json

/-!
# `tx_simulate` tool

Dry-run a `{chainId, from, to, value, data}` against the daemon's
`tx.simulate` RPC. Returns the eth_call success/revert, gas estimate,
and (when available) decoded token transfers.

Read-only. The daemon enforces network policy on the underlying
eth_call / eth_estimateGas / debug_traceCall.
-/

namespace LeanCli.Agent.ToolDefs.Simulate

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Encoding.Json

private def chainGuard (cfg : AgentConfig) (args : Json) : Except String Nat := do
  let some chainJ := getField "chainId" args
    | .error "tx_simulate: missing required field 'chainId'"
  let some chainId := asNat chainJ
    | .error "tx_simulate: 'chainId' must be a non-negative integer"
  if cfg.chainWhitelist.contains chainId then .ok chainId
  else .error s!"tx_simulate: chainId {chainId} not in whitelist"

def txSimulate : ToolDecl := {
  name := "tx_simulate",
  description :=
    "Simulate a transaction (eth_call + eth_estimateGas + optional \
     debug_traceCall for transfers) against the configured RPC. \
     Read-only.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "to"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("from",    .obj #[("type", .str "string")]),
      ("to",      .obj #[("type", .str "string")]),
      ("value",   .obj #[("type", .str "integer")]),
      ("data",    .obj #[("type", .str "string")])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard cfg args with
    | .error e => pure { ok := false, data := .obj #[("error", .str e)] }
    | .ok _ => daemonCall cfg "tx.simulate" args
}

end LeanCli.Agent.ToolDefs.Simulate
