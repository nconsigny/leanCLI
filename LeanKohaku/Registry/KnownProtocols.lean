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

## Naming convention

`resolve` accepts BOTH bare slugs (`"aave"`, `"morpho"`) AND the
multi-word forms `LlmAgent.RuleParser` now emits (`"aave v3"`,
`"morpho blue"`, `"liquity v2"`, `"privacy pool"`, `"tornado cash"`,
`"fxusd"`). Casing is normalised internally.

## Trust contract

* Privacy plugins (Railgun, Privacy Pool, Tornado Cash) ONLY expose
  the user-facing entrypoint here. The agent never drafts shielded
  calldata; SDK-prepared txs flow through the standard
  `decodeIntent → simulate → ConfirmGate` pipeline, and this registry
  is only used for "does the user-facing protocol exist on this
  chain?" disambiguation.
* Tornado Cash is listed as "coming soon" in the chat surface (see
  `feedback_no_ofac_no_refuse`). The address entries are present so
  decode + display work; the drafting path is intentionally absent.
* fxUSD currently lists only the wstETH branch — the asset most users
  interact with. Other branches (sfrxETH, weETH, …) will be added
  when the wallet ships drafting for them.
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

/-! ## Morpho Bundler V3 — user-facing multicall router for vault flows.

`MorphoBundlerV3` is the contract clear-signing-erc7730-registry's
upstream `calldata-MorphoBundlerV3.json` descriptor binds against. We
list the address so the LLM picker can route "morpho v3" / "morpho
bundler" prompts to the right surface. -/

def morphoBundlerV3Mainnet : String := "0x6566194141eefa99af43bb5aa71460ca2dc90f07"

def morphoBundlerV3For : ChainId → Option String
  | .mainnet => some morphoBundlerV3Mainnet
  | .sepolia => none

/-! ## ENS — controller (registrar V2) + public resolver. The two
    addresses users actually call when registering / renewing / setting
    records. -/

/-- ETHRegistrarController v3 — the contract `register`/`renew` is
called against. See ens.docs / `ETHRegistrarControllerV3`. -/
def ensControllerMainnet : String := "0x253553366da8546fc250f225fe3d25d0c782303b"

/-- ENS Public Resolver — the contract `setAddr`/`setName`/`setText`
is called against. -/
def ensPublicResolverMainnet : String := "0x231b0ee14048e9dccd1d247744d114a4eb5e8e63"

def ensControllerFor : ChainId → Option String
  | .mainnet => some ensControllerMainnet
  | .sepolia => some "0xfb3ce5d01e0f33f41dbb39035db9745962f1f968"

def ensPublicResolverFor : ChainId → Option String
  | .mainnet => some ensPublicResolverMainnet
  | .sepolia => some "0x8fade66b79cc9f707ab26799354482eb93a5b7dd"

/-! ## Liquity V2 (BOLD) — user-facing entry points. The frontend env
file (`liquity/bold/frontend/app/.env`) is the source of truth for
mainnet addresses. -/

/-- BorrowerOperations — `openTrove` / `closeTrove` / `adjustTrove`. -/
def liquityV2BorrowerOpsEthMainnet : String := "0x4231ec00a82bdd00f7dc9b2d3aa01ff8e51fb01e"

/-- CollateralRegistry — discovers per-collateral branches. -/
def liquityV2CollateralRegistryMainnet : String := "0xf949982b91c8c61e952b3ba942cbbfaef5386684"

/-- BoldToken (ERC-20). -/
def liquityV2BoldTokenMainnet : String := "0x6440f144b7e50d6a8439336510312d2f54beb01d"

def liquityV2BorrowerOpsFor : ChainId → Option String
  | .mainnet => some liquityV2BorrowerOpsEthMainnet
  | .sepolia => none

def liquityV2CollateralRegistryFor : ChainId → Option String
  | .mainnet => some liquityV2CollateralRegistryMainnet
  | .sepolia => none

def liquityV2BoldTokenFor : ChainId → Option String
  | .mainnet => some liquityV2BoldTokenMainnet
  | .sepolia => some "0x620ce1130f7c63457784cdfa31cfccbfb6be5029"

/-! ## Railgun Smart Wallet — proxy users call. Logic implementation is
    behind EIP-1967 storage slot; user calldata targets the proxy. -/

def railgunSmartWalletMainnet : String := "0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9"

def railgunSmartWalletFor : ChainId → Option String
  | .mainnet => some railgunSmartWalletMainnet
  | .sepolia => none

/-! ## Privacy Pool Entrypoint — single deposit/withdraw surface. -/

def privacyPoolEntrypointMainnet : String := "0x6818809eefce719e480a7526d76bd3e561526b46"
def privacyPoolEntrypointSepolia : String := "0x9d8d4cdfed605293dc8826bc2d2a2c7fb867edd0"

def privacyPoolEntrypointFor : ChainId → Option String
  | .mainnet => some privacyPoolEntrypointMainnet
  | .sepolia => some privacyPoolEntrypointSepolia

/-! ## Tornado Cash ETH pools — four denominations on mainnet. Listed
    for decode coverage; drafting path is intentionally absent (see
    module docstring). -/

def tornadoCashEth01Mainnet  : String := "0x12d66f87a04a9e220743712ce6d9bb1b5616b8fc"
def tornadoCashEth1Mainnet   : String := "0x47ce0c6ed5b0ce3d3a51fdb1c52dc66a7c3c2936"
def tornadoCashEth10Mainnet  : String := "0x910cbd523d972eb0a6f4cae4618ad62622b39dbf"
def tornadoCashEth100Mainnet : String := "0xa160cdab225685da1d56aa342ad8841c3b53f291"

