# updateFlashloanPremiums

**Signature**: `updateFlashloanPremiums(uint128 flashLoanPremiumTotal,uint128 flashLoanPremiumToProtocol)`

**Selector**: `0xbcb6e522`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `flashLoanPremiumTotal` (`uint128`): TODO(curator): describe
- `flashLoanPremiumToProtocol` (`uint128`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
