# setInterestBatchManager

**Signature**: `setInterestBatchManager(uint256 _troveId,address _newBatchManager,uint256 _upperHint,uint256 _lowerHint,uint256 _maxUpfrontFee)`

**Selector**: `0x9537f001`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_newBatchManager` (`address`): TODO(curator): describe
- `_upperHint` (`uint256`): TODO(curator): describe
- `_lowerHint` (`uint256`): TODO(curator): describe
- `_maxUpfrontFee` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Join an interest-batch manager. The batch manager sets the rate for all participants. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
