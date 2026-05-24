# setPreSignature

**Signature**: `setPreSignature(bytes orderUid,bool signed)`

**Selector**: `0xec6cb13f`

**Mutability**: nonpayable

**Contract**: `GPv2Settlement` (CoW Protocol)

## Inputs
- `orderUid` (`bytes`): TODO(curator): describe
- `signed` (`bool`): TODO(curator): describe

## Outputs
- (none)

## What it does

On-chain pre-signature for an EIP-712 `Order`. The off-chain order EIP-712 payload is covered by `bridge/clearsign/registry/eip712-cowswap-order.json`. Used when the order is being signed by a smart-contract account (EIP-1271) or pre-committed by an EOA. See <https://docs.cow.fi/cow-protocol/reference/contracts/core>.

## Security notes

Granting a pre-signature for an order whose underlying `Order` has not been independently EIP-712 decoded is equivalent to signing it blind. The wallet must decode the `orderUid` and surface the underlying `Order` before submitting.
