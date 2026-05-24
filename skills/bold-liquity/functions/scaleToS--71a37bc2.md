# scaleToS

**Signature**: `scaleToS(uint256 _scale)`

**Selector**: `0x71a37bc2`

**Mutability**: view

**Contract**: `StabilityPool` (Liquity V2 / BOLD)

## Inputs
- `_scale` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
