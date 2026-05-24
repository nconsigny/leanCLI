# mint

**Signature**: `mint(address baseToken,uint256 amountIn,address receiver,uint256 minOut)`

**Selector**: `0x3c173a4f`

**Mutability**: nonpayable

**Contract**: `FxUSD` (fx Protocol)

## Inputs
- `baseToken` (`address`): TODO(curator): describe
- `amountIn` (`uint256`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe
- `minOut` (`uint256`): TODO(curator): describe

## Outputs
- `amountOut` (`uint256`): TODO(curator): describe

## What it does

Mint fTokens AND fxUSD in one step: deposit `amount` of `baseToken` into the market and receive fxUSD. `minOut` caps slippage. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Pre-sign: read the market's current collateral ratio (`MarketV2.collateralRatio()` or via `TreasuryV2.collateralRatio()`). Surface whether the market is in stability mode (cannot mint xToken) and refuse if the user is trying to mint into a market in shutdown.
