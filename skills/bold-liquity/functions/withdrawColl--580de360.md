# withdrawColl

**Signature**: `withdrawColl(uint256 _troveId,uint256 _amount)`

**Selector**: `0x580de360`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_amount` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Withdraw `_amount` of collateral from a Trove. Fails if it would push CR below MCR. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Pre-sign: read `TroveManager.getCurrentICR(troveId, price)` after building calldata and refuse if the post-action ICR would drop below 1.10× MCR. The MCR is 110% for ETH/WSTETH branches and may differ for RETH; resolve via `BorrowerOperations.MCR()`.
