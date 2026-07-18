// Tornado Cash ERC-4337 paymaster gas helpers.
//
// Ported from kohaku-cli src/utils/tornado-paymaster-gas.ts (plain JS, no types).
//
// The withdraw paymaster flow pays gas out of the note's denomination and
// forwards the remainder to the recipient via a tail call. We must know the
// paymaster fee up front to compute that forward value, and we must patch the
// SDK's bundled worker gas limits because Node ignores `stateManagerWorkerUrl`
// (the worker runs from the on-disk file, not a caller-supplied URL).

import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

export const TORNADO_PRE_VERIFICATION_GAS_LIMIT = 85_000n;

/** SDK default is 10k; TornadoFeeAdapter postOp needs more on Sepolia. */
export const TORNADO_PAYMASTER_POST_OP_GAS_LIMIT = 100_000n;

/** Mirrors @kohaku-eth/tornado-cash `reasonableGasUnits` when tailCalls are set. */
export const TORNADO_PAYMASTER_GAS_UNITS = {
  preVerificationGas: TORNADO_PRE_VERIFICATION_GAS_LIMIT,
  verificationGasLimit: 50_000n,
  callGasLimit: 300_000n,
  paymasterVerificationGasLimit: 350_000n,
  paymasterPostOpGasLimit: TORNADO_PAYMASTER_POST_OP_GAS_LIMIT,
};

const ERC20_TRANSFER_GAS = 100_000n;

const WORKER_GAS_PATCHES = [
  { old: "preVerificationGas: 80000n", new: "preVerificationGas: 85000n", label: "preVerificationGas" },
  { old: "paymasterPostOpGasLimit: 10000n", new: "paymasterPostOpGasLimit: 100000n", label: "paymasterPostOpGasLimit" },
];

/** Same formula as tornado-cash `computeMinimumViableFee` (incl. 1.2x safety margin). */
export function estimateTornadoPaymasterFee(maxFeePerGas, opts) {
  const hasTailCalls = opts?.hasTailCalls ?? true;
  const isERC20 = opts?.isERC20 ?? false;
  const units = {
    ...TORNADO_PAYMASTER_GAS_UNITS,
    callGasLimit: hasTailCalls ? TORNADO_PAYMASTER_GAS_UNITS.callGasLimit : 0n,
    paymasterVerificationGasLimit: isERC20
      ? TORNADO_PAYMASTER_GAS_UNITS.paymasterVerificationGasLimit + ERC20_TRANSFER_GAS
      : TORNADO_PAYMASTER_GAS_UNITS.paymasterVerificationGasLimit,
  };
  const requiredGas =
    units.verificationGasLimit +
    units.callGasLimit +
    units.paymasterVerificationGasLimit +
    units.preVerificationGas +
    units.paymasterPostOpGasLimit;
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
  const json = await res.json();
  const hex = json?.result?.standard?.maxFeePerGas;
  if (!hex) {
    throw new Error(
      json?.error?.message ??
        "Failed to fetch bundler gas price for Tornado paymaster unshield.",
    );
  }
  return BigInt(hex);
}

let patched = false;

function tornadoWorkerFiles() {
  const require = createRequire(import.meta.url);
  const pkgRoot = dirname(require.resolve("@kohaku-eth/tornado-cash/package.json"));
  return [
    join(pkgRoot, "dist/state-manager.worker.node.js"),
    join(pkgRoot, "dist/state-manager.worker.js"),
  ];
}

function patchWorkerGasLimits(file) {
  let source;
  try {
    source = readFileSync(file, "utf8");
  } catch (e) {
    console.error(`[bridge] tornado worker patch skipped (unreadable ${file}): ${e?.message ?? e}`);
    return;
  }
  let changed = false;
  for (const { old, new: replacement, label } of WORKER_GAS_PATCHES) {
    if (source.includes(replacement)) continue;
    if (!source.includes(old)) {
      console.error(`[bridge] tornado ${label} patch skipped (constant missing in ${file})`);
      continue;
    }
    source = source.replace(old, replacement);
    changed = true;
    console.error(`[bridge] patched tornado ${label} in ${file}`);
  }
  if (changed) writeFileSync(file, source);
}

/**
 * Bump @kohaku-eth/tornado-cash worker gas limits (idempotent, best-effort).
 * Node ignores `stateManagerWorkerUrl`, so we patch the bundled worker on disk.
 * A failure here is non-fatal: the withdraw may under-estimate gas and revert,
 * which surfaces as a broadcast error, not a silent loss.
 */
export function ensureTornadoPaymasterGasPatched() {
  if (patched) return;
  for (const file of tornadoWorkerFiles()) {
    patchWorkerGasLimits(file);
  }
  patched = true;
}
