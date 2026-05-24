# getReserveAddressById

**Signature**: `getReserveAddressById(uint16 id)`

**Selector**: `0x52751797`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- `id` (`uint16`): TODO(curator): describe

## Outputs
- `(unnamed)` (`address`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read pool / reserve / user state via `chain_read`. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / health-factor implication.
