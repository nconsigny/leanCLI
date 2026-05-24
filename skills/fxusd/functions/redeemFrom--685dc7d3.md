# redeemFrom

**Signature**: `redeemFrom(address pool,uint256 amountIn,address receiver,uint256 minOut)`

**Selector**: `0x685dc7d3`

**Mutability**: nonpayable

**Contract**: `FxUSD` (fx Protocol)

## Inputs
- `pool` (`address`): TODO(curator): describe
- `amountIn` (`uint256`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe
- `minOut` (`uint256`): TODO(curator): describe

## Outputs
- `amountOut` (`uint256`): TODO(curator): describe
- `bonusOut` (`uint256`): TODO(curator): describe

## What it does

Redeem fxUSD but pulling from a Rebalance Pool. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Redemption charges a per-market fee. Surface the fee from `MarketV2.fTokenRedemptionFeeRatio()` / `MarketV2.xTokenRedemptionFeeRatio()` before signing.
