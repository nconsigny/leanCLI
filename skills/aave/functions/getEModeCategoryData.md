# getEModeCategoryData

**Signature**: `getEModeCategoryData(uint8 id)`

**Selector**: `0x6c6f6ae1`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- `id` (`uint8`): TODO(curator): describe

## Outputs
- `(unnamed)` (`(uint16 ltv,uint16 liquidationThreshold,uint16 liquidationBonus,address priceSource,string label)`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read pool / reserve / user state via `chain_read`. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / health-factor implication.
