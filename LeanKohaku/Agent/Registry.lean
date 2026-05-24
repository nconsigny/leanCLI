import LeanKohaku.Agent.Tools
import LeanKohaku.Agent.ToolDefs.Decode
import LeanKohaku.Agent.ToolDefs.Simulate
import LeanKohaku.Agent.ToolDefs.Chain
import LeanKohaku.Agent.ToolDefs.Propose

/-!
# Default tool registry

The Phase 0 default agent surface: 7 read/propose tools mapping
1:1 to existing daemon RPCs. Splitting this out from `Agent.Loop`
keeps the loop module dependency-light and makes it obvious where
the tool inventory lives.
-/

namespace LeanKohaku.Agent.Registry

open LeanKohaku.Agent.Tools
open LeanKohaku.Agent.ToolDefs

/-- The full registry shipped with `kohaku-agent`. Operators narrow
    the surface for a given invocation via `cfg.toolAllowlist`. -/
def default : ToolRegistry := [
  Decode.decodeCalldata,
  Decode.decodeEip712,
  Simulate.txSimulate,
  Chain.chainRead,
  Chain.nonce,
  Chain.gasPrice,
  Propose.proposeSend
]

end LeanKohaku.Agent.Registry
