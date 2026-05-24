# setPoolImpl

**Signature**: `setPoolImpl(address newPoolImpl)`

**Selector**: `0xa1564406`

**Mutability**: nonpayable

**Contract**: `PoolAddressesProvider` (Aave V3)

## Inputs
- `newPoolImpl` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / governance function — not a user surface. See <https://aave.com/docs/developers/smart-contracts/pool-addresses-provider>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
