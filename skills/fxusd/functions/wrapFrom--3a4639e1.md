# wrapFrom

**Signature**: `wrapFrom(address pool,uint256 amount,address receiver)`

**Selector**: `0x3a4639e1`

**Mutability**: nonpayable

**Contract**: `FxUSD` (fx Protocol)

## Inputs
- `pool` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Same as `wrap` but pulls fTokens from `pool` (a Rebalance Pool the caller deposited into). See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Pre-sign: read the market's current collateral ratio (`MarketV2.collateralRatio()` or via `TreasuryV2.collateralRatio()`). Surface whether the market is in stability mode (cannot mint xToken) and refuse if the user is trying to mint into a market in shutdown.
