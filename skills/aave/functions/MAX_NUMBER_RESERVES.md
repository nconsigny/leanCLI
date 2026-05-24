# MAX_NUMBER_RESERVES

**Signature**: `MAX_NUMBER_RESERVES()`

**Selector**: `0xf8119d51`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`uint16`): TODO(curator): describe

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
