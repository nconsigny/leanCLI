# allowance

**Signature**: `allowance(address owner,address spender)`

**Selector**: `0xdd62ed3e`

**Mutability**: view

**Contract**: `BoldToken` (Liquity V2 / BOLD)

## Inputs
- `owner` (`address`): TODO(curator): describe
- `spender` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
