# supplyCollateral

**Signature**: `supplyCollateral((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams,uint256 assets,address onBehalf,bytes data)`

**Selector**: `0x238d6579`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe
- `assets` (`uint256`): TODO(curator): describe
- `onBehalf` (`address`): TODO(curator): describe
- `data` (`bytes`): TODO(curator): describe

## Outputs
- (none)

## What it does

Supply `assets` of `marketParams.collateralToken` as collateral for `onBehalf`. Collateral does NOT earn yield in Morpho Blue — only `loanToken` supplies do. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Pre-sign: re-read `position(id, user)` and `market(id)` to compute the **post-action LLTV health**. Refuse if the position would drop below 1.05x LLTV. The market `id` is `keccak256(abi.encode(marketParams))`.
