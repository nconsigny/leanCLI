import LeanKohaku.Agent.Tools
import LeanKohaku.Encoding.Json

/-!
# Calldata / EIP-712 decode tools

`decode_calldata` forwards `{chainId, to, data, value?}` to the
daemon's `tx.decodeIntent` RPC, which fans out to the ERC-7730 clear-
sign sidecar via the daemon's policy gate.

`decode_eip712` forwards a parsed EIP-712 message to the daemon's
`eip712.decodeIntent` RPC.

Both are pure reads from the agent's perspective: no state change, no
signature, no broadcast. The daemon validates each call against
`Privacy.NetworkPolicy` before forwarding.
-/

namespace LeanKohaku.Agent.ToolDefs.Decode

open LeanKohaku.Agent
open LeanKohaku.Agent.Tools
open LeanKohaku.Encoding.Json

/-- Reject non-whitelisted chain ids before contacting the daemon. -/
private def chainGuard (cfg : AgentConfig) (args : Json) : Except String Nat := do
  let some chainJ := getField "chainId" args
    | .error "decode tool: missing required field 'chainId'"
  let some chainId := asNat chainJ
    | .error "decode tool: 'chainId' must be a non-negative integer"
  if cfg.chainWhitelist.contains chainId then
    .ok chainId
  else
    .error s!"decode tool: chainId {chainId} not in whitelist"

/-- `decode_calldata` — forward `{chainId, to, data, value?, from?}`
    to the daemon's `tx.decodeIntent`. -/
def decodeCalldata : ToolDecl := {
  name := "decode_calldata",
  description :=
    "Decode raw EVM calldata into a human-readable intent via the daemon's \
     ERC-7730 / 4byte clear-sign descriptor stack. Read-only.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "to", .str "data"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("to",      .obj #[("type", .str "string")]),
      ("data",    .obj #[("type", .str "string")]),
      ("value",   .obj #[("type", .str "integer")]),
      ("from",    .obj #[("type", .str "string")])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard cfg args with
    | .error e => pure { ok := false, data := .obj #[("error", .str e)] }
    | .ok _ => daemonCall cfg "tx.decodeIntent" args
}

/-- `decode_eip712` — forward a parsed EIP-712 typed-data object to
    the daemon's `eip712.decodeIntent`. -/
def decodeEip712 : ToolDecl := {
  name := "decode_eip712",
  description :=
    "Decode an EIP-712 typed-data message against the daemon's \
     descriptor registry. Returns the rendered fields for user \
     confirmation. Read-only.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "chainId", .str "message"]),
    ("properties", .obj #[
      ("chainId", .obj #[("type", .str "integer")]),
      ("message", .obj #[("type", .str "object")])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    match chainGuard cfg args with
    | .error e => pure { ok := false, data := .obj #[("error", .str e)] }
    | .ok _ => daemonCall cfg "eip712.decodeIntent" args
}

end LeanKohaku.Agent.ToolDefs.Decode
