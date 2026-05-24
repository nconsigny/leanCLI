# openTroveAndJoinInterestBatchManager

**Signature**: `openTroveAndJoinInterestBatchManager((address owner,uint256 ownerIndex,uint256 collAmount,uint256 boldAmount,uint256 upperHint,uint256 lowerHint,address interestBatchManager,uint256 maxUpfrontFee,address addManager,address removeManager,address receiver) _params)`

**Selector**: `0xc440844f`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_params` (`(address owner,uint256 ownerIndex,uint256 collAmount,uint256 boldAmount,uint256 upperHint,uint256 lowerHint,address interestBatchManager,uint256 maxUpfrontFee,address addManager,address removeManager,address receiver)`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Same as `openTrove` but immediately joins an interest-batch manager (delegated rate management). See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Pre-sign: read `TroveManager.getCurrentICR(troveId, price)` after building calldata and refuse if the post-action ICR would drop below 1.10× MCR. The MCR is 110% for ETH/WSTETH branches and may differ for RETH; resolve via `BorrowerOperations.MCR()`.
