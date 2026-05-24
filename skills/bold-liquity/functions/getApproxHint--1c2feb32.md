# getApproxHint

**Signature**: `getApproxHint(uint256 _collIndex,uint256 _interestRate,uint256 _numTrials,uint256 _inputRandomSeed)`

**Selector**: `0x1c2feb32`

**Mutability**: view

**Contract**: `HintHelpers` (Liquity V2 / BOLD)

## Inputs
- `_collIndex` (`uint256`): TODO(curator): describe
- `_interestRate` (`uint256`): TODO(curator): describe
- `_numTrials` (`uint256`): TODO(curator): describe
- `_inputRandomSeed` (`uint256`): TODO(curator): describe

## Outputs
- `hintId` (`uint256`): TODO(curator): describe
- `diff` (`uint256`): TODO(curator): describe
- `latestRandomSeed` (`uint256`): TODO(curator): describe

## What it does

Off-chain helper to compute `_upperHint`/`_lowerHint` for sorted-list insertion. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
