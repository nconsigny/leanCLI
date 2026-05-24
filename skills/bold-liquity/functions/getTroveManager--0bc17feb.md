# getTroveManager

**Signature**: `getTroveManager(uint256 _index)`

**Selector**: `0x0bc17feb`

**Mutability**: view

**Contract**: `CollateralRegistry` (Liquity V2 / BOLD)

## Inputs
- `_index` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`ITroveManager`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
