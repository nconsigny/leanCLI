# adjustTroveInterestRate

**Signature**: `adjustTroveInterestRate(uint256 _troveId,uint256 _newAnnualInterestRate,uint256 _upperHint,uint256 _lowerHint,uint256 _maxUpfrontFee)`

**Selector**: `0x26f4e252`

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

Change a Trove's annual interest rate. May incur an upfront fee depending on time since last adjustment. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
