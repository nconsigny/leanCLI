# mintXToken

**Signature**: `mintXToken(uint256 baseIn,address recipient)`

**Selector**: `0xcd8bf874`

**Mutability**: nonpayable

**Contract**: `FxTreasuryV2` (fx Protocol)

## Inputs
- `baseIn` (`uint256`): TODO(curator): describe
- `recipient` (`address`): TODO(curator): describe

## Outputs
- `xTokenOut` (`uint256`): TODO(curator): describe

## What it does

Deposit `_baseIn` of base token; receive `_xTokenOut` of xToken (the levered leg). Implicit leverage = 2× to 3× depending on collateral ratio. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Pre-sign: read the market's current collateral ratio (`MarketV2.collateralRatio()` or via `TreasuryV2.collateralRatio()`). Surface whether the market is in stability mode (cannot mint xToken) and refuse if the user is trying to mint into a market in shutdown.
