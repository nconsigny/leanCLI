# ADDRESSES_PROVIDER

**Signature**: `ADDRESSES_PROVIDER()`

**Selector**: `0x0542975c`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`address`): TODO(curator): describe

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
