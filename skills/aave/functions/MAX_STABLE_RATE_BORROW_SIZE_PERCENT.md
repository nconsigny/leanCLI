# MAX_STABLE_RATE_BORROW_SIZE_PERCENT

**Signature**: `MAX_STABLE_RATE_BORROW_SIZE_PERCENT()`

**Selector**: `0xe82fec2f`

**Mutability**: view

**Contract**: `Pool` (Aave V3)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
