# closeTrove

**Signature**: `closeTrove(uint256 _troveId)`

**Selector**: `0x5aa6d461`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Close a Trove. Requires repaying the full debt and burning the TroveNFT. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

ICR-improving / debt-reducing operations are safe by construction but the wallet should still surface the resulting ICR.
