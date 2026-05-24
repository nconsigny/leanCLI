# getLatestBatchData

**Signature**: `getLatestBatchData(address _batchAddress)`

**Selector**: `0x613cacae`

**Mutability**: view

**Contract**: `TroveManager` (Liquity V2 / BOLD)

## Inputs
- `_batchAddress` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`LatestBatchData`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
