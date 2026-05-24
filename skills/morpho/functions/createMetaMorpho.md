# createMetaMorpho

**Signature**: `createMetaMorpho(address initialOwner,uint256 initialTimelock,address asset,string name,string symbol,bytes32 salt)`

**Selector**: `0xb5102025`

**Mutability**: nonpayable

**Contract**: `MetaMorphoFactory` (Morpho)

## Inputs
- `initialOwner` (`address`): TODO(curator): describe
- `initialTimelock` (`uint256`): TODO(curator): describe
- `asset` (`address`): TODO(curator): describe
- `name` (`string`): TODO(curator): describe
- `symbol` (`string`): TODO(curator): describe
- `salt` (`bytes32`): TODO(curator): describe

## Outputs
- `metaMorpho` (`IMetaMorpho`): TODO(curator): describe

## What it does

Deploys a new MetaMorpho vault with a fixed timelock, underlying asset, name, symbol, and CREATE2 salt. See <https://docs.morpho.org/curation/concepts/metamorpho>.

## Security notes

Deploying a new vault is a public action but commits the caller to the gas + initial owner choice. Surface the `initialTimelock` and `salt` clearly.
