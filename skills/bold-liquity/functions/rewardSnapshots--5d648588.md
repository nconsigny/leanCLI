# rewardSnapshots

**Signature**: `rewardSnapshots(uint256 _id)`

**Selector**: `0x5d648588`

**Mutability**: view

**Contract**: `TroveManager` (Liquity V2 / BOLD)

## Inputs
- `_id` (`uint256`): TODO(curator): describe

## Outputs
- `coll` (`uint256`): TODO(curator): describe
- `boldDebt` (`uint256`): TODO(curator): describe

## What it does

View accessor. Used during pre-sign to read Trove / pool / oracle state via `chain_read`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
