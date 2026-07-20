const BPS_DENOMINATOR = 10_000n;

export const RAILGUN_UNSHIELD_GAS_UNITS = Object.freeze({
  preVerificationGas: 100_000n,
  verificationGasLimit: 150_000n,
  callGasLimit: 2_500_000n,
  nativeUnwrapCallGas: 80_000n,
  paymasterVerificationGasLimit: 400_000n,
  paymasterPostOpGasLimit: 120_000n,
});

export function estimateRailgunBundlerFeeWei(maxFeePerGas, { nativeUnwrap = false } = {}) {
  const units = RAILGUN_UNSHIELD_GAS_UNITS;
  const callGas = units.callGasLimit + (nativeUnwrap ? units.nativeUnwrapCallGas : 0n);
  const requiredGas = units.verificationGasLimit + callGas +
    units.paymasterVerificationGasLimit + units.preVerificationGas +
    units.paymasterPostOpGasLimit;
  return (requiredGas * BigInt(maxFeePerGas) * 12n) / 10n;
}

export function railgunMaxReceivableFromBalance(balance, unshieldFeeBps, reservedFeeTokenWei) {
  balance = BigInt(balance);
  reservedFeeTokenWei = BigInt(reservedFeeTokenWei);
  const feeBps = BigInt(unshieldFeeBps);
  if (balance <= reservedFeeTokenWei || feeBps >= BPS_DENOMINATOR) return 0n;
  return ((balance - reservedFeeTokenWei) * (BPS_DENOMINATOR - feeBps)) /
    BPS_DENOMINATOR;
}

export async function fetchPimlicoMaxFeePerGas(bundlerUrl) {
  const response = await fetch(bundlerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 1,
      method: "pimlico_getUserOperationGasPrice", params: [],
    }),
  });
  const json = await response.json();
  const value = json?.result?.standard?.maxFeePerGas;
  if (!response.ok || value == null) {
    throw new Error(json?.error?.message ??
      `failed to fetch Pimlico bundler gas price (HTTP ${response.status})`);
  }
  return BigInt(value);
}

export function largestSpendableNote(notes, balanceField = "balance") {
  let largest = 0n;
  for (const note of notes ?? []) {
    const balance = BigInt(note?.[balanceField] ?? 0);
    if (balance > largest) largest = balance;
  }
  return largest;
}
