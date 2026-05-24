# isAuthorized

**Signature**: `isAuthorized(address authorizer,address authorized)`

**Selector**: `0x65e4ad9e`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `authorizer` (`address`): TODO(curator): describe
- `authorized` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`bool`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
