# setUserUseReserveAsCollateral

**Signature**: `setUserUseReserveAsCollateral(address asset,bool useAsCollateral)`

**Selector**: `0x5a3b74b9`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `useAsCollateral` (`bool`): TODO(curator): describe

## Outputs
- (none)

## What it does

Toggle whether the caller's deposit of `asset` counts as collateral for borrowing. Toggling off cannot push health factor below 1. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Toggling collateral can cascade into a borrow position becoming undercollateralised. Always verify health factor via `getUserAccountData` before submitting.
