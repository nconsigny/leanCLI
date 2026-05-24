# borrow

**Signature**: `borrow(address asset,uint256 amount,uint256 interestRateMode,uint16 referralCode,address onBehalfOf)`

**Selector**: `0xa415bcad`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `interestRateMode` (`uint256`): TODO(curator): describe
- `referralCode` (`uint16`): TODO(curator): describe
- `onBehalfOf` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Borrow `amount` of `asset` against the caller's collateral. `interestRateMode = 2` means variable rate (the only mode supported in V3 since the stable-rate kill switch). See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Always re-read `getUserAccountData(user)` after building the calldata and surface the resulting **health factor** to the user before signing. Refuse if hf would drop below 1.05.
