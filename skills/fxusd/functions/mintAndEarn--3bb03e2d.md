# mintAndEarn

**Signature**: `mintAndEarn(address pool,uint256 amountIn,address receiver,uint256 minOut)`

**Selector**: `0x3bb03e2d`

**Mutability**: nonpayable

**Contract**: `FxUSD` (fx Protocol)

## Inputs
- `pool` (`address`): TODO(curator): describe
- `amountIn` (`uint256`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe
- `minOut` (`uint256`): TODO(curator): describe

## Outputs
- `amountOut` (`uint256`): TODO(curator): describe

## What it does

Combined mint + earn: deposit `amount` of `baseToken`, get fxUSD, immediately stake it. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Pre-sign: read the market's current collateral ratio (`MarketV2.collateralRatio()` or via `TreasuryV2.collateralRatio()`). Surface whether the market is in stability mode (cannot mint xToken) and refuse if the user is trying to mint into a market in shutdown.
