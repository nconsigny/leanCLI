# setAuthorizationWithSig

**Signature**: `setAuthorizationWithSig((address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline) authorization,(uint8 v,bytes32 r,bytes32 s) signature)`

**Selector**: `0x8069218f`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `authorization` (`(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)`): TODO(curator): describe
- `signature` (`(uint8 v,bytes32 r,bytes32 s)`): TODO(curator): describe

## Outputs
- (none)

## What it does

Same as `setAuthorization` but consumes an EIP-712 signature so a third party can submit. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Signing an EIP-712 `setAuthorization` is equivalent to handing the `authorized` party control over the user's positions. Decode the typed-data fields (`authorizer`, `authorized`, `isAuthorized`, `nonce`, `deadline`) and surface them all.
