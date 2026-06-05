// Parse an ERC-7730 format key into a viem-compatible ABI item, then decode
// calldata against it. We don't reuse the registry file's pre-baked ABI
// because the format key is the source of truth for parameter names + types
// (it's what gets hashed into the selector). Building the ABI from the key
// guarantees decoded fields line up with descriptor `path` references.
import { decodeFunctionData, parseAbiItem } from "viem";

// Convert "transfer(address to,uint256 value)" into a viem AbiItem via
// human-readable ABI parsing. Tuples need the Solidity-style "(...)" form,
// which viem accepts directly. Anonymous tuples (no inner names) are fine
// for selector hashing but lose path resolvability — descriptor authors
// should provide names in the format key when they want path access.
export function abiItemFromFormatKey(formatKey) {
  // viem's parseAbiItem expects "function transfer(address to, uint256 value)".
  return parseAbiItem(`function ${formatKey}`);
}

// Decode the raw calldata into { functionName, args }. Args are positional;
// for tuples viem returns an object keyed by component name when names are
// present in the ABI item — exactly what we need for descriptor paths like
// "params.tokenIn".
export function decodeCalldata(formatKey, data) {
  const item = abiItemFromFormatKey(formatKey);
  return decodeFunctionData({ abi: [item], data });
}
