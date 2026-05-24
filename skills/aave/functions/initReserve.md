# initReserve

**Signature**: `initReserve(address asset,address aTokenAddress,address stableDebtAddress,address variableDebtAddress,address interestRateStrategyAddress)`

**Selector**: `0x7a708e92`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `aTokenAddress` (`address`): TODO(curator): describe
- `stableDebtAddress` (`address`): TODO(curator): describe
- `variableDebtAddress` (`address`): TODO(curator): describe
- `interestRateStrategyAddress` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
