# mintFToken

**Signature**: `mintFToken(uint256 baseIn,address recipient,uint256 minFTokenMinted)`

**Selector**: `0x64c9b4c3`

**Mutability**: nonpayable

**Contract**: `FxMarketV2` (fx Protocol)

## Inputs
- `baseIn` (`uint256`): TODO(curator): describe
- `recipient` (`address`): TODO(curator): describe
- `minFTokenMinted` (`uint256`): TODO(curator): describe

## Outputs
- `fTokenMinted` (`uint256`): TODO(curator): describe

## What it does

Deposit `_baseIn` of base token; receive `_fTokenOut` of fToken (the stable leg). The user takes on no leverage. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Pre-sign: read the market's current collateral ratio (`MarketV2.collateralRatio()` or via `TreasuryV2.collateralRatio()`). Surface whether the market is in stability mode (cannot mint xToken) and refuse if the user is trying to mint into a market in shutdown.
