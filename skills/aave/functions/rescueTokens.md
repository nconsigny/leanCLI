# rescueTokens

**Signature**: `rescueTokens(address token,address to,uint256 amount)`

**Selector**: `0xcea9d26f`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `token` (`address`): TODO(curator): describe
- `to` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
