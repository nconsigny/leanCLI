# supply

**Signature**: `supply((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams,uint256 assets,uint256 shares,address onBehalf,bytes data)`

**Selector**: `0xa99aad89`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe
- `assets` (`uint256`): TODO(curator): describe
- `shares` (`uint256`): TODO(curator): describe
- `onBehalf` (`address`): TODO(curator): describe
- `data` (`bytes`): TODO(curator): describe

## Outputs
- `assetsSupplied` (`uint256`): TODO(curator): describe
- `sharesSupplied` (`uint256`): TODO(curator): describe

## What it does

Supply `assets` or `shares` of `marketParams.loanToken` to the market on behalf of `onBehalf`. Either `assets` or `shares` must be zero. Optional `data` triggers `IMorphoCallback.onMorphoSupply`. The supplier accrues yield from borrowers' interest. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Pre-sign: re-read `position(id, user)` and `market(id)` to compute the **post-action LLTV health**. Refuse if the position would drop below 1.05x LLTV. The market `id` is `keccak256(abi.encode(marketParams))`.
