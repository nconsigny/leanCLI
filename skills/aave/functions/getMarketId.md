# getMarketId

**Signature**: `getMarketId()`

**Selector**: `0x568ef470`

**Mutability**: view

**Contract**: `PoolAddressesProvider` (Aave V3)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`string`): TODO(curator): describe

## What it does

View accessor. Returns the address of the named component. Used during pre-sign to resolve the live Pool / Oracle / ACL addresses without hard-coding. See <https://aave.com/docs/developers/smart-contracts/pool-addresses-provider>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / health-factor implication.
