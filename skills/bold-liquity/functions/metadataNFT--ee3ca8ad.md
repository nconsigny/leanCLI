# metadataNFT

**Signature**: `metadataNFT()`

**Selector**: `0xee3ca8ad`

**Mutability**: view

**Contract**: `AddressesRegistry` (Liquity V2 / BOLD)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`IMetadataNFT`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
