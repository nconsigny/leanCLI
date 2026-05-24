# getCompoundedBoldDeposit

**Signature**: `getCompoundedBoldDeposit(address _depositor)`

**Selector**: `0x065f566d`

**Mutability**: view

**Contract**: `StabilityPool` (Liquity V2 / BOLD)

## Inputs
- `_depositor` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
