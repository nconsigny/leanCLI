# setAuthorization

**Signature**: `setAuthorization(address authorized,bool newIsAuthorized)`

**Selector**: `0xeecea000`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `authorized` (`address`): TODO(curator): describe
- `newIsAuthorized` (`bool`): TODO(curator): describe

## Outputs
- (none)

## What it does

Authorize / deauthorize `authorized` to act on the caller's positions across all markets. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

TODO(curator): callback re-entrancy, oracle dependency, share / asset rounding edge cases.
