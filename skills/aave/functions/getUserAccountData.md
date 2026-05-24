# getUserAccountData

**Signature**: `getUserAccountData(address user)`

**Selector**: `0xbf92857c`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- `user` (`address`): TODO(curator): describe

## Outputs
- `totalCollateralBase` (`uint256`): TODO(curator): describe
- `totalDebtBase` (`uint256`): TODO(curator): describe
- `availableBorrowsBase` (`uint256`): TODO(curator): describe
- `currentLiquidationThreshold` (`uint256`): TODO(curator): describe
- `ltv` (`uint256`): TODO(curator): describe
- `healthFactor` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read pool / reserve / user state via `chain_read`. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / health-factor implication.
