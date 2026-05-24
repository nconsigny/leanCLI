# borrowerOperationsAddress

**Signature**: `borrowerOperationsAddress()`

**Selector**: `0xb7f8cf9b`

**Mutability**: view

**Contract**: `ActivePool` (Liquity V2 / BOLD)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`address`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
