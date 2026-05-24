# setCollateralRegistry

**Signature**: `setCollateralRegistry(address _collateralRegistryAddress)`

**Selector**: `0x34fd38f9`

**Mutability**: nonpayable

**Contract**: `BoldToken` (Liquity V2 / BOLD)

## Inputs
- `_collateralRegistryAddress` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / inter-contract helper. Not a user-signed flow — Liquity branches call each other through these. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Inter-contract or admin call gated by AddressesRegistry. Not a user surface.
