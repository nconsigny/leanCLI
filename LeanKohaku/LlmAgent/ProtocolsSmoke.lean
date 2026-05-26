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

-- Tornado Cash — currently routed to `.unknown` with a "coming soon" note.
example : (parse "shield 1 ETH with tornado cash").action = .unknown := by native_decide

-- Railgun — same gating: canonical `shield` without a known protocol
-- protocol stays `.unknown` so the user gets routed to the Privacy menu.
example : (parse "shield 1 ETH with railgun").action = .unknown := by native_decide

-- fxUSD — chat path treats f(x) as a supply-style flow.
example : (parse "supply 1 wstETH to fxusd").action = .aaveSupply := by native_decide
example : (parse "supply 1 wstETH to fxusd").fields.lookup "protocol"
        = some "fxusd" := by native_decide

-- ENS — register / renew currently flow through `.unknown` (the chat
-- doesn't draft ENS calldata yet), but we anchor that the verbs don't
-- get mis-classified as transfers.
example : (parse "register vitalik.eth").action = .unknown := by native_decide

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
example : resolve "Liquity V2"    .mainnet = some "0x4231ec00a82bdd00f7dc9b2d3aa01ff8e51fb01e" := by native_decide
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
