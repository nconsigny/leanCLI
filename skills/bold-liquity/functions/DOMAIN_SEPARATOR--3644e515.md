# DOMAIN_SEPARATOR

**Signature**: `DOMAIN_SEPARATOR()`

**Selector**: `0x3644e515`

**Mutability**: view

**Contract**: `BoldToken` (Liquity V2 / BOLD)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`bytes32`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
