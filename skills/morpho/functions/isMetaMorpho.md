# isMetaMorpho

**Signature**: `isMetaMorpho(address target)`

**Selector**: `0x29b5352c`

**Mutability**: view

**Contract**: `MetaMorphoFactory` (Morpho)

## Inputs
- `target` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`bool`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/curation/concepts/metamorpho>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
