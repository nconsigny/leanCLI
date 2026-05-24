# getReserveData

**Signature**: `getReserveData(address asset)`

**Selector**: `0x35ea6a75`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`((uint256 data) configuration,uint128 liquidityIndex,uint128 currentLiquidityRate,uint128 variableBorrowIndex,uint128 currentVariableBorrowRate,uint128 currentStableBorrowRate,uint40 lastUpdateTimestamp,uint16 id,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address interestRateStrategyAddress,uint128 accruedToTreasury,uint128 unbacked,uint128 isolationModeTotalDebt)`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read pool / reserve / user state via `chain_read`. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / health-factor implication.
