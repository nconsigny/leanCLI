# repayWithATokens

**Signature**: `repayWithATokens(address asset,uint256 amount,uint256 interestRateMode)`

**Selector**: `0x2dad97d4`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `interestRateMode` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Repay debt using the caller's aTokens directly (burn aToken instead of transferring underlying). See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Always re-read `getUserAccountData(user)` after building the calldata and surface the resulting **health factor** to the user before signing. Refuse if hf would drop below 1.05.
