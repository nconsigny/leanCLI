# vaultRelayer

**Signature**: `vaultRelayer()`

**Selector**: `0x9b552cc2`

**Mutability**: view

**Contract**: `GPv2Settlement` (CoW Protocol)

## Inputs
- (none)

## Outputs
- `(unnamed)` (`address`): TODO(curator): describe

## What it does

View accessor. Used by the wallet during pre-sign to read protocol parameters or order state; never called as a state-changing tx. See <https://docs.cow.fi/cow-protocol/reference/contracts/core>.

## Security notes

TODO(curator): solver-vs-trader role, EIP-712 vs EIP-1271 path, replay protection.
