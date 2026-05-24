# bold-liquity — interaction recipes

## Recipe: open a Trove on the ETH branch

Goal: deposit `ethAmount` of WETH-equivalent collateral, mint
`boldAmount` of BOLD at `annualInterestRate` (e.g. `5e16` for 5%).

1. Resolve branch addresses from `contracts.json` (ETH branch:
   `BorrowerOperations = 0x372a…BC65`, `TroveManager = 0x7bcb…CF5a`).
2. Read `BorrowerOperations.MCR()` — typically `110e16` (110%).
3. Read `PriceFeed.fetchPrice()` for the branch.
4. Compute `ICR = (ethAmount * price) / boldAmount`. **Refuse if
   `ICR < 1.10 * MCR`** (i.e., below 121%).
5. Compute approximate hints:
   `chain_read({to: HintHelpers, data: encode("getApproxHint(uint256 collIndex, uint256 _interestRate, uint256 _numTrials, uint256 _inputRandomSeed)", 0, annualInterestRate, ...)})`.
6. Refine hints via `SortedTroves.findInsertPosition`.
7. Compute `maxUpfrontFee` — read
   `BorrowerOperations.getInterestRateUpfrontFee` or use the
   off-chain estimator. Cap with a small slippage buffer.
8. ERC-20 approve `WETH → BorrowerOperations` if needed.
9. Build `BorrowerOperations.openTrove(
     owner = msg.sender,
     ownerIndex = 0,
     ETHAmount = ethAmount,
     boldAmount,
     upperHint, lowerHint,
     annualInterestRate,
     maxUpfrontFee,
     addManager = address(0),
     removeManager = address(0),
     receiver = msg.sender)`.
10. `tx.simulate` → `propose_send`.
11. Post-tx: read `TroveManager.troves(troveId)` to confirm the
    Trove and surface the assigned `troveId` (NFT id).

## Recipe: adjust a Trove

Goal: add `addColl` or `removeColl` collateral, mint `addBold` or
repay `removeBold`.

1. Read current Trove state: `TroveManager.troves(troveId)`.
2. Compute post-adjustment ICR using current price. Refuse if
   `< 1.10 * MCR`.
3. Build `BorrowerOperations.adjustTrove(troveId, collChange,
   isCollIncrease, debtChange, isDebtIncrease, maxUpfrontFee)`.
4. `tx.simulate` → `propose_send`.

## Recipe: close a Trove

1. Read `troves(troveId)` for current debt + collateral.
2. Allowance dance for BOLD to `BorrowerOperations`.
3. Build `BorrowerOperations.closeTrove(troveId)`.
4. `tx.simulate` → `propose_send`.

## Recipe: provide BOLD to the Stability Pool

1. Resolve branch's `StabilityPool` (per collateral type).
2. Allowance dance for BOLD to the StabilityPool.
3. Build `StabilityPool.provideToSP(amount, doClaim=true)`.
4. `tx.simulate` → `propose_send`.

## Recipe: withdraw from the Stability Pool

1. Build `StabilityPool.withdrawFromSP(amount, doClaim=true)`.
2. `doClaim=true` simultaneously sweeps any collateral gains.
3. `tx.simulate` → `propose_send`.

## Recipe: BOLD ↔ collateral redemption (advanced)

For an arb user only:

1. Resolve `CollateralRegistry`.
2. Read redemption fee: `CollateralRegistry.getRedemptionRate()`.
3. Build `CollateralRegistry.redeemCollateral(boldAmount,
   maxFeePercentage, maxIterations)`.
4. Surface the fee and the worst-case slippage.
5. `tx.simulate` → `propose_send`.

## Refusal triggers

* Post-action ICR < 1.10 × MCR.
* `_maxUpfrontFee = type(uint256).max`.
* `_annualInterestRate` outside `[1e16, 350e16]`.
* Closing a Trove the user doesn't own the NFT for.
* `redeemCollateral` outside a flagged arb workflow.
* `setAddManager` / `setRemoveManager` without an explicit user-named
  manager.

## Cross-reference

* `bridge/clearsign/registry/erc20.json` — for WETH / collateral
  approve and BOLD approve.
* No dedicated 7730 descriptor for BorrowerOperations or
  TroveManager. The wallet falls back to ABI-decoded view; these
  would be worth adding upstream.
