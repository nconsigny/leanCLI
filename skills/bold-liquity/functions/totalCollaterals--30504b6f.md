# totalCollaterals

**Signature**: `totalCollaterals()`

**Selector**: `0x30504b6f`

**Mutability**: view

**Contract**: `CollateralRegistry` (Liquity V2 / BOLD)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
