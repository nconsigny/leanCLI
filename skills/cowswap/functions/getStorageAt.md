# getStorageAt

**Signature**: `getStorageAt(uint256 offset,uint256 length)`

**Selector**: `0x5624b25b`

**Mutability**: view

**Contract**: `GPv2Settlement` (CoW Protocol)

## Inputs
- `offset` (`uint256`): TODO(curator): describe
- `length` (`uint256`): TODO(curator): describe

## Outputs
- `(unnamed)` (`bytes`): TODO(curator): describe

## What it does

View accessor. Used by the wallet during pre-sign to read protocol parameters or order state; never called as a state-changing tx. See <https://docs.cow.fi/cow-protocol/reference/contracts/core>.

## Security notes

TODO(curator): solver-vs-trader role, EIP-712 vs EIP-1271 path, replay protection.
