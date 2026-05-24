# setUserEMode

**Signature**: `setUserEMode(uint8 categoryId)`

**Selector**: `0x28530a47`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `categoryId` (`uint8`): TODO(curator): describe

## Outputs
- (none)

## What it does

Enter / exit an 'eMode' category (e.g. ETH-correlated, stablecoin) which loosens LTV between assets in the same correlation bucket. Changing eMode while having open borrows is restricted by health-factor checks. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Always re-read `getUserAccountData(user)` after building the calldata and surface the resulting **health factor** to the user before signing. Refuse if hf would drop below 1.05.
