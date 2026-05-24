# setAddresses

**Signature**: `setAddresses((IERC20Metadata collToken,IBorrowerOperations borrowerOperations,ITroveManager troveManager,ITroveNFT troveNFT,IMetadataNFT metadataNFT,IStabilityPool stabilityPool,IPriceFeed priceFeed,IActivePool activePool,IDefaultPool defaultPool,address gasPoolAddress,ICollSurplusPool collSurplusPool,ISortedTroves sortedTroves,IInterestRouter interestRouter,IHintHelpers hintHelpers,IMultiTroveGetter multiTroveGetter,ICollateralRegistry collateralRegistry,IBoldToken boldToken,IWETH WETH) _vars)`

**Selector**: `0xe287f7b6`

**Mutability**: nonpayable

**Contract**: `AddressesRegistry` (Liquity V2 / BOLD)

## Inputs
- `_vars` (`(IERC20Metadata collToken,IBorrowerOperations borrowerOperations,ITroveManager troveManager,ITroveNFT troveNFT,IMetadataNFT metadataNFT,IStabilityPool stabilityPool,IPriceFeed priceFeed,IActivePool activePool,IDefaultPool defaultPool,address gasPoolAddress,ICollSurplusPool collSurplusPool,ISortedTroves sortedTroves,IInterestRouter interestRouter,IHintHelpers hintHelpers,IMultiTroveGetter multiTroveGetter,ICollateralRegistry collateralRegistry,IBoldToken boldToken,IWETH WETH)`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / inter-contract helper. Not a user-signed flow — Liquity branches call each other through these. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Inter-contract or admin call gated by AddressesRegistry. Not a user surface.
