# withdraw

**Signature**: `withdraw(address asset,uint256 amount,address to)`

**Selector**: `0x69328dec`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): underlying reserve token to redeem from Aave (for example USDC or WETH).
- `amount` (`uint256`): underlying amount in base units. `type(uint256).max` withdraws the caller's full aToken balance for this reserve.
- `to` (`address`): recipient of the redeemed underlying tokens.

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Burn the caller's aTokens and return `amount` of underlying `asset` to `to`.
`type(uint256).max` means withdraw the full supplied balance for that reserve.
This changes the supplied-collateral side of the user's Aave position; it does
not repay debt and it is not an ERC-20 transfer. Fails if it would push the
user's health factor below 1. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Always re-read `getUserAccountData(user)` after building the calldata and surface the resulting **health factor** to the user before signing. Refuse if hf would drop below 1.05.
