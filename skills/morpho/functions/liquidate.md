# liquidate

**Signature**: `liquidate((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams,address borrower,uint256 seizedAssets,uint256 repaidShares,bytes data)`

**Selector**: `0xd8eabcb8`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe
- `borrower` (`address`): TODO(curator): describe
- `seizedAssets` (`uint256`): TODO(curator): describe
- `repaidShares` (`uint256`): TODO(curator): describe
- `data` (`bytes`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Liquidate `borrower`'s unhealthy position. Caller repays `seizedAssets` worth of debt and receives the corresponding collateral. Keeper-side; not a retail surface. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Liquidation is keeper-side; the wallet should not surface it to a retail user.
