# withdrawBold

**Signature**: `withdrawBold(uint256 _troveId,uint256 _amount,uint256 _maxUpfrontFee)`

**Selector**: `0x90de348a`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_amount` (`uint256`): TODO(curator): describe
- `_maxUpfrontFee` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Mint additional BOLD debt against an existing Trove. `_maxUpfrontFee` caps the borrowing fee at submission time. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Pre-sign: read `TroveManager.getCurrentICR(troveId, price)` after building calldata and refuse if the post-action ICR would drop below 1.10× MCR. The MCR is 110% for ETH/WSTETH branches and may differ for RETH; resolve via `BorrowerOperations.MCR()`.
