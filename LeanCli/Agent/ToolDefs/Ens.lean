import LeanCli.Agent.Tools
import LeanCli.Agent.DaemonClient
import LeanCli.Encoding.Json

/-!
# ENS resolution agent tool

Surfaces the daemon's `chain.resolveName` read-only RPC to the LLM so
the agent loop can turn a human-typed name like `vitalik.eth` into a
`0x` address on its own, instead of stalling to ask the user (which is
exactly what a 4B model does when it has no resolver tool — see the
"I don't have an ENS resolution tool" stall).

The same `chain.resolveName` RPC already backs `leancli resolve` and
the `book.add` address-book path; this module just makes that one
capability available inside the agent loop too. ENS names are
mainnet-canonical, so the daemon always queries mainnet (chainId 1)
regardless of the wallet's operating chain — which is why this tool
takes **no `chainId` parameter** and therefore never trips the
chain-whitelist pin in `Tools.dispatch`.

Trust contract — same as every other tool in `LeanCli/Agent/`: this
module imports only `Agent.Tools`, `Agent.DaemonClient`, and
`Encoding.Json`. Resolution is policy-gated daemon-side
(`Ens.resolveIO cfg.policy …`); a resolved address is an input to the
standard `decode → simulate → ConfirmGate` pipeline, never a signing
authority. The user still confirms the underlying intent.
-/

namespace LeanCli.Agent.ToolDefs.Ens

open LeanCli.Agent
open LeanCli.Agent.Tools
open LeanCli.Encoding.Json

/-- Resolve an ENS name (e.g. `vitalik.eth`) to its EIP-55 checksummed
    `0x` address via the daemon's `chain.resolveName` RPC. Read-only.

    The daemon resolves against mainnet ENS regardless of the active
    chain, so there is no `chainId` parameter. Requires the daemon to
    have an ENS RPC configured (`LEANCLI_ENS_RPC_URL` / `ens_rpc_url`);
    when it is not, the tool surfaces the daemon's structured error so
    the model can tell the user resolution is unavailable rather than
    guessing an address from training data. -/
def ensResolve : ToolDecl := {
  name := "ens_resolve",
  description :=
    "Resolve an ENS name (like 'vitalik.eth') to its 0x address. \
     Read-only. Use this whenever the user names a recipient or spender \
     by an ENS name instead of a 0x address — never guess or recall an \
     address from memory. Returns {name, address, chainId, resolver}; \
     ENS always resolves on mainnet so no chain argument is needed.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "name"]),
    ("properties", .obj #[
      ("name", .obj #[
        ("type", .str "string"),
        ("description", .str "ENS name to resolve, e.g. \"vitalik.eth\"")
      ])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    let res ← daemonCall cfg "chain.resolveName" args
    -- On success, hand the model a one-line summary so a small model
    -- doesn't have to re-read the JSON envelope to grab the address.
    if res.ok then
      let nm   := (getField "name" res.data >>= asString).getD ""
      let addr := (getField "address" res.data >>= asString).getD ""
      pure { res with summary := some s!"{nm} → {addr}" }
    else
      pure res
}

end LeanCli.Agent.ToolDefs.Ens
