# setConfiguration

**Signature**: `setConfiguration(address asset,(uint256 data) configuration)`

**Selector**: `0xf51e435b`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `configuration` (`(uint256 data)`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
