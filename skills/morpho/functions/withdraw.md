# withdraw

**Signature**: `withdraw((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams,uint256 assets,uint256 shares,address onBehalf,address receiver)`

**Selector**: `0x5c2bea49`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe
- `assets` (`uint256`): TODO(curator): describe
- `shares` (`uint256`): TODO(curator): describe
- `onBehalf` (`address`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe

## Outputs
- `assetsWithdrawn` (`uint256`): TODO(curator): describe
- `sharesWithdrawn` (`uint256`): TODO(curator): describe

## What it does

Burn supply shares and withdraw underlying back to `receiver`. Health check applies if the position has a collateral / borrow leg too. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Pre-sign: re-read `position(id, user)` and `market(id)` to compute the **post-action LLTV health**. Refuse if the position would drop below 1.05x LLTV. The market `id` is `keccak256(abi.encode(marketParams))`.
