# swap

**Signature**: `swap((bytes32 poolId,uint256 assetInIndex,uint256 assetOutIndex,uint256 amount,bytes userData)[] swaps,address[] tokens,(uint256 sellTokenIndex,uint256 buyTokenIndex,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,uint256 flags,uint256 executedAmount,bytes signature) trade)`

**Selector**: `0x845a101f`

**Mutability**: nonpayable

**Contract**: `GPv2Settlement` (CoW Protocol)

## Inputs
- `swaps` (`(bytes32 poolId,uint256 assetInIndex,uint256 assetOutIndex,uint256 amount,bytes userData)[]`): TODO(curator): describe
- `tokens` (`address[]`): TODO(curator): describe
- `trade` (`(uint256 sellTokenIndex,uint256 buyTokenIndex,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,uint256 flags,uint256 executedAmount,bytes signature)`): TODO(curator): describe

## Outputs
- (none)

## What it does

Solver-only single-trade swap path (skips batch-auction matching). End users never call this directly. See <https://docs.cow.fi/cow-protocol/reference/contracts/core>.

## Security notes

TODO(curator): solver-vs-trader role, EIP-712 vs EIP-1271 path, replay protection.
