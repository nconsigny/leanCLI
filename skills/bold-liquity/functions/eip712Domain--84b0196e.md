# eip712Domain

**Signature**: `eip712Domain()`

**Selector**: `0x84b0196e`

**Mutability**: view

**Contract**: `BoldToken` (Liquity V2 / BOLD)

## Inputs
- (none)

## Outputs
- `fields` (`bytes1`): TODO(curator): describe
- `name` (`string`): TODO(curator): describe
- `version` (`string`): TODO(curator): describe
- `chainId` (`uint256`): TODO(curator): describe
- `verifyingContract` (`address`): TODO(curator): describe
- `salt` (`bytes32`): TODO(curator): describe
- `extensions` (`uint256[]`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
