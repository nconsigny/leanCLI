# redeemCollateral

**Signature**: `redeemCollateral(address _sender,uint256 _boldAmount,uint256 _price,uint256 _redemptionRate,uint256 _maxIterations)`

**Selector**: `0xf8a239e8`

**Mutability**: nonpayable

**Contract**: `TroveManager` (Liquity V2 / BOLD)

## Inputs
- `_sender` (`address`): TODO(curator): describe
- `_boldAmount` (`uint256`): TODO(curator): describe
- `_price` (`uint256`): TODO(curator): describe
- `_redemptionRate` (`uint256`): TODO(curator): describe
- `_maxIterations` (`uint256`): TODO(curator): describe

## Outputs
- `_redemeedAmount` (`uint256`): TODO(curator): describe

## What it does

Burn BOLD and receive collateral from the cheapest Trove in the protocol. Open to anyone; this is the redemption arb path. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Redemption is open to anyone but is the canonical arb path — surface only if the user has explicitly requested a redemption arb.
