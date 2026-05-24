# setInterestIndividualDelegate

**Signature**: `setInterestIndividualDelegate(uint256 _troveId,address _delegate,uint128 _minInterestRate,uint128 _maxInterestRate,uint256 _newAnnualInterestRate,uint256 _upperHint,uint256 _lowerHint,uint256 _maxUpfrontFee,uint256 _minInterestRateChangePeriod)`

**Selector**: `0xc6ac2465`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_delegate` (`address`): TODO(curator): describe
- `_minInterestRate` (`uint128`): TODO(curator): describe
- `_maxInterestRate` (`uint128`): TODO(curator): describe
- `_newAnnualInterestRate` (`uint256`): TODO(curator): describe
- `_upperHint` (`uint256`): TODO(curator): describe
- `_lowerHint` (`uint256`): TODO(curator): describe
- `_maxUpfrontFee` (`uint256`): TODO(curator): describe
- `_minInterestRateChangePeriod` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Delegate per-Trove interest-rate management to a third party. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
