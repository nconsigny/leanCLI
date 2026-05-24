# isLltvEnabled

**Signature**: `isLltvEnabled(uint256 lltv)`

**Selector**: `0xb485f3b8`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `lltv` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`bool`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
