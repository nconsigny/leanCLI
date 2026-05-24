# repayWithPermit

**Signature**: `repayWithPermit(address asset,uint256 amount,uint256 interestRateMode,address onBehalfOf,uint256 deadline,uint8 permitV,bytes32 permitR,bytes32 permitS)`

**Selector**: `0xee3e210b`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `interestRateMode` (`uint256`): TODO(curator): describe
- `onBehalfOf` (`address`): TODO(curator): describe
- `deadline` (`uint256`): TODO(curator): describe
- `permitV` (`uint8`): TODO(curator): describe
- `permitR` (`bytes32`): TODO(curator): describe
- `permitS` (`bytes32`): TODO(curator): describe

## Outputs
- `(unnamed)` (`uint256`): TODO(curator): describe

## What it does

Same as `repay` plus an ERC-2612 `permit` signature on the debt asset. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

TODO(curator): permission boundary, oracle dependency, slippage / health-factor implication.
