# withdrawFromSP

**Signature**: `withdrawFromSP(uint256 _amount,bool doClaim)`

**Selector**: `0xcfddf5f5`

**Mutability**: nonpayable

**Contract**: `StabilityPool` (Liquity V2 / BOLD)

## Inputs
- `_amount` (`uint256`): TODO(curator): describe
- `doClaim` (`bool`): TODO(curator): describe

## Outputs
- (none)

## What it does

Withdraw BOLD from the Stability Pool. Pulls accrued collateral gains too. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Stability Pool deposits earn liquidation gains but expose principal to liquidation losses if the SP must cover a Trove. Surface the current SP utilization.
