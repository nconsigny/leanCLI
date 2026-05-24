# market

**Signature**: `market(bytes32 id)`

**Selector**: `0x5c60e39a`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `id` (`bytes32`): TODO(curator): describe

## Outputs
- `m` (`(uint128 totalSupplyAssets,uint128 totalSupplyShares,uint128 totalBorrowAssets,uint128 totalBorrowShares,uint128 lastUpdate,uint128 fee)`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
