// Tornado Cash ERC-4337 paymaster gas helpers.
//
// These constants mirror @kohaku-eth/tornado-cash 0.0.2-alpha.18. Keep the
// fee preview aligned with the SDK instead of mutating its installed worker.

/** SDK base callGasLimit when paymaster tail calls are present. */
export const TORNADO_BASE_CALL_GAS_LIMIT = 300_000n;
export const TORNADO_FORWARD_CALL_GAS_LIMIT = 60_000n;

/** SDK gas allowance for each direct ETH withdrawal after the first. */
const TORNADO_PER_DIRECT_WITHDRAW_GAS = 400_000n;

/** SDK gas allowance for each direct ERC-20 withdrawal after the first. */
const TORNADO_PER_DIRECT_WITHDRAW_GAS_ERC20 = 500_000n;

const TORNADO_PAYMASTER_GAS_UNITS = {
  preVerificationGas: 85_000n,
  verificationGasLimit: 50_000n,
  paymasterVerificationGasLimit: 350_000n,
  paymasterPostOpGasLimit: 50_000n,
};

const ERC20_TRANSFER_GAS = 100_000n;

/**
 * Mirrors SDK `reasonableGasUnitsForBatch().callGasLimit`.
 * `executionTail` is the measured user tail-call gas and defaults to the
 * SDK's static forward-only baseline.
 */
export function tornadoWithdrawalCallGasLimit(
  extraWithdrawals,
  executionTail,
  isERC20 = false,
  hasUserTailCalls = executionTail !== undefined,
) {
  if (!Number.isSafeInteger(extraWithdrawals) || extraWithdrawals < 0) {
    throw new Error("extraWithdrawals must be a non-negative safe integer");
  }
  const perWithdraw = isERC20
    ? TORNADO_PER_DIRECT_WITHDRAW_GAS_ERC20
    : TORNADO_PER_DIRECT_WITHDRAW_GAS;
  // A single withdrawal without user tails takes the SDK's independent path;
  // its fee is quoted with baseGasUnits even though the final callGasLimit is
  // zero. Multi-note consolidation uses a 60k automatic-forward allowance.
  const tail = hasUserTailCalls
    ? (executionTail ?? TORNADO_BASE_CALL_GAS_LIMIT)
    : (extraWithdrawals === 0
        ? TORNADO_BASE_CALL_GAS_LIMIT
        : TORNADO_FORWARD_CALL_GAS_LIMIT);
  return BigInt(extraWithdrawals) * perWithdraw +
    tail;
}

/** Mirrors SDK `computeMinimumViableFee`, including its 1.2x safety margin. */
export function estimateTornadoPaymasterFee(maxFeePerGas, opts) {
  if (maxFeePerGas < 0n) throw new Error("maxFeePerGas must be non-negative");
  const callGasLimit = opts?.callGasLimit ?? TORNADO_BASE_CALL_GAS_LIMIT;
  const isERC20 = opts?.isERC20 ?? false;
  const requiredGas =
    TORNADO_PAYMASTER_GAS_UNITS.verificationGasLimit +
    callGasLimit +
    TORNADO_PAYMASTER_GAS_UNITS.paymasterVerificationGasLimit +
    (isERC20 ? ERC20_TRANSFER_GAS : 0n) +
    TORNADO_PAYMASTER_GAS_UNITS.preVerificationGas +
    TORNADO_PAYMASTER_GAS_UNITS.paymasterPostOpGasLimit;
  return (requiredGas * maxFeePerGas * 12n) / 10n;
}

export async function fetchTornadoMaxFeePerGas(bundlerUrl) {
  const res = await fetch(bundlerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "pimlico_getUserOperationGasPrice",
      params: [],
    }),
  });
  if (!res.ok) {
    throw new Error(`Tornado bundler gas-price request failed: HTTP ${res.status}`);
  }
  const json = await res.json();
  const hex = json?.result?.standard?.maxFeePerGas;
  if (typeof hex !== "string" || !/^0x[0-9a-fA-F]+$/.test(hex)) {
    throw new Error(
      json?.error?.message ??
        "Failed to fetch a valid bundler gas price for Tornado paymaster unshield.",
    );
  }
  return BigInt(hex);
}
