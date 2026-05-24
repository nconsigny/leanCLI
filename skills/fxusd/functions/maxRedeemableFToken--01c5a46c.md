# maxRedeemableFToken

**Signature**: `maxRedeemableFToken(uint256 newCollateralRatio)`

**Selector**: `0x01c5a46c`

**Mutability**: view

**Contract**: `FxTreasuryV2` (fx Protocol)

## Inputs
- `newCollateralRatio` (`uint256`): TODO(curator): describe

## Outputs
- `maxBaseOut` (`uint256`): TODO(curator): describe
- `maxFTokenRedeemable` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read protocol / market / pool state via `chain_read`. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / collateral-ratio implications.
