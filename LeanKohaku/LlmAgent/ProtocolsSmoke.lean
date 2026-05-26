import LeanKohaku.LlmAgent.RuleParser
import LeanKohaku.Registry.KnownProtocols
import LeanKohaku.Swap.Tokens
import LeanKohaku.Ethereum.TokenRegistry

/-!
# Protocol-coverage smoke checks

End-to-end build-time anchors that exercise the chat-path pieces the
8-protocol support depends on:

* `LeanKohaku.LlmAgent.RuleParser.parse` → `RegexDraft` shape.
* `LeanKohaku.Registry.KnownProtocols.resolve` → on-chain address.
* `LeanKohaku.Ethereum.TokenRegistry.toBaseUnits` → exact base units.

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

namespace LeanKohaku.LlmAgent.ProtocolsSmoke

open LeanKohaku.LlmAgent.RuleParser (parse)
open LeanKohaku.Ethereum.Intent (Action Confidence RegexDraft)
open LeanKohaku.Registry.KnownProtocols (resolve)
open LeanKohaku.Swap.Tokens (ChainId)
open LeanKohaku.Ethereum.TokenRegistry (toBaseUnits humanUnits)

/-! ## RuleParser.parse — end-to-end on canned prompts -/

-- Aave V3 — supply / withdraw / borrow / repay flow.
example : (parse "supply 0.1 ETH to aave v3").action      = .aaveSupply   := by native_decide
example : (parse "supply 0.1 ETH to aave v3").confidence  = .high         := by native_decide
example : (parse "withdraw 0.1 ETH from aave v3").action  = .aaveWithdraw := by native_decide
example : (parse "borrow 100 USDC from aave").action      = .aaveBorrow   := by native_decide
example : (parse "repay 100 USDC to aave").action         = .aaveRepay    := by native_decide

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

-- Tornado Cash chat shortcut (PR 2) — `shield <amount> ETH with
-- tornado [cash]` now routes to .tornadoDeposit; the unshield variant
-- carries the recipient + needs the user's saved deposit note (passed
-- via tool args at the agent layer, not via regex). The bridge sidecar
-- integration is a stub until snarkjs + Baby Jubjub Pedersen lands.
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
    (parse "register vitalik.eth for 2 years").fields.lookup "durationYears"
      = some "2" ∧
    (parse "register vitalik.eth for 2 years").confidence = .high
  := by native_decide
example : (parse "renew vitalik.eth for 1 year").action = .ensRenew := by native_decide
example :
    (parse "renew vitalik.eth for 1 year").fields.lookup "durationYears" = some "1"
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

end LeanKohaku.LlmAgent.ProtocolsSmoke
