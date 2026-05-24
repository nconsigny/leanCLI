# applyPendingDebt

**Signature**: `applyPendingDebt(uint256 _troveId,uint256 _lowerHint,uint256 _upperHint)`

**Selector**: `0xba5f47a6`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_lowerHint` (`uint256`): TODO(curator): describe
- `_upperHint` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / inter-contract helper. Not a user-signed flow — Liquity branches call each other through these. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Inter-contract or admin call gated by AddressesRegistry. Not a user surface.
