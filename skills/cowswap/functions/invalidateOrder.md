# invalidateOrder

**Signature**: `invalidateOrder(bytes orderUid)`

**Selector**: `0x15337bc0`

**Mutability**: nonpayable

**Contract**: `GPv2Settlement` (CoW Protocol)

## Inputs
- `orderUid` (`bytes`): TODO(curator): describe

## Outputs
- (none)

## What it does

Caller invalidates one of their own `Order` UIDs so it can no longer be settled by a solver. The wallet must decode the `orderUid` and surface the underlying `Order` before submitting. See <https://docs.cow.fi/cow-protocol/reference/contracts/core>.

## Security notes

Cheap-but-non-free cancel. Surfacing the order being cancelled is mandatory so the user doesn't accidentally rescind a different one.
