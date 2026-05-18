import LeanKohaku.Swap.Tokens

/-!
# Known DeFi protocol addresses

Static registry for protocols the wallet has hard-coded support for —
parallel to `LeanKohaku.Swap.Tokens` (tokens) and `LeanKohaku.Swap.UniV3`
(Uniswap-specific deployment addresses). Lives outside `Swap/` because
Aave V3 and Morpho Blue are not swap routers.

The trusted path uses this directly. The LLM-chat path is forbidden from
inventing addresses; any protocol it references must resolve here.

Addresses are lowercase 0x-prefixed. We intentionally omit any protocol
contract whose deployment address we could not verify on a given chain
(returning `none` is safer than shipping a wrong constant).
-/

namespace LeanKohaku.Registry.KnownProtocols

open LeanKohaku.Swap.Tokens (ChainId)

/-! ## Aave V3 Pool — the user-facing entry point (`supply`, `withdraw`,
    `borrow`, `repay`). One Pool per chain. -/

def aaveV3PoolMainnet : String := "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2"
def aaveV3PoolSepolia : String := "0x6ae43d3271ff6888e7fc43fd7321a503ff738951"

def aaveV3PoolFor : ChainId → Option String
  | .mainnet => some aaveV3PoolMainnet
  | .sepolia => some aaveV3PoolSepolia

/-! ## Morpho Blue — singleton lending primitive. Mainnet-only canonical
    deployment at the time of writing. -/

def morphoBlueMainnet : String := "0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb"

def morphoBlueFor : ChainId → Option String
  | .mainnet => some morphoBlueMainnet
  | .sepolia => none

/-- Resolve a protocol name to its address on the given chain. Names are
case-insensitive. Returns `none` when the protocol is unknown or
undeployed on the requested chain. The chat path uses this to verify
LLM-supplied protocol references; the trusted path constructs the
specific intent variants directly. -/
def resolve (name : String) (chain : ChainId) : Option String :=
  match name.toLower with
  | "aavev3pool" => aaveV3PoolFor chain
  | "aavev3"     => aaveV3PoolFor chain
  | "aave"       => aaveV3PoolFor chain
  | "morphoblue" => morphoBlueFor chain
  | "morpho"     => morphoBlueFor chain
  | _            => none

end LeanKohaku.Registry.KnownProtocols
