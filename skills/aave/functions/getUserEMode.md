# getUserEMode

**Signature**: `getUserEMode(address user)`

**Selector**: `0xeddf1b79`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- `user` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read pool / reserve / user state via `chain_read`. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / health-factor implication.
