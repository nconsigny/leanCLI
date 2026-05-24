# setFeeRecipient

**Signature**: `setFeeRecipient(address newFeeRecipient)`

**Selector**: `0xe74b981b`

**Mutability**: nonpayable

**Contract**: `MorphoBlue` (Morpho)

## Inputs
- `newFeeRecipient` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Governance / admin function. The Morpho Blue owner can enable IRMs, enable LLTVs, set fees, and re-assign the fee recipient. Not a user surface. See <https://docs.morpho.org/morpho/contracts/morpho-blue>.

## Security notes

Admin gate by `owner()` — not a user surface.
