# updateBridgeProtocolFee

**Signature**: `updateBridgeProtocolFee(uint256 protocolFee)`

**Selector**: `0x3036b439`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `protocolFee` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / view function — not a user-signed flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Admin gate via `PoolAddressesProvider.getACLManager()` — not a user surface.
