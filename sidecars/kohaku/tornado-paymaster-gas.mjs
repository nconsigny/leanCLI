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

/** SDK default callGasLimit when tailCalls are set. */
export const TORNADO_BASE_CALL_GAS_LIMIT = 300_000n;

const TORNADO_EXECUTE_BATCH_OVERHEAD = 80_000n;
const TORNADO_EMPTY_CALL_GAS = 30_000n;
const TORNADO_NONEMPTY_CALL_FALLBACK_GAS = 350_000n;
const TORNADO_CALL_GAS_SAFETY_NUM = 15n;
const TORNADO_CALL_GAS_SAFETY_DEN = 10n; // 1.5x
const TORNADO_CALL_GAS_CAP = 5_000_000n;

/** Mirrors @kohaku-eth/tornado-cash `reasonableGasUnits` when tailCalls are set. */
export const TORNADO_PAYMASTER_GAS_UNITS = {
  preVerificationGas: TORNADO_PRE_VERIFICATION_GAS_LIMIT,
  verificationGasLimit: 50_000n,
  callGasLimit: TORNADO_BASE_CALL_GAS_LIMIT,
  paymasterVerificationGasLimit: 350_000n,
  paymasterPostOpGasLimit: TORNADO_PAYMASTER_POST_OP_GAS_LIMIT,
};

const ERC20_TRANSFER_GAS = 100_000n;

function calldataByteLength(data) {
  if (!data || data === "0x") return 0;
  return Math.max(0, Math.floor((data.length - 2) / 2));
}

function heuristicCallGas(call) {
  const bytes = calldataByteLength(call.data);
  if (bytes === 0) return TORNADO_EMPTY_CALL_GAS;
  // Rough calldata floor + room for a Uniswap-style swap / router call.
  const calldataGas = BigInt(bytes) * 16n;
  const estimated = 150_000n + calldataGas;
  return estimated > TORNADO_NONEMPTY_CALL_FALLBACK_GAS
    ? estimated
    : TORNADO_NONEMPTY_CALL_FALLBACK_GAS;
}

/**
 * Heuristic UserOperation callGasLimit for Tornado execute/executeBatch.
 * Deliberately does NOT call eth_estimateGas — the delegated account has no
 * funds until the unshield UserOp itself runs, so RPC estimation would fail
 * with insufficient funds. Ported from kohaku-cli 0df25ce.
 */
export function estimateTornadoCallGasLimit(calls) {
  let callsGas = 0n;
  for (const call of calls) {
    callsGas += heuristicCallGas(call);
  }

  let callGasLimit =
    TORNADO_EXECUTE_BATCH_OVERHEAD +
    (callsGas * TORNADO_CALL_GAS_SAFETY_NUM) / TORNADO_CALL_GAS_SAFETY_DEN;

  if (callGasLimit < TORNADO_BASE_CALL_GAS_LIMIT) callGasLimit = TORNADO_BASE_CALL_GAS_LIMIT;
  if (callGasLimit > TORNADO_CALL_GAS_CAP) callGasLimit = TORNADO_CALL_GAS_CAP;
  return callGasLimit;
}

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
    callGasLimit: hasTailCalls
      ? (opts?.callGasLimit ?? TORNADO_PAYMASTER_GAS_UNITS.callGasLimit)
      : 0n,
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

let basePatched = false;

function tornadoWorkerFiles() {
  const require = createRequire(import.meta.url);
  const pkgRoot = dirname(require.resolve("@kohaku-eth/tornado-cash/package.json"));
  return [
    join(pkgRoot, "dist/state-manager.worker.node.js"),
    join(pkgRoot, "dist/state-manager.worker.js"),
  ];
}

function patchWorkerBaseGasLimits(file) {
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
 * Force the SDK worker's baseGasUnits.callGasLimit. Must run before the worker
 * is spawned (i.e. before createTCPlugin / first Tornado sync). Ported from
 * kohaku-cli 0df25ce; best-effort like the base patches.
 */
function patchWorkerCallGasLimit(file, callGasLimit) {
  let source;
  try {
    source = readFileSync(file, "utf8");
  } catch (e) {
    console.error(`[bridge] tornado callGasLimit patch skipped (unreadable ${file}): ${e?.message ?? e}`);
    return;
  }
  const next = `callGasLimit: ${callGasLimit.toString()}n`;
  // Match the baseGasUnits field specifically (verificationGasLimit precedes it).
  const re = /(verificationGasLimit:\s*\d+n,\s*)callGasLimit:\s*\d+n/;
  if (!re.test(source)) {
    console.error(`[bridge] tornado callGasLimit patch skipped (pattern missing in ${file})`);
    return;
  }
  const updated = source.replace(re, `$1${next}`);
  if (updated !== source) {
    writeFileSync(file, updated);
    console.error(`[bridge] patched tornado callGasLimit to ${callGasLimit} in ${file}`);
  }
}

/**
 * Bump @kohaku-eth/tornado-cash worker gas limits (idempotent for the base
 * patches, best-effort). When `opts.callGasLimit` is provided it is always
 * written (must happen before the worker spawns); otherwise the default is
 * applied only on the first call so a prior override is preserved.
 * Node ignores `stateManagerWorkerUrl`, so we patch the bundled worker on disk.
 * A failure here is non-fatal: the withdraw may under-estimate gas and revert,
 * which surfaces as a broadcast error, not a silent loss.
 */
export function ensureTornadoPaymasterGasPatched(opts) {
  for (const file of tornadoWorkerFiles()) {
    if (!basePatched) {
      patchWorkerBaseGasLimits(file);
    }
    if (opts?.callGasLimit != null) {
      patchWorkerCallGasLimit(file, opts.callGasLimit);
    } else if (!basePatched) {
      patchWorkerCallGasLimit(file, TORNADO_BASE_CALL_GAS_LIMIT);
    }
  }
  basePatched = true;
}
