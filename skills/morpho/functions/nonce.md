# nonce

**Signature**: `nonce(address authorizer)`

**Selector**: `0x70ae92d2`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `authorizer` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
