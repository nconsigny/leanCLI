# redeemFToken

**Signature**: `redeemFToken(uint256 fTokenIn,address recipient,uint256 minBaseOut)`

**Selector**: `0xd0ce98fa`

**Mutability**: nonpayable

**Contract**: `FxMarketV2` (fx Protocol)

## Inputs
- `fTokenIn` (`uint256`): TODO(curator): describe
- `recipient` (`address`): TODO(curator): describe
- `minBaseOut` (`uint256`): TODO(curator): describe

## Outputs
- `baseOut` (`uint256`): TODO(curator): describe
- `bonus` (`uint256`): TODO(curator): describe

## What it does

Burn `_fTokenIn` of fToken; receive base token. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Redemption charges a per-market fee. Surface the fee from `MarketV2.fTokenRedemptionFeeRatio()` / `MarketV2.xTokenRedemptionFeeRatio()` before signing.
