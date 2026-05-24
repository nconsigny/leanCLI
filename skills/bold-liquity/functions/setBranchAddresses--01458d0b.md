# setBranchAddresses

**Signature**: `setBranchAddresses(address _troveManagerAddress,address _stabilityPoolAddress,address _borrowerOperationsAddress,address _activePoolAddress)`

**Selector**: `0x01458d0b`

**Mutability**: nonpayable

**Contract**: `BoldToken` (Liquity V2 / BOLD)

## Inputs
- `_troveManagerAddress` (`address`): TODO(curator): describe
- `_stabilityPoolAddress` (`address`): TODO(curator): describe
- `_borrowerOperationsAddress` (`address`): TODO(curator): describe
- `_activePoolAddress` (`address`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / inter-contract helper. Not a user-signed flow — Liquity branches call each other through these. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Inter-contract or admin call gated by AddressesRegistry. Not a user surface.
