# allowance

**Signature**: `allowance(address owner,address spender)`

**Selector**: `0xdd62ed3e`

**Mutability**: view

**Contract**: `FxUSD` (fx Protocol)

## Inputs
- `owner` (`address`): TODO(curator): describe
- `spender` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read protocol / market / pool state via `chain_read`. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / collateral-ratio implications.
