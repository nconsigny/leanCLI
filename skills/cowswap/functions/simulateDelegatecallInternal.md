# simulateDelegatecallInternal

**Signature**: `simulateDelegatecallInternal(address targetContract,bytes calldataPayload)`

**Selector**: `0x43218e19`

**Mutability**: nonpayable

**Contract**: `GPv2Settlement` (CoW Protocol)

## Inputs
- `targetContract` (`address`): TODO(curator): describe
- `calldataPayload` (`bytes`): TODO(curator): describe

## Outputs
- `response` (`bytes`): TODO(curator): describe

## What it does

TODO(curator): operational semantics for `GPv2Settlement.simulateDelegatecallInternal` — see <https://docs.cow.fi/cow-protocol/reference/contracts/core>.

## Security notes

Maintenance/simulation surfaces — not a user-signed flow. Refuse if a wallet flow tries to call them.
