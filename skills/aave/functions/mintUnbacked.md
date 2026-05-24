# mintUnbacked

**Signature**: `mintUnbacked(address asset,uint256 amount,address onBehalfOf,uint16 referralCode)`

**Selector**: `0x69a933a5`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `onBehalfOf` (`address`): TODO(curator): describe
- `referralCode` (`uint16`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
