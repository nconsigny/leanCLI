# withdrawCollateral

**Signature**: `withdrawCollateral((address loanToken,address collateralToken,address oracle,address irm,uint256 lltv) marketParams,uint256 assets,address onBehalf,address receiver)`

**Selector**: `0x8720316d`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `marketParams` (`(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)`): TODO(curator): describe
- `assets` (`uint256`): TODO(curator): describe
- `onBehalf` (`address`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Withdraw `assets` of collateral. Fails if it would push the position below LLTV. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Pre-sign: re-read `position(id, user)` and `market(id)` to compute the **post-action LLTV health**. Refuse if the position would drop below 1.05x LLTV. The market `id` is `keccak256(abi.encode(marketParams))`.
