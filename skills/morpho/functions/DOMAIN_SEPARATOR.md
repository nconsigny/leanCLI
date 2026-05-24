# DOMAIN_SEPARATOR

**Signature**: `DOMAIN_SEPARATOR()`

**Selector**: `0x3644e515`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`bytes32`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
