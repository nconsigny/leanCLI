# createMarket

**Signature**: `createMarket((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams)`

**Selector**: `0x8c1358a2`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe

## Outputs
- (none)

## What it does

Permissionless creation of a new isolated market with `(loanToken, collateralToken, oracle, irm, lltv)`. `irm` must be in the enabled set and `lltv` must be in the enabled set. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Permissionless market creation is usually not a wallet surface. Refuse unless the user explicitly is building a curator workflow.
