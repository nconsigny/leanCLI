# adjustTrove

**Signature**: `adjustTrove(uint256 _troveId,uint256 _collChange,bool _isCollIncrease,uint256 _debtChange,bool isDebtIncrease,uint256 _maxUpfrontFee)`

**Selector**: `0x84e5253c`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_collChange` (`uint256`): TODO(curator): describe
- `_isCollIncrease` (`bool`): TODO(curator): describe
- `_debtChange` (`uint256`): TODO(curator): describe
- `isDebtIncrease` (`bool`): TODO(curator): describe
- `_maxUpfrontFee` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Single tx that combines deposit/withdraw collateral with mint/repay BOLD. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Pre-sign: read `TroveManager.getCurrentICR(troveId, price)` after building calldata and refuse if the post-action ICR would drop below 1.10× MCR. The MCR is 110% for ETH/WSTETH branches and may differ for RETH; resolve via `BorrowerOperations.MCR()`.
