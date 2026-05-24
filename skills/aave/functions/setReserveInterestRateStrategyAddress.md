# setReserveInterestRateStrategyAddress

**Signature**: `setReserveInterestRateStrategyAddress(address asset,address rateStrategyAddress)`

**Selector**: `0x1d2118f9`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `rateStrategyAddress` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
