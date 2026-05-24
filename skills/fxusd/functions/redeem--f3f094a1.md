# redeem

**Signature**: `redeem(address baseToken,uint256 amountIn,address receiver,uint256 minOut)`

**Selector**: `0xf3f094a1`

**Mutability**: nonpayable

**Contract**: `FxUSD` (fx Protocol)

## Inputs
- `baseToken` (`address`): TODO(curator): describe
- `amountIn` (`uint256`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe
- `minOut` (`uint256`): TODO(curator): describe

## Outputs
- `amountOut` (`uint256`): TODO(curator): describe
- `bonusOut` (`uint256`): TODO(curator): describe

## What it does

Burn `amount` of fxUSD; receive `baseToken` from the market. `minOut` caps slippage. May incur a redemption fee. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Redemption charges a per-market fee. Surface the fee from `MarketV2.fTokenRedemptionFeeRatio()` / `MarketV2.xTokenRedemptionFeeRatio()` before signing.
