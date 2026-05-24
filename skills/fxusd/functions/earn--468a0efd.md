# earn

**Signature**: `earn(address pool,uint256 amount,address receiver)`

**Selector**: `0x468a0efd`

**Mutability**: nonpayable

**Contract**: `FxUSD` (fx Protocol)

## Inputs
- `pool` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `receiver` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Stake fxUSD into a Rebalance Pool (the protocol's stability sink). Earns leverage-side liquidations and gauge incentives. See <https://docs.aladdin.club/fx-protocol/>.

## Security notes

Staking fxUSD in a Rebalance Pool exposes principal to liquidation losses (the pool absorbs xToken liquidations).
