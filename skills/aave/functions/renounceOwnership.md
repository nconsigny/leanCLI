# renounceOwnership

**Signature**: `renounceOwnership()`

**Selector**: `0x715018a6`

**Mutability**: nonpayable

**Contract**: `PoolAddressesProvider` (Aave V3)

## Inputs
- (none)

## Outputs
- (none)

## What it does

Admin / governance function — not a user surface. See <https://aave.com/docs/developers/smart-contracts/pool-addresses-provider>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
