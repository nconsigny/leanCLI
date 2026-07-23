import { AbiCoder, Interface, JsonRpcProvider, keccak256 } from "ethers";

import {
  estimateTornadoPaymasterFee,
  tornadoWithdrawalCallGasLimit,
} from "./tornado-paymaster-gas.mjs";

/** EIP-7702 SimpleAccount implementation used by the Tornado SDK. */
export const TORNADO_SIMPLE_7702_IMPLEMENTATION =
  "0xe6Cae83BdE06E4c305530e199D7217f42808555B";

const EXECUTE_ABI = [
  "function execute(address target, uint256 value, bytes data)",
  "function executeBatch((address target, uint256 value, bytes data)[] calls)",
];
const executeIface = new Interface(EXECUTE_ABI);
const abiCoder = AbiCoder.defaultAbiCoder();

const TAIL_GAS_OVERHEAD_NUM = 11n;
const TAIL_GAS_OVERHEAD_DEN = 10n;
const MAX_REFINE_ITERS = 2;

function encodeAccountCalls(calls) {
  if (calls.length === 0) {
    throw new Error("Cannot estimate gas for an empty tail-call list.");
  }
  if (calls.length === 1) {
    const call = calls[0];
    return executeIface.encodeFunctionData("execute", [
      call.to,
      call.value,
      call.data,
    ]);
  }
  return executeIface.encodeFunctionData("executeBatch", [
    calls.map((call) => ({
      target: call.to,
      value: call.value,
      data: call.data,
    })),
  ]);
}

function toHexQuantity(value) {
  return `0x${value.toString(16)}`;
}

export function withTailCallsGasOverhead(measuredGas) {
  if (measuredGas <= 0n) throw new Error("measuredGas must be positive");
  return (measuredGas * TAIL_GAS_OVERHEAD_NUM) / TAIL_GAS_OVERHEAD_DEN;
}

function buildStateOverride(account, implementationCode, balanceWei) {
  return {
    [account]: {
      balance: toHexQuantity(balanceWei),
      code: implementationCode,
    },
  };
}

/**
 * Estimate execution-tail gas with the post-withdraw ETH balance and EIP-7702
 * account code injected through Geth-style state overrides.
 */
export async function estimateTornadoTailCallsGas({
  rpcUrl,
  account,
  calls,
  nativeBalanceWei,
}) {
  if (calls.length === 0) {
    throw new Error("Cannot estimate gas for an empty tail-call list.");
  }
  if (nativeBalanceWei < 0n) {
    throw new Error("nativeBalanceWei must be non-negative");
  }

  const provider = new JsonRpcProvider(rpcUrl);
  try {
    const implementationCode = await provider.send("eth_getCode", [
      TORNADO_SIMPLE_7702_IMPLEMENTATION,
      "latest",
    ]);
    if (
      typeof implementationCode !== "string" ||
      implementationCode === "0x" ||
      !/^0x(?:[0-9a-fA-F]{2})+$/.test(implementationCode)
    ) {
      throw new Error(
        `Tornado Simple7702 implementation has no valid code at ${TORNADO_SIMPLE_7702_IMPLEMENTATION}`,
      );
    }

    const data = encodeAccountCalls(calls);
    let gasHex;
    try {
      gasHex = await provider.send("eth_estimateGas", [
        { from: account, to: account, data },
        "latest",
        buildStateOverride(account, implementationCode, nativeBalanceWei),
      ]);
    } catch (cause) {
      throw new Error(
        "Failed to estimate Tornado tail-call gas. The configured RPC must " +
          `support Geth-style state overrides on eth_estimateGas: ${cause?.message ?? cause}`,
        { cause },
      );
    }
    if (typeof gasHex !== "string" || !/^0x[0-9a-fA-F]+$/.test(gasHex)) {
      throw new Error(`eth_estimateGas returned an invalid quantity: ${gasHex}`);
    }
    const gas = BigInt(gasHex);
    if (gas <= 0n) throw new Error("eth_estimateGas returned non-positive gas");
    return gas;
  } finally {
    provider.destroy();
  }
}

function buildSimulationPlan({
  amountWei,
  estimatedFee,
  userTailCalls,
}) {
  const afterFee = amountWei - estimatedFee;
  if (afterFee <= 0n) {
    throw new Error(
      `Withdrawal amount is too small to cover the Tornado paymaster fee (${estimatedFee} wei).`,
    );
  }
  const userTailValue = userTailCalls.reduce(
    (sum, call) => sum + call.value,
    0n,
  );
  if (userTailValue > afterFee) {
    throw new Error(
      `tail call value total (${userTailValue} wei) exceeds the amount ` +
        `remaining after the Tornado paymaster fee (${afterFee} wei)`,
    );
  }
  return {
    calls: [...userTailCalls],
    balanceWei: afterFee,
  };
}

/**
 * Resolve the SDK's `tailCallsGasEstimate`. The fee depends on the gas estimate
 * and the forwarded balance depends on the fee, so refine twice, then apply the
 * explicit 10% margin used by the reference CLI branch.
 */
export async function resolveTornadoTailCallsGasEstimate({
  rpcUrl,
  account,
  amountWei,
  maxFeePerGas,
  extraWithdrawals,
  userTailCalls,
}) {
  if (userTailCalls.length === 0) return undefined;

  let executionTail = tornadoWithdrawalCallGasLimit(0, undefined, false, true);
  let measured = 0n;
  for (let i = 0; i < MAX_REFINE_ITERS; i++) {
    const callGasLimit = tornadoWithdrawalCallGasLimit(
      extraWithdrawals,
      executionTail,
    );
    const fee = estimateTornadoPaymasterFee(maxFeePerGas, { callGasLimit });
    const plan = buildSimulationPlan({
      amountWei,
      estimatedFee: fee,
      userTailCalls,
    });
    measured = await estimateTornadoTailCallsGas({
      rpcUrl,
      account,
      calls: plan.calls,
      nativeBalanceWei: plan.balanceWei,
    });
    executionTail = withTailCallsGasOverhead(measured);
  }
  return withTailCallsGasOverhead(measured);
}

// Keep the mapping-slot helper available for parity tests and future ERC-20
// Tornado pools, while the current leanCLI surface remains ETH-only.
export function solidityMappingSlot(account, baseSlot) {
  return keccak256(
    abiCoder.encode(["address", "uint256"], [account, baseSlot]),
  );
}
