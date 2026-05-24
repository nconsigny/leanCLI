# getInterestBatchManager

**Signature**: `getInterestBatchManager(address _account)`

**Selector**: `0x4ed1bd5d`

**Mutability**: view

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_account` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`(uint128 minInterestRate,uint128 maxInterestRate,uint256 minInterestRateChangePeriod)`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
