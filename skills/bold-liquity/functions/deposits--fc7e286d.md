# deposits

**Signature**: `deposits(address _depositor)`

**Selector**: `0xfc7e286d`

**Mutability**: view

**Contract**: `StabilityPool` (Liquity V2 / BOLD)

## Inputs
- `_depositor` (`address`): TODO(curator): describe

## Outputs
- `initialValue` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
