# idToMarketParams

**Signature**: `idToMarketParams(bytes32 id)`

**Selector**: `0x2c3c9157`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `id` (`bytes32`): TODO(curator): describe

## Outputs
- `(unnamed)` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
