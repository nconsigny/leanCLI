# claimCollateral

**Signature**: `claimCollateral()`

**Selector**: `0x6f0b0c1c`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- (none)

## Outputs
- (none)

## What it does

After liquidation / redemption, claim any collateral left to the user in the CollSurplusPool. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

TODO(curator): permission boundary, oracle dependency, hint correctness for sorted-list insertion.
