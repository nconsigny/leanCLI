# setFee

**Signature**: `setFee((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams,uint256 newFee)`

**Selector**: `0x2b4f013c`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe
- `newFee` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Governance / admin function. The Morpho Blue owner can enable IRMs, enable LLTVs, set fees, and re-assign the fee recipient. Not a user surface. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Admin gate by `owner()` — not a user surface.
