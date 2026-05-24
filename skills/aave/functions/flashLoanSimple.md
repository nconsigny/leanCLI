# flashLoanSimple

**Signature**: `flashLoanSimple(address receiverAddress,address asset,uint256 amount,bytes params,uint16 referralCode)`

**Selector**: `0x42b0b77c`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `receiverAddress` (`address`): TODO(curator): describe
- `asset` (`address`): TODO(curator): describe
- `amount` (`uint256`): TODO(curator): describe
- `params` (`bytes`): TODO(curator): describe
- `referralCode` (`uint16`): TODO(curator): describe

## Outputs
- (none)

## What it does

Single-asset flash loan with a thinner callback interface. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Same as `flashLoan`.
