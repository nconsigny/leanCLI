# liquidationCall

**Signature**: `liquidationCall(address collateralAsset,address debtAsset,address user,uint256 debtToCover,bool receiveAToken)`

**Selector**: `0x00a718a9`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `collateralAsset` (`address`): TODO(curator): describe
- `debtAsset` (`address`): TODO(curator): describe
- `user` (`address`): TODO(curator): describe
- `debtToCover` (`uint256`): TODO(curator): describe
- `receiveAToken` (`bool`): TODO(curator): describe

## Outputs
- (none)

## What it does

Liquidate `user`'s unhealthy position. Caller repays `debtToCover` of `debtAsset` and receives the equivalent `collateralAsset` (plus liquidation bonus). The wallet should never originate this from a retail flow. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Liquidation is keeper-side; the wallet should not surface it to a retail user without an explicit advanced-flow flag.
