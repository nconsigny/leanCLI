# getReservesList

**Signature**: `getReservesList()`

**Selector**: `0xd1946dbc`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`address[]`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read pool / reserve / user state via `chain_read`. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / health-factor implication.
