# redeemCollateral

**Signature**: `redeemCollateral(uint256 _boldamount,uint256 _maxIterations,uint256 _maxFeePercentage)`

**Selector**: `0xab6d53bd`

**Mutability**: nonpayable

**Contract**: `CollateralRegistry` (Liquity V2 / BOLD)

## Inputs
- `_boldamount` (`uint256`): TODO(curator): describe
- `_maxIterations` (`uint256`): TODO(curator): describe
- `_maxFeePercentage` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Burn BOLD and receive collateral from the cheapest Trove in the protocol. Open to anyone; this is the redemption arb path. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Redemption is open to anyone but is the canonical arb path — surface only if the user has explicitly requested a redemption arb.
