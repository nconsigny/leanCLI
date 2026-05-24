# Troves

**Signature**: `Troves(uint256 _id)`

**Selector**: `0xa411219c`

**Mutability**: view

**Contract**: `TroveManager` (Liquity V2 / BOLD)

## Inputs
- `_id` (`uint256`): TODO(curator): describe

## Outputs
- `debt` (`uint256`): TODO(curator): describe
- `coll` (`uint256`): TODO(curator): describe
- `stake` (`uint256`): TODO(curator): describe
- `status` (`Status`): TODO(curator): describe
- `arrayIndex` (`uint64`): TODO(curator): describe
- `lastDebtUpdateTime` (`uint64`): TODO(curator): describe
- `lastInterestRateAdjTime` (`uint64`): TODO(curator): describe
- `annualInterestRate` (`uint256`): TODO(curator): describe
- `interestBatchManager` (`address`): TODO(curator): describe
- `batchDebtShares` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
