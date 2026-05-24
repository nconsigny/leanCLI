# FLASHLOAN_PREMIUM_TO_PROTOCOL

**Signature**: `FLASHLOAN_PREMIUM_TO_PROTOCOL()`

**Selector**: `0x6a99c036`

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
