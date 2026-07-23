import LeanCli.LlmAgent.RuleParser
import LeanCli.LlmAgent.DirectSynth
import LeanCli.Registry.KnownProtocols
import LeanCli.Swap.Tokens
import LeanCli.Ethereum.TokenRegistry

/-!
# Protocol-coverage smoke checks

End-to-end build-time anchors that exercise the chat-path pieces the
8-protocol support depends on:

* `LeanCli.LlmAgent.RuleParser.parse` → `RegexDraft` shape.
* `LeanCli.Registry.KnownProtocols.resolve` → on-chain address.
* `LeanCli.Ethereum.TokenRegistry.toBaseUnits` → exact base units.

Each protocol gets at least one canned English prompt that lands on
the canonical `Action`, fills the expected fields, and resolves to
known constants. `native_decide` runs everything at `lake build`,
which is the project test runner. Any regression in tokenisation,
amount normalisation, protocol name normalisation, or address
constants breaks the build before the daemon ever sees a real prompt.

This module deliberately contains ONLY `example` declarations — no
exported names. The `import` graph mirrors what the chat draft path
actually touches at runtime.
-/

namespace LeanCli.LlmAgent.ProtocolsSmoke

open LeanCli.LlmAgent.RuleParser (parse)
open LeanCli.Ethereum.Intent (Action Confidence RegexDraft)
open LeanCli.Registry.KnownProtocols (resolve)
open LeanCli.Swap.Tokens (ChainId)
open LeanCli.Ethereum.TokenRegistry (toBaseUnits humanUnits)

/-! ## RuleParser.parse — end-to-end on canned prompts -/

-- Aave V3 — supply / withdraw / borrow / repay flow.
example : (parse "supply 0.1 ETH to aave v3").action      = .aaveSupply   := by native_decide
example : (parse "supply 0.1 ETH to aave v3").confidence  = .high         := by native_decide
example : (parse "withdraw 0.1 ETH from aave v3").action  = .aaveWithdraw := by native_decide
example : (parse "borrow 100 USDC from aave").action      = .aaveBorrow   := by native_decide
example : (parse "repay 100 USDC to aave").action         = .aaveRepay    := by native_decide
-- "into" is a common English equivalent of "to" / "on" for lending
-- deposits ("supply 10 USDC into aave V3"); regex now accepts it so
-- DirectSynth handles the phrasing without falling through to the LLM.
example : (parse "supply 10 USDC into aave v3").action    = .aaveSupply   := by native_decide
-- "using <slot>" is a common sender-hint synonym for "from <slot>"
-- ("supply X into aave v3 using leanWallet/0"); extractFromHint picks
-- it up so chat.draft's wallet resolver can substitute the 0x address.
example :
    (parse "supply 10 USDC into aave v3 using leanwallet/0").fields.lookup "from"
      = some "leanwallet/0"
  := by native_decide

-- Morpho — protocol field carries the multi-word form.
example :
    (parse "supply 1k DAI to morpho blue").action  = .aaveSupply ∧
    (parse "supply 1k DAI to morpho blue").fields.lookup "protocol" = some "morpho blue" ∧
    (parse "supply 1k DAI to morpho blue").fields.lookup "amount"   = some "1000"
  := by native_decide

-- Liquity V2 / BOLD — multi-word with version qualifier.
example : (parse "deposit 5 ETH on liquity v2").fields.lookup "protocol"
        = some "liquity v2" := by native_decide

-- Privacy Pool — canonical "shield" verb, requires explicit protocol.
example : (parse "shield 0.05 ETH with privacy pool").action = .shieldedDeposit := by native_decide
example : (parse "unshield 0.05 ETH with privacy pool to 0x0000000000000000000000000000000000000001").action
        = .shieldedWithdraw := by native_decide

