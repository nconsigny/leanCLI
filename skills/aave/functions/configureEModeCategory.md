# configureEModeCategory

**Signature**: `configureEModeCategory(uint8 id,(uint16 ltv,uint16 liquidationThreshold,uint16 liquidationBonus,address priceSource,string label) category)`

**Selector**: `0xd579ea7d`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `id` (`uint8`): TODO(curator): describe
- `category` (`(uint16 ltv,uint16 liquidationThreshold,uint16 liquidationBonus,address priceSource,string label)`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
