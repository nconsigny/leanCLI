# mintAggInterest

**Signature**: `mintAggInterest()`

**Selector**: `0x1bfa0d7b`

**Mutability**: nonpayable

**Contract**: `ActivePool` (Liquity V2 / BOLD)

## Inputs
- (none)

## Outputs
- (none)

## What it does

Admin / inter-contract helper. Not a user-signed flow — Liquity branches call each other through these. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Inter-contract or admin call gated by AddressesRegistry. Not a user surface.