-- Tornado Cash chat shortcut — `shield <amount> ETH with tornado
-- [cash]` routes to .tornadoDeposit; the unshield variant carries the
-- recipient in `to`. No saved note is involved anywhere: the bridge
-- (live, @kohaku-eth/tornado-cash) derives note secrets from the
-- wallet seed.
example : (parse "shield 1 ETH with tornado cash").action = .tornadoDeposit := by native_decide
example : (parse "shield 1 ETH with tornado").action = .tornadoDeposit := by native_decide
example :
    (parse "shield 1 ETH with tornado cash").fields.lookup "protocol" = some "tornado cash" ∧
    (parse "shield 1 ETH with tornado cash").fields.lookup "amount"   = some "1"
  := by native_decide
example :
    (parse "unshield 1 ETH with tornado to 0x0000000000000000000000000000000000000001").action
      = .tornadoWithdraw ∧
    (parse "unshield 1 ETH with tornado to 0x0000000000000000000000000000000000000001").fields.lookup "to"
      = some "0x0000000000000000000000000000000000000001"
  := by native_decide

-- Tornado DirectSynth (pure Lean, no LLM). Regression anchor for the
-- chat path falling through to the LLM — which then answered from
-- stale knowledge ("SDK not yet shipped / coming soon") — on a prompt
-- the wallet fully understands. The daemon injects `amountBase`
-- before calling synth; we simulate that with `setField`. The prompt
-- is the exact user phrasing that fell through (sender hint + chain
-- qualifier included).
example :
    (match LeanCli.LlmAgent.DirectSynth.synth
        ((parse "shield 0.1 ETH from mainEOA with tornado cash on sepolia").setField
          "amountBase" "100000000000000000")
        11155111 none with
     | .ok (.tornadoDeposit 11155111 100000000000000000) => true
     | _ => false) = true
  := by native_decide
example :
    (match LeanCli.LlmAgent.DirectSynth.synth
        ((parse "unshield 1 ETH with tornado to 0x0000000000000000000000000000000000000001").setField
          "amountBase" "1000000000000000000")
        11155111 none with
     | .ok (.tornadoWithdraw 11155111 1000000000000000000 _ "") => true
     | _ => false) = true
  := by native_decide
-- Multi-note amounts synthesize; non-0.1 multiples remain rejected.
example :
    (match LeanCli.LlmAgent.DirectSynth.synth
        ((parse "shield 0.2 ETH with tornado cash").setField
          "amountBase" "200000000000000000")
        11155111 none with
     | .ok (.tornadoDeposit 11155111 200000000000000000) => true
     | _ => false) = true
  := by native_decide
example :
    (match LeanCli.LlmAgent.DirectSynth.synth
        ((parse "unshield 0.05 ETH with tornado cash to 0x0000000000000000000000000000000000000001").setField
          "amountBase" "50000000000000000")
        11155111 none with
     | .error _ => true
     | .ok _ => false) = true
  := by native_decide

-- Railgun chat shortcut (PR 1) — `shield <amount> ETH with railgun`
-- now routes to `.railgunShield`; the unshield variant carries the
-- recipient address through to the `to` field for DirectSynth.
example : (parse "shield 1 ETH with railgun").action = .railgunShield := by native_decide
example :
    (parse "shield 1 ETH with railgun").fields.lookup "protocol" = some "railgun" ∧
    (parse "shield 1 ETH with railgun").fields.lookup "amount"   = some "1"
  := by native_decide
example :
    (parse "unshield 0.05 ETH with railgun to 0x0000000000000000000000000000000000000001").action
      = .railgunUnshield ∧
    (parse "unshield 0.05 ETH with railgun to 0x0000000000000000000000000000000000000001").fields.lookup "to"
      = some "0x0000000000000000000000000000000000000001"
  := by native_decide

-- fxUSD — chat path treats f(x) as a supply-style flow.
example : (parse "supply 1 wstETH to fxusd").action = .aaveSupply := by native_decide
example : (parse "supply 1 wstETH to fxusd").fields.lookup "protocol"
        = some "fxusd" := by native_decide

