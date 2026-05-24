# accrueInterest

**Signature**: `accrueInterest((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams)`

**Selector**: `0x151c1ade`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe

## Outputs
- (none)

## What it does

Manually accrue interest on a market. Anyone can call; idempotent within a block. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
