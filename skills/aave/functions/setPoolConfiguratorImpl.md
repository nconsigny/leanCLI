# setPoolConfiguratorImpl

**Signature**: `setPoolConfiguratorImpl(address newPoolConfiguratorImpl)`

**Selector**: `0xe4ca28b7`

**Mutability**: nonpayable

**Contract**: `PoolAddressesProvider` (Aave V3)

## Inputs
- `newPoolConfiguratorImpl` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / governance function — not a user surface. See <https://aave.com/docs/developers/smart-contracts/pool-addresses-provider>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