-- ENS — register / renew now have a chat-side draft path that the
-- skill card orchestrates through the commit/reveal pair. Drafts
-- carry the verb + ENS name + duration in years.
example : (parse "register vitalik.eth").action = .ensRegister := by native_decide
example :
    (parse "register vitalik.eth for 2 years").fields.lookup "name"
      = some "vitalik.eth" ∧
    (parse "register vitalik.eth for 2 years").fields.lookup "durationNum"
      = some "2" ∧
    (parse "register vitalik.eth for 2 years").fields.lookup "durationUnit"
      = some "years" ∧
    (parse "register vitalik.eth for 2 years").confidence = .high
  := by native_decide
example : (parse "renew vitalik.eth for 1 year").action = .ensRenew := by native_decide
example :
    (parse "renew vitalik.eth for 1 year").fields.lookup "durationNum" = some "1" ∧
    (parse "renew vitalik.eth for 1 year").fields.lookup "durationUnit" = some "year"
  := by native_decide
-- Duration without the "year(s)" unit lowers confidence so the skill
-- card asks for clarification.
example : (parse "register vitalik.eth for 5").confidence = .medium := by native_decide

-- ENS resolver actions — set primary + set reverse name.
example : (parse "set primary to vitalik.eth").action = .ensSetAddr := by native_decide
example : (parse "set name to vitalik.eth").action   = .ensSetName := by native_decide
example :
    (parse "set primary to vitalik.eth").fields.lookup "to"
      = some "vitalik.eth" ∧
    (parse "set name to vitalik.eth").fields.lookup "newName"
      = some "vitalik.eth"
  := by native_decide

-- New protocol verbs.
example : (parse "mint 100 fxusd with wstETH").action      = .protocolMint   := by native_decide
example : (parse "redeem 100 fxusd for wstETH").action     = .protocolRedeem := by native_decide
example : (parse "open trove with 5 ETH for 1000 BOLD at 7.5%").action
        = .liquityOpenTrove := by native_decide
example :
    (parse "open trove with 5 ETH for 1000 BOLD at 7.5%").fields.lookup "branch" = some "eth" ∧
    (parse "open trove with 5 ETH for 1000 BOLD at 7.5%").fields.lookup "collAmount" = some "5" ∧
    (parse "open trove with 5 ETH for 1000 BOLD at 7.5%").fields.lookup "boldAmount" = some "1000" ∧
    (parse "open trove with 5 ETH for 1000 BOLD at 7.5%").fields.lookup "rate" = some "7.5%"
  := by native_decide
example : (parse "close trove 42 on wstETH").action = .liquityCloseTrove := by native_decide
example :
    (parse "close trove 42 on wstETH").fields.lookup "troveId" = some "42" ∧
    (parse "close trove 42 on wstETH").fields.lookup "branch"  = some "wsteth"
  := by native_decide

-- Claim / stake / unstake.
example : (parse "claim from liquity v2").action = .protocolClaim := by native_decide
example :
    (parse "claim from liquity v2").fields.lookup "protocol" = some "liquity v2"
  := by native_decide
example : (parse "stake 1 ETH via lido").action   = .stake   := by native_decide
example : (parse "unstake 1 ETH via lido").action = .unstake := by native_decide
-- Bare stake defaults to lido without explicit `via`.
example :
    (parse "stake 1 ETH").fields.lookup "protocol" = some "lido"
  := by native_decide

/-! ## Smarter NL parsing

Range amounts, multi-unit durations, explicit minOut, and conjunction
detection. Each canonical form anchored so a regression in the
helpers (`parseRange`, `durationUnitSeconds`, the minOut sweep)
breaks `lake build` immediately. -/

-- Range amount: floor goes into amountIn, ceiling into amountInMax.
example :
    (parse "swap 1-2 ETH for USDC with 0.5% slippage").fields.lookup "amountIn"
      = some "1" ∧
    (parse "swap 1-2 ETH for USDC with 0.5% slippage").fields.lookup "amountInMax"
      = some "2"
  := by native_decide
