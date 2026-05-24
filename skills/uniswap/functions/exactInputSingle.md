# exactInputSingle

**Signature**: `exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96) params)`

**Selector**: `0x04e45aaf`

**Mutability**: payable

**Contract**: `SwapRouter02` (Uniswap)

## Inputs
- `params` (`(address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)`): TODO(curator): describe

## Outputs
- `amountOut` (`uint256`): TODO(curator): describe

## What it does

See `bridge/clearsign/registry/uniswap-v3-swap-router-02.json` for the canonical ERC-7730 decoded view shown to the user at signing time.

## Security notes

TODO(curator): approval surface, slippage, recipient checks, callbacks, multicall framing.
