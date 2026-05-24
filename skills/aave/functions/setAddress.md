# setAddress

**Signature**: `setAddress(bytes32 id,address newAddress)`

**Selector**: `0xca446dd9`

**Mutability**: nonpayable

**Contract**: `PoolAddressesProvider` (Aave V3)

## Inputs
- `id` (`bytes32`): TODO(curator): describe
- `newAddress` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / governance function — not a user surface. See <https://aave.com/docs/developers/smart-contracts/pool-addresses-provider>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
