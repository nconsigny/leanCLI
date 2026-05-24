# interestBatchManagerOf

**Signature**: `interestBatchManagerOf(uint256 _troveId)`

**Selector**: `0xa0df5cd5`

**Mutability**: view

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`address`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
