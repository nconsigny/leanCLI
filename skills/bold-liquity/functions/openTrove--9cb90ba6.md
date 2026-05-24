# openTrove

**Signature**: `openTrove(address _owner,uint256 _ownerIndex,uint256 _ETHAmount,uint256 _boldAmount,uint256 _upperHint,uint256 _lowerHint,uint256 _annualInterestRate,uint256 _maxUpfrontFee,address _addManager,address _removeManager,address _receiver)`

**Selector**: `0x9cb90ba6`

**Mutability**: nonpayable

**Contract**: `BorrowerOperations` (Liquity V2 / BOLD)

## Inputs
- `_owner` (`address`): TODO(curator): describe
- `_ownerIndex` (`uint256`): TODO(curator): describe
- `_ETHAmount` (`uint256`): TODO(curator): describe
- `_boldAmount` (`uint256`): TODO(curator): describe
- `_upperHint` (`uint256`): TODO(curator): describe
- `_lowerHint` (`uint256`): TODO(curator): describe
- `_annualInterestRate` (`uint256`): TODO(curator): describe
- `_maxUpfrontFee` (`uint256`): TODO(curator): describe
- `_addManager` (`address`): TODO(curator): describe
- `_removeManager` (`address`): TODO(curator): describe
- `_receiver` (`address`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Open a new Trove. Caller deposits ETH-equivalent collateral and mints `_boldAmount` of BOLD. `_annualInterestRate` is the chosen per-Trove rate (Liquity v2's per-Trove interest is a defining feature). `_upperHint`/`_lowerHint` are sorted-list hints for gas efficiency. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Pre-sign: read `TroveManager.getCurrentICR(troveId, price)` after building calldata and refuse if the post-action ICR would drop below 1.10× MCR. The MCR is 110% for ETH/WSTETH branches and may differ for RETH; resolve via `BorrowerOperations.MCR()`.
