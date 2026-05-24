# settle

**Signature**: `settle(address[] tokens,uint256[] clearingPrices,(uint256 sellTokenIndex,uint256 buyTokenIndex,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,uint256 flags,uint256 executedAmount,bytes signature)[] trades,(address target,uint256 value,bytes callData)[][3] interactions)`

**Selector**: `0x13d79a0b`

**Mutability**: nonpayable

**Contract**: `GPv2Settlement` (CoW Protocol)

## Inputs
- `tokens` (`address[]`): TODO(curator): describe
- `clearingPrices` (`uint256[]`): TODO(curator): describe
- `trades` (`(uint256 sellTokenIndex,uint256 buyTokenIndex,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,uint256 flags,uint256 executedAmount,bytes signature)[]`): TODO(curator): describe
- `interactions` (`(address target,uint256 value,bytes callData)[][3]`): TODO(curator): describe

## Outputs
- (none)

## What it does

Solver-only batch settlement entrypoint. End users never call this directly; the canonical user-facing surface is the off-chain EIP-712 `Order` covered by `bridge/clearsign/registry/eip712-cowswap-order.json`. See <https://docs.cow.fi/cow-protocol/reference/contracts/core>.

## Security notes

Solver-restricted via `GPv2AllowListAuthentication`. A wallet user signing this directly is wrong; refuse.
