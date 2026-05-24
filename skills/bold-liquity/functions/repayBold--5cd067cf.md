# repayBold

**Signature**: `repayBold(uint256 _troveId,uint256 _amount)`

**Selector**: `0x5cd067cf`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_amount` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Burn `_amount` of BOLD to reduce a Trove's debt. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

ICR-improving / debt-reducing operations are safe by construction but the wallet should still surface the resulting ICR.
