# flashLoan

**Signature**: `flashLoan(address receiverAddress,address[] assets,uint256[] amounts,uint256[] interestRateModes,address onBehalfOf,bytes params,uint16 referralCode)`

**Selector**: `0xab9c4b5d`

**Mutability**: nonpayable

**Contract**: `Pool` (Aave V3)

## Inputs
- `receiverAddress` (`address`): TODO(curator): describe
- `assets` (`address[]`): TODO(curator): describe
- `amounts` (`uint256[]`): TODO(curator): describe
- `interestRateModes` (`uint256[]`): TODO(curator): describe
- `onBehalfOf` (`address`): TODO(curator): describe
- `params` (`bytes`): TODO(curator): describe
- `referralCode` (`uint16`): TODO(curator): describe

## Outputs
- (none)

## What it does

Multi-asset flash loan. The caller must implement `IFlashLoanReceiver.executeOperation` and repay loan + premium in the same tx. See <https://aave.com/docs/developers/smart-contracts/pool>.

## Security notes

Flash loans are not a retail surface; refuse unless the user has wired a receiver contract.
