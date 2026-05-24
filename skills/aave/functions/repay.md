# repay

**Signature**: `repay(address asset,uint256 amount,uint256 interestRateMode,address onBehalfOf)`

**Selector**: `0x573ade81`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `interestRateMode` (`uint256`): TODO(curator): describe
- `onBehalfOf` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Repay `amount` of `asset` debt for `onBehalfOf`. `type(uint256).max` means repay full debt. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Always re-read `getUserAccountData(user)` after building the calldata and surface the resulting **health factor** to the user before signing. Refuse if hf would drop below 1.05.
