# maxMintableXToken

**Signature**: `maxMintableXToken(uint256 newCollateralRatio)`

**Selector**: `0xe9ea2b25`

**Mutability**: view

**Contract**: `FxTreasuryV2` (fx Protocol)

## Inputs
- `newCollateralRatio` (`uint256`): TODO(curator): describe

## Outputs
- `maxBaseIn` (`uint256`): TODO(curator): describe
- `maxXTokenMintable` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read protocol / market / pool state via `chain_read`. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / collateral-ratio implications.
