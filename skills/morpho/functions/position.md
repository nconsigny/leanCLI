# position

**Signature**: `position(bytes32 id,address user)`

**Selector**: `0x93c52062`

**Mutability**: view

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `id` (`bytes32`): TODO(curator): describe
- `user` (`address`): TODO(curator): describe

## Outputs
- `p` (`(uint256 supplyShares,uint128 borrowShares,uint128 collateral)`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read position / market / configuration state via `chain_read`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
