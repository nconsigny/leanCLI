# redeemXToken

**Signature**: `redeemXToken(uint256 xTokenIn,address recipient,uint256 minBaseOut)`

**Selector**: `0x72b790db`

**Mutability**: nonpayable

**Contract**: `FxMarketV2` (fx Protocol)

## Inputs
- `xTokenIn` (`uint256`): TODO(curator): describe
- `recipient` (`address`): TODO(curator): describe
- `minBaseOut` (`uint256`): TODO(curator): describe

## Outputs
- `baseOut` (`uint256`): TODO(curator): describe

## What it does

Burn `_xTokenIn` of xToken; receive base token. May suffer if collateral ratio is unhealthy. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Redemption charges a per-market fee. Surface the fee from `MarketV2.fTokenRedemptionFeeRatio()` / `MarketV2.xTokenRedemptionFeeRatio()` before signing.
