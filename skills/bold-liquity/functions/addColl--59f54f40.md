# addColl

**Signature**: `addColl(uint256 _troveId,uint256 _ETHAmount)`

**Selector**: `0x59f54f40`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_ETHAmount` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Deposit additional collateral to an existing Trove identified by `_troveId`. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

ICR-improving / debt-reducing operations are safe by construction but the wallet should still surface the resulting ICR.
