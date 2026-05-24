# simulateDelegatecall

**Signature**: `simulateDelegatecall(address targetContract,bytes calldataPayload)`

**Selector**: `0xf84436bd`

**Mutability**: nonpayable

**Contract**: `GPv2Settlement` (CoW Protocol)

## Inputs
- `targetContract` (`address`): TODO(curator): describe
- `calldataPayload` (`bytes`): TODO(curator): describe

## Outputs
- `response` (`bytes`): TODO(curator): describe

## What it does

TODO(curator): operational semantics for `GPv2Settlement.simulateDelegatecall` — see <https://docs.cow.fi/cow-protocol/reference/contracts/core>.

## Security notes

Maintenance/simulation surfaces — not a user-signed flow. Refuse if a wallet flow tries to call them.
