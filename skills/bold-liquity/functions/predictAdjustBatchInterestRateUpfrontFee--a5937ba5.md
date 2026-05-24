# predictAdjustBatchInterestRateUpfrontFee

**Signature**: `predictAdjustBatchInterestRateUpfrontFee(uint256 _collIndex,address _batchAddress,uint256 _newInterestRate)`

**Selector**: `0xa5937ba5`

**Mutability**: view

**Contract**: `HintHelpers` (Liquity V2 / BOLD)

## Inputs
- `_collIndex` (`uint256`): TODO(curator): describe
- `_batchAddress` (`address`): TODO(curator): describe
- `_newInterestRate` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