example :
    (parse "swap 0.5-1.5k usdc for weth with 0.3% slippage").fields.lookup "amountIn"
      = some "0.5" ∧
    (parse "swap 0.5-1.5k usdc for weth with 0.3% slippage").fields.lookup "amountInMax"
      = some "1500"
  := by native_decide

-- Explicit minOut overrides the slippage-percentage path.
example :
    (parse "swap 1 ETH for USDC minimum 3000 USDC").fields.lookup "minAmountOut"
      = some "3000" ∧
    (parse "swap 1 ETH for USDC minimum 3000 USDC").confidence = .high
  := by native_decide
example :
    (parse "swap 1 ETH for USDC at least 3000").fields.lookup "minAmountOut"
      = some "3000"
  := by native_decide
example :
    (parse "swap 1 ETH for USDC min 2500").fields.lookup "minAmountOut"
      = some "2500"
  := by native_decide

-- Multi-unit durations on ENS register/renew.
example :
    (parse "register vitalik.eth for 30 days").fields.lookup "durationSeconds"
      = some "2592000" ∧
    (parse "register vitalik.eth for 30 days").confidence = .high
  := by native_decide
example :
    (parse "renew vitalik.eth for 6 weeks").fields.lookup "durationSeconds"
      = some "3628800"
  := by native_decide
example :
    (parse "register vitalik.eth for 3 months").fields.lookup "durationSeconds"
      = some "7776000"
  := by native_decide
example :
    (parse "register vitalik.eth for 2 years").fields.lookup "durationSeconds"
      = some "63072000"
  := by native_decide

-- Conjunction detection: only fires when no single-leg matcher
-- consumes the prompt. Prompts where the first token is a known verb
-- still go through the single-leg path; this branch is for the
-- residue ("100 USDC and 50 USDT to alice.eth" — no verb in position
-- 0, no single-leg shape).
example :
    (parse "100 USDC and 50 USDT to alice.eth").confidence = .medium ∧
    (parse "100 USDC and 50 USDT to alice.eth").fields.lookup "conjunction"
      = some "and"
  := by native_decide

/-! ## Token + protocol disambiguation -/

-- USDC.e / DAI.e / WETH.e bridge variants normalise to canonical
-- mainnet symbols (we don't track L2 deployments yet, so we route to
-- the closest-thing-on-mainnet).
example :
    LeanCli.Swap.Tokens.disambiguateSymbol "USDC.e"      = "USDC" ∧
    LeanCli.Swap.Tokens.disambiguateSymbol "USDC-e"      = "USDC" ∧
    LeanCli.Swap.Tokens.disambiguateSymbol "bridged-USDC" = "USDC" ∧
    LeanCli.Swap.Tokens.disambiguateSymbol "DAI.e"       = "DAI"  ∧
    LeanCli.Swap.Tokens.disambiguateSymbol "WETH.e"      = "WETH" ∧
    LeanCli.Swap.Tokens.disambiguateSymbol "eth2"        = "ETH"  ∧
    LeanCli.Swap.Tokens.disambiguateSymbol "USDC"        = "USDC"  -- canonical pass-through
  := by native_decide

-- findBySymbol applies disambiguation transparently.
example :
    (LeanCli.Swap.Tokens.findBySymbol "USDC.e").isSome ∧
    (LeanCli.Swap.Tokens.findBySymbol "usdc-bridged").isNone
      -- "usdc-bridged" uses '-' as a separator, gets split by tokenize
      -- (which is upstream); raw lookup with that string isn't a
      -- recognised normalisation, so we expect a miss here. The chat
      -- path tokenises before lookup.
  := by native_decide

-- Asset → default-protocol routing.
example :
    LeanCli.Registry.KnownProtocols.defaultProtocolForAsset "BOLD"
      = some "liquity v2" ∧
    LeanCli.Registry.KnownProtocols.defaultProtocolForAsset "fxusd"
      = some "fxusd" ∧
    LeanCli.Registry.KnownProtocols.defaultProtocolForAsset "MORPHO"
      = some "morpho blue" ∧
    LeanCli.Registry.KnownProtocols.defaultProtocolForAsset "USDC"
      = none  -- too many reasonable destinations; user must specify
  := by native_decide

