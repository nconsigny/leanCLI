# removeFromBatch

**Signature**: `removeFromBatch(uint256 _troveId,uint256 _newAnnualInterestRate,uint256 _upperHint,uint256 _lowerHint,uint256 _maxUpfrontFee)`

**Selector**: `0xf9ef19ca`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_newAnnualInterestRate` (`uint256`): TODO(curator): describe
- `_upperHint` (`uint256`): TODO(curator): describe
- `_lowerHint` (`uint256`): TODO(curator): describe
- `_maxUpfrontFee` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Leave an interest-batch manager. Returns the Trove to individual rate management. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
