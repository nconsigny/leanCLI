# flashLoan

**Signature**: `flashLoan(address token,uint256 assets,bytes data)`

**Selector**: `0xe0232b42`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `token` (`address`): TODO(curator): describe
- `assets` (`uint256`): TODO(curator): describe
- `data` (`bytes`): TODO(curator): describe

## Outputs
- (none)

## What it does

Single-asset flash loan. The caller's `IMorphoFlashLoanCallback.onMorphoFlashLoan` must repay loan + 0 fee in the same tx (Morpho Blue charges no flash-loan fee). See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Flash loans require a deployed `IMorphoFlashLoanCallback` receiver. Refuse retail surfaces.
