# adjustZombieTrove

**Signature**: `adjustZombieTrove(uint256 _troveId,uint256 _collChange,bool _isCollIncrease,uint256 _boldChange,bool _isDebtIncrease,uint256 _upperHint,uint256 _lowerHint,uint256 _maxUpfrontFee)`

**Selector**: `0xdcfbd293`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_troveId` (`uint256`): TODO(curator): describe
- `_collChange` (`uint256`): TODO(curator): describe
- `_isCollIncrease` (`bool`): TODO(curator): describe
- `_boldChange` (`uint256`): TODO(curator): describe
- `_isDebtIncrease` (`bool`): TODO(curator): describe
- `_upperHint` (`uint256`): TODO(curator): describe
- `_lowerHint` (`uint256`): TODO(curator): describe
- `_maxUpfrontFee` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

TODO(curator): operational semantics for `BorrowerOperations.adjustZombieTrove` — see <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Pre-sign: read `TroveManager.getCurrentICR(troveId, price)` after building calldata and refuse if the post-action ICR would drop below 1.10× MCR. The MCR is 110% for ETH/WSTETH branches and may differ for RETH; resolve via `BorrowerOperations.MCR()`.
