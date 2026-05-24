# predictAdjustTroveUpfrontFee

**Signature**: `predictAdjustTroveUpfrontFee(uint256 _collIndex,uint256 _troveId,uint256 _debtIncrease)`

**Selector**: `0x3a0b1dfa`

**Mutability**: view

**Contract**: `HintHelpers` (Liquity V2 / BOLD)

## Inputs
- `_collIndex` (`uint256`): TODO(curator): describe
- `_troveId` (`uint256`): TODO(curator): describe
- `_debtIncrease` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
