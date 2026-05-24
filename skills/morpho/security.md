# morpho — security

## Pre-sign checklist (every Blue call)

1. Compute `id = keccak256(abi.encode(marketParams))` locally; do
   not trust a sidecar's `id`.
2. Read `idToMarketParams(id)` and confirm the returned tuple
   matches your input `(loanToken, collateralToken, oracle, irm,
   lltv)`. Refuse if it doesn't (the market was created from
   different params and happens to collide — never happens in
   practice, but the check is cheap).
3. Read the market's `oracle` and `irm` addresses. Refuse if either
   is not on the user's allow-list of trusted oracles / IRMs.
4. For `borrow` / `withdrawCollateral`: read `position(id, user)`
   and `market(id)`, compute post-action collateralisation, and
   refuse if it would drop below 1.05× LLTV.
5. For `supplyCollateral` / `repay`: verify allowance on the
   relevant token (`marketParams.collateralToken` /
   `marketParams.loanToken`) to the Morpho contract.
6. For `setAuthorizationWithSig`: this is delegating wallet control
   to a third party. Decode the typed-data fields `authorizer`,
   `authorized`, `isAuthorized`, `nonce`, `deadline` and refuse if
   any are missing from the rendered prompt.

## Refusal triggers

* `oracle` or `irm` not on user's trusted list.
* `flashLoan` from a retail flow (requires a deployed receiver).
* `liquidate` from a retail flow.
* `createMarket` outside an explicit curator workflow.
* `setAuthorization(authorized=msg.sender, isAuthorized=true)` —
  self-authorization is meaningless.
* MetaMorpho `createMetaMorpho` with `initialTimelock = 0` —
  vaults without a timelock allow the curator to drain at will.

## Callback re-entrancy

Morpho Blue's `supply`, `repay`, `supplyCollateral`, `flashLoan`,
and `liquidate` accept arbitrary `data` that triggers a callback on
the caller (`IMorphoCallback.onMorphoXXX`). Smart-contract callers
must guard against re-entrancy. For EOA callers (the wallet's
default), the wallet should always pass empty `data`. **Refuse to
sign a Morpho Blue call with non-empty `data` from an EOA** — there
is no reason to.

## Oracle and IRM ecosystem

Morpho Blue is intentionally **unopinionated** about oracles and
IRMs. The result is that the wallet's safety relies entirely on the
user's choice of market. The agent should:

* Prefer markets whose `oracle` is one of: Morpho Chainlink Oracle,
  MorphoChainlinkOracleV2, ChainlinkAdapter, RedstoneAdapter — i.e.
  oracle adapters maintained by the Morpho team.
* Prefer markets whose `irm` is the canonical
  `AdaptiveCurveIrm` (the only IRM Morpho Labs publishes).
* Surface the `oracle` / `irm` addresses explicitly when proposing
  any borrow / supply / supplyCollateral.

## MetaMorpho-specific risks

* The vault `curator` chooses which markets to allocate to. A
  malicious curator can allocate the user's deposit into a market
  with a malicious oracle.
* The `guardian` can veto allocations. If the vault has no
  guardian (`address(0)`), the curator is unopposed.
* The vault's `timelock` is the only delay between a proposal and
  execution. A 1-second timelock effectively means no delay.

## Citations

* <https://docs.morpho.org/morpho/contracts/morpho-blue>
* <https://docs.morpho.org/curation/concepts/metamorpho>
* <https://github.com/morpho-org/morpho-blue/blob/main/SECURITY.md>
