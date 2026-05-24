# supplyWithPermit

**Signature**: `supplyWithPermit(address asset,uint256 amount,address onBehalfOf,uint16 referralCode,uint256 deadline,uint8 permitV,bytes32 permitR,bytes32 permitS)`

**Selector**: `0x02c205f0`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `asset` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `onBehalfOf` (`address`): TODO(curator): describe
- `referralCode` (`uint16`): TODO(curator): describe
- `deadline` (`uint256`): TODO(curator): describe
- `permitV` (`uint8`): TODO(curator): describe
- `permitR` (`bytes32`): TODO(curator): describe
- `permitS` (`bytes32`): TODO(curator): describe

## Outputs
- (none)

## What it does

Same as `supply` but submits an ERC-2612 `permit` signature in the same tx so no separate `approve` is needed. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Always re-read `getUserAccountData(user)` after building the calldata and surface the resulting **health factor** to the user before signing. Refuse if hf would drop below 1.05.
