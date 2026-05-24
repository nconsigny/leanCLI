# withdraw

**Signature**: `withdraw(address asset,uint256 amount,address to)`

**Selector**: `0x69328dec`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `to` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Burn aTokens and return `amount` of underlying `asset` to `to`. `type(uint256).max` means withdraw the full balance. Fails if it would push the user's health factor below 1. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Always re-read `getUserAccountData(user)` after building the calldata and surface the resulting **health factor** to the user before signing. Refuse if hf would drop below 1.05.
