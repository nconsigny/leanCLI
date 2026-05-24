# switchBatchManager

**Signature**: `switchBatchManager(uint256 _troveId,uint256 _removeUpperHint,uint256 _removeLowerHint,address _newBatchManager,uint256 _addUpperHint,uint256 _addLowerHint,uint256 _maxUpfrontFee)`

**Selector**: `0xd5479cd4`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_removeUpperHint` (`uint256`): TODO(curator): describe
- `_removeLowerHint` (`uint256`): TODO(curator): describe
- `_newBatchManager` (`address`): TODO(curator): describe
- `_addUpperHint` (`uint256`): TODO(curator): describe
- `_addLowerHint` (`uint256`): TODO(curator): describe
- `_maxUpfrontFee` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

TODO(curator): operational semantics for `BorrowerOperations.switchBatchManager` — see <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