/-- Default Tornado pool when no denomination is supplied. -/
def tornadoCashDefaultFor : ChainId → Option String
  | .mainnet => some tornadoCashEth1Mainnet
  | .sepolia => none

/-! ## fxUSD — wstETH branch (the primary user-facing market). Other
    branches (sfrxETH, weETH, etc.) will be added when drafting ships. -/

def fxUsdTokenMainnet : String := "0x085780639cc2cacd35e474e71f4d000e2405d8f6"
def fxUsdWstethMarketMainnet : String := "0xad9a0e7c08bc9f747df97a3e7e7f620632cb6155"
def fxUsdWstethTreasuryMainnet : String := "0xed803540037b0ae069c93420f89cd653b6e3df1f"

def fxUsdTokenFor : ChainId → Option String
  | .mainnet => some fxUsdTokenMainnet
  | .sepolia => none

def fxUsdMarketFor : ChainId → Option String
  | .mainnet => some fxUsdWstethMarketMainnet
  | .sepolia => none

/-! ## Name resolution -/

/-- ASCII-fold + collapse any internal whitespace to a single space so
`"  Morpho   Blue "` normalises to `"morpho blue"`. Total, no IO. -/
private def normalizeProtocolName (s : String) : String :=
  let lowered := s.toLower
  let chars := lowered.trimAscii.toString.toList
  -- Walk once, collapse runs of whitespace.
  let collapsed := Id.run do
    let mut out : List Char := []
    let mut prevWs : Bool := false
    for c in chars do
      if c == ' ' ∨ c == '\t' then
        if ¬ prevWs then out := out ++ [' ']
        prevWs := true
      else
        out := out ++ [c]
        prevWs := false
    pure out
  String.ofList collapsed

/-- Resolve a protocol designator to its primary on-chain address on
the given chain. Accepts:

* Bare slug (`"aave"`, `"morpho"`, `"ens"`).
* Versioned multi-word form (`"aave v3"`, `"morpho blue"`,
  `"liquity v2"`, `"privacy pool"`, `"tornado cash"`).
* Vendor-specific aliases (`"fxusd"`, `"f(x)"`).

Returns `none` when the protocol is unknown or undeployed on the
requested chain. Used by the chat path to verify LLM-supplied
protocol references; the trusted path constructs the specific intent
variants directly. -/
def resolve (name : String) (chain : ChainId) : Option String :=
  match normalizeProtocolName name with
  -- Aave
  | "aave" | "aave v3" | "aavev3" | "aavev3pool"
      => aaveV3PoolFor chain
  -- Morpho
  | "morpho" | "morpho blue" | "morphoblue"
      => morphoBlueFor chain
  | "morpho v3" | "morpho bundler" | "morpho bundler v3"
      => morphoBundlerV3For chain
  -- ENS
  | "ens" | "ens controller" | "ens registrar"
      => ensControllerFor chain
  | "ens resolver" | "ens public resolver"
      => ensPublicResolverFor chain
  -- Liquity V2 (BOLD)
  | "liquity" | "liquity v2" | "bold" | "bold liquity"
      => liquityV2BorrowerOpsFor chain
  | "liquity collateral" | "liquity v2 collateral"
      => liquityV2CollateralRegistryFor chain
  -- Railgun
  | "railgun" | "railgun smart wallet"
      => railgunSmartWalletFor chain
  -- Privacy Pool
  | "privacy pool" | "privacy pools" | "0xbow" | "privacy pool entrypoint"
      => privacyPoolEntrypointFor chain
  -- Tornado Cash
  | "tornado" | "tornado cash" | "tornadocash"
      => tornadoCashDefaultFor chain
  -- fxUSD
  | "fxusd" | "fx usd" | "f(x)" | "fx protocol" | "fxusd market"
      => fxUsdMarketFor chain
  | "fxusd token"
      => fxUsdTokenFor chain
  | _ => none

/-! ### Build-time anchors

`native_decide` checks pin the canonical name → address mapping. Any
typo in a constant or accidental rename of a slug breaks the build
before the daemon can route a chat draft to the wrong contract. -/

example : resolve "Aave"          .mainnet = some aaveV3PoolMainnet := by native_decide
example : resolve "aave v3"       .mainnet = some aaveV3PoolMainnet := by native_decide
example : resolve "Morpho Blue"   .mainnet = some morphoBlueMainnet := by native_decide
example : resolve "morpho"        .sepolia = none := by native_decide
example : resolve "ENS"           .mainnet = some ensControllerMainnet := by native_decide
example : resolve "ens resolver"  .mainnet = some ensPublicResolverMainnet := by native_decide
example : resolve "liquity v2"    .mainnet = some liquityV2BorrowerOpsEthMainnet := by native_decide
example : resolve "BOLD"          .mainnet = some liquityV2BorrowerOpsEthMainnet := by native_decide
example : resolve "Railgun"       .mainnet = some railgunSmartWalletMainnet := by native_decide
example : resolve "privacy pool"  .mainnet = some privacyPoolEntrypointMainnet := by native_decide
example : resolve "privacy pool"  .sepolia = some privacyPoolEntrypointSepolia := by native_decide
example : resolve "tornado cash"  .mainnet = some tornadoCashEth1Mainnet := by native_decide
example : resolve "fxUSD"         .mainnet = some fxUsdWstethMarketMainnet := by native_decide
example : resolve "fx protocol"   .mainnet = some fxUsdWstethMarketMainnet := by native_decide
example : resolve "unknown"       .mainnet = none := by native_decide

end LeanKohaku.Registry.KnownProtocols
