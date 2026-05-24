# getRedemptionRateForRedeemedAmount

**Signature**: `getRedemptionRateForRedeemedAmount(uint256 _redeemAmount)`

**Selector**: `0x63f1134e`

**Mutability**: view

**Contract**: `CollateralRegistry` (Liquity V2 / BOLD)

## Inputs
- `_redeemAmount` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