-- End-to-end: "supply 1000 BOLD" with no protocol clause infers
-- Liquity V2 from the asset and lands on .aaveSupply (the
-- bare-verb default) with confidence .medium (always-medium for
-- inferred protocols).
example :
    (parse "supply 1000 BOLD").action = .aaveSupply ∧
    (parse "supply 1000 BOLD").fields.lookup "protocol" = some "liquity v2" ∧
    (parse "supply 1000 BOLD").fields.lookup "inferredProtocol" = some "true" ∧
    (parse "supply 1000 BOLD").confidence = .medium
  := by native_decide

-- Same shape for fxUSD.
example :
    (parse "supply 100 fxusd").fields.lookup "protocol" = some "fxusd" ∧
    (parse "supply 100 fxusd").fields.lookup "inferredProtocol" = some "true"
  := by native_decide

-- Generic stablecoins have no default → fall through past the
-- asset-default matcher; no protocol field is populated.
example :
    (parse "supply 1000 USDC").fields.lookup "inferredProtocol" = none
  := by native_decide

/-! ## New top assets — registry coverage

Every newly-added symbol resolves via `findBySymbol` so the chat
path's `isKnownSymbol` check accepts the canonical form. Decimals
are anchored because off-by-12-zeros bugs are catastrophic. -/

-- USDC + USDT: symbol resolves, but mainnet address is deliberately
-- omitted at curator request. Sepolia entry kept where it exists.
example : (LeanCli.Swap.Tokens.findBySymbol "USDC").isSome := by native_decide
example : ((LeanCli.Swap.Tokens.findBySymbol "USDC").bind
            (fun t => LeanCli.Swap.Tokens.addressOn t .mainnet)) = none := by native_decide
example : ((LeanCli.Swap.Tokens.findBySymbol "USDC").bind
            (fun t => LeanCli.Swap.Tokens.addressOn t .sepolia))
          = some "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238" := by native_decide
example : ((LeanCli.Swap.Tokens.findBySymbol "USDT").bind
            (fun t => LeanCli.Swap.Tokens.addressOn t .mainnet)) = none := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "USDT").map (·.decimals) = some 6  := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "GHO").map  (·.decimals) = some 18 := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "CRV").map  (·.decimals) = some 18 := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "LUSD").map (·.decimals) = some 18 := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "cbETH").map (·.decimals) = some 18 := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "sDAI").map (·.decimals) = some 18  := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "USDS").map (·.decimals) = some 18  := by native_decide
-- Removed tokens are no longer in the registry:
example : (LeanCli.Swap.Tokens.findBySymbol "MKR").isNone     := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "SNX").isNone     := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "BAL").isNone     := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "cbBTC").isNone   := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "sfrxETH").isNone := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "PYUSD").isNone   := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "weETH").isNone   := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "USDe").isNone    := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "LDO").isNone     := by native_decide
example : (LeanCli.Swap.Tokens.findBySymbol "LINK").isNone    := by native_decide

-- Cashtag-prefixed parses still resolve the asset (RuleParser's
-- isKnownSymbol strips `$` via stripCashtag before findBySymbol).
example :
    (parse "send 100 $USDT to vitalik.eth").fields.lookup "asset" = some "usdt"
  := by native_decide
example :
    (parse "send 5 $UNI to 0x0000000000000000000000000000000000000001").fields.lookup "asset"
      = some "uni"
  := by native_decide

/-! ## Uniswap V3 default fee-tier routing through matchSwap

When the user doesn't name a fee tier inline, matchSwap picks one
from the pair classification. The smoke anchor pins each tier so a
classification regression breaks the build. -/

example :
    (parse "swap 1000 USDC for USDT with 0.05% slippage").fields.lookup "feeTier" = some "100"
  := by native_decide
example :
    (parse "swap 1 WETH for USDC with 0.5% slippage").fields.lookup "feeTier" = some "500"
  := by native_decide
