# feeRecipient

**Signature**: `feeRecipient()`

**Selector**: `0x46904840`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`address`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
