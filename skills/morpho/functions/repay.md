# repay

**Signature**: `repay((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams,uint256 assets,uint256 shares,address onBehalf,bytes data)`

**Selector**: `0x20b76e81`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe
- `assets` (`uint256`): TODO(curator): describe
- `shares` (`uint256`): TODO(curator): describe
- `onBehalf` (`address`): TODO(curator): describe
- `data` (`bytes`): TODO(curator): describe

## Outputs
- `assetsRepaid` (`uint256`): TODO(curator): describe
- `sharesRepaid` (`uint256`): TODO(curator): describe

## What it does

Repay `assets` or `shares` of borrow. Optional `data` triggers `IMorphoCallback.onMorphoRepay`. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Pre-sign: re-read `position(id, user)` and `market(id)` to compute the **post-action LLTV health**. Refuse if the position would drop below 1.05x LLTV. The market `id` is `keccak256(abi.encode(marketParams))`.
