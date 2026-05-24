# autoRedeem

**Signature**: `autoRedeem(uint256 amountIn,address receiver,uint256[] minOuts)`

**Selector**: `0x16c40335`

**Mutability**: nonpayable

**Contract**: `FxUSD` (fx Protocol)

## Inputs
- `amountIn` (`uint256`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe
- `minOuts` (`uint256[]`): TODO(curator): describe

## Outputs
- `baseTokens` (`address[]`): TODO(curator): describe
- `amountOuts` (`uint256[]`): TODO(curator): describe
- `bonusOuts` (`uint256[]`): TODO(curator): describe

## What it does

Burn `amount` of fxUSD; protocol selects redemption ordering across `markets` automatically. The wallet should surface the chosen markets before signing. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Redemption charges a per-market fee. Surface the fee from `MarketV2.fTokenRedemptionFeeRatio()` / `MarketV2.xTokenRedemptionFeeRatio()` before signing.
