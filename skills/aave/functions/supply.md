# supply

**Signature**: `supply(address asset,uint256 amount,address onBehalfOf,uint16 referralCode)`

**Selector**: `0x617ba037`

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

Supply `amount` of `asset` to the pool. Mints aTokens to `onBehalfOf` and accrues interest. The user gets to choose whether the supplied asset can be used as collateral (subsequent call to `setUserUseReserveAsCollateral`). See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Always re-read `getUserAccountData(user)` after building the calldata and surface the resulting **health factor** to the user before signing. Refuse if hf would drop below 1.05.
