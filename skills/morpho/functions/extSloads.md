# extSloads

**Signature**: `extSloads(bytes32[] slots)`

**Selector**: `0x7784c685`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `slots` (`bytes32[]`): TODO(curator): describe

## Outputs
- `(unnamed)` (`bytes32[]`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
