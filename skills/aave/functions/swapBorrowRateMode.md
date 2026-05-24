# swapBorrowRateMode

**Signature**: `swapBorrowRateMode(address asset,uint256 interestRateMode)`

**Selector**: `0x94ba89a2`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `interestRateMode` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

TODO(curator): operational semantics for `Pool.swapBorrowRateMode` — see <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

V3 stable-rate mode is killed. The wallet should refuse to surface this; it is a no-op or revert in current V3.
