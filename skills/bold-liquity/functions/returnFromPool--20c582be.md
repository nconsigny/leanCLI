# returnFromPool

**Signature**: `returnFromPool(address poolAddress,address user,uint256 _amount)`

**Selector**: `0x20c582be`

**Mutability**: nonpayable

**Contract**: `BoldToken` (Liquity V2 / BOLD)

## Inputs
- `poolAddress` (`address`): TODO(curator): describe
- `user` (`address`): TODO(curator): describe
- `_amount` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / inter-contract helper. Not a user-signed flow — Liquity branches call each other through these. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Inter-contract or admin call gated by AddressesRegistry. Not a user surface.
