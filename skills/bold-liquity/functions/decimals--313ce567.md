# decimals

**Signature**: `decimals()`

**Selector**: `0x313ce567`

**Mutability**: view

**Contract**: `BoldToken` (Liquity V2 / BOLD)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`uint8`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