example :
    (parse "swap 0.1 WETH for WBTC with 0.3% slippage").fields.lookup "feeTier" = some "500"
  := by native_decide
example :
    (parse "swap 100 LDO for USDC with 1% slippage").fields.lookup "feeTier" = some "3000"
  := by native_decide
example :
    (parse "swap 1 ETH for wstETH with 0.05% slippage").fields.lookup "feeTier" = some "500"
  := by native_decide

-- Cashtag + suffix end-to-end.
example :
    (parse "send $1.5k usdc to vitalik.eth").action     = .erc20Transfer ∧
    (parse "send $1.5k usdc to vitalik.eth").fields.lookup "amount" = some "1500" ∧
    (parse "send $1.5k usdc to vitalik.eth").fields.lookup "asset"  = some "usdc"
  := by native_decide

-- Comma-grouped numeral survives tokenisation.
example :
    (parse "send 1,500.5 usdc to vitalik.eth").fields.lookup "amount" = some "1500.5"
  := by native_decide

/-! ## KnownProtocols.resolve — protocol name → address -/

-- The 8 protocols + their multi-word forms all resolve.
example : resolve "Aave"          .mainnet = some "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2" := by native_decide
example : resolve "aave v3"       .mainnet = some "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2" := by native_decide
example : resolve "Morpho Blue"   .mainnet = some "0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb" := by native_decide
example : resolve "ENS"           .mainnet = some "0x253553366da8546fc250f225fe3d25d0c782303b" := by native_decide
-- Liquity V2 BorrowerOperations (ETH branch). Bare slug resolves to
-- the ETH-collateral branch per liquityV2BorrowerOpsFor_ETH; the
-- per-branch addresses (wstETH / rETH) have their own anchors in
-- KnownProtocols.lean.
example : resolve "Liquity V2"    .mainnet = some "0x372abd1810eaf23cb9d941bbe7596dfb2c46bc65" := by native_decide
example : resolve "Railgun"       .mainnet = some "0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9" := by native_decide
example : resolve "privacy pool"  .mainnet = some "0x6818809eefce719e480a7526d76bd3e561526b46" := by native_decide
-- Default Tornado pool resolves to the 1-ETH instance (not the
-- 0.1-ETH one).
example : resolve "tornado cash"  .mainnet = some "0x47ce0c6ed5b0ce3d3a51fdb1c52dc66a7c3c2936" := by native_decide
example : resolve "fxUSD"         .mainnet = some "0xad9a0e7c08bc9f747df97a3e7e7f620632cb6155" := by native_decide

/-! ## TokenRegistry.toBaseUnits — exact decimal → base units

`Except String String` has no `DecidableEq` instance available here,
so we project through `.toOption` to land in `Option String` (which
does) before comparing. -/

-- USDC (6 dec) — round-trip the RuleParser's canonical decimal.
example : (toBaseUnits "1500"      6).toOption = some "1500000000"          := by native_decide
example : (toBaseUnits "1500.5"    6).toOption = some "1500500000"          := by native_decide
example : (toBaseUnits "0.000001"  6).toOption = some "1"                   := by native_decide
-- ETH (18 dec).
example : (toBaseUnits "1"        18).toOption = some "1000000000000000000" := by native_decide
example : (toBaseUnits "0.05"     18).toOption = some "50000000000000000"   := by native_decide
example : (toBaseUnits "0.000000000000000001" 18).toOption = some "1"        := by native_decide
-- WBTC (8 dec).
example : (toBaseUnits "0.1"       8).toOption = some "10000000"            := by native_decide
-- Rejects over-precision.
example : (toBaseUnits "0.5"       0).toOption = none                       := by native_decide
example : (toBaseUnits "1.234567"  6).toOption = some "1234567"             := by native_decide
example : (toBaseUnits "1.2345678" 6).toOption = none                       := by native_decide  -- 7 > 6

end LeanCli.LlmAgent.ProtocolsSmoke
