# FLASHLOAN_PREMIUM_TOTAL

**Signature**: `FLASHLOAN_PREMIUM_TOTAL()`

**Selector**: `0x074b2e43`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`uint128`): TODO(curator): describe

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
