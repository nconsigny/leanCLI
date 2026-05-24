# sendColl

**Signature**: `sendColl(address _account,uint256 _amount)`

**Selector**: `0x9f4e511e`

**Mutability**: nonpayable

**Contract**: `ActivePool` (Liquity V2 / BOLD)

## Inputs
- `_account` (`address`): TODO(curator): describe
- `_amount` (`uint256`): TODO(curator): describe

## Outputs
- (none)

## What it does

Admin / inter-contract helper. Not a user-signed flow — Liquity branches call each other through these. See <https://github.com/liquity/bold/blob/main/README.md>.

## Security notes

Inter-contract or admin call gated by AddressesRegistry. Not a user surface.
