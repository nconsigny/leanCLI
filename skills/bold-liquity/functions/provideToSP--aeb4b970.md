# provideToSP

**Signature**: `provideToSP(uint256 _amount,bool _doClaim)`

**Selector**: `0xaeb4b970`

**Mutability**: nonpayable

**Contract**: `StabilityPool` (Liquity V2 / BOLD)

## Inputs
- `_amount` (`uint256`): TODO(curator): describe
- `_doClaim` (`bool`): TODO(curator): describe

## Outputs
- (none)

## What it does

Deposit BOLD into a branch's Stability Pool. Earns liquidation gains in collateral. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Stability Pool deposits earn liquidation gains but expose principal to liquidation losses if the SP must cover a Trove. Surface the current SP utilization.
