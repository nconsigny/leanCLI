// Load every JSON file from `registry/` at boot and build two indexes:
//   1. (chainId, address) → descriptor — when an ERC-7730 file scopes itself
//      to specific deployments via context.contract.deployments.
//   2. functionSelector → [descriptor, formatKey] — for chain-agnostic
//      descriptors (notably the standard ERC-20 file). Used as a fallback
//      when the (chainId, address) lookup misses.
//
// The walker (decoder.mjs) consults the deployment index first; if no match,
// it tries the selector index. This lets us decode `transfer(...)` against
// any ERC-20 token without enumerating every token in the registry.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseAbiItem, toFunctionSelector } from "viem";

const SELF_DIR = path.dirname(fileURLToPath(import.meta.url));
const REGISTRY_DIR = path.resolve(SELF_DIR, "..", "registry");

// Compute the 4-byte selector for an ERC-7730 format key. The format key
// is the human-readable ABI signature *with* parameter names (e.g.
// "transfer(address to,uint256 value)"); viem's parseAbiItem strips names
// and hashes the canonical form. Returns null if the key isn't a valid
// function signature (e.g. EIP-712 encodeType keys).
//
// Using viem instead of an ad-hoc regex because the regex form did not
// descend into nested tuple parens — `exactInputSingle((address tokenIn,…)
// params)` would have kept the trailing ` params` in the hashed signature
// and produced a wrong selector. viem's parser handles arbitrary nesting.
export function formatKeyToSelector(formatKey) {
  try {
    const item = parseAbiItem(`function ${formatKey}`);
    return toFunctionSelector(item).toLowerCase();
  } catch {
    return null;
  }
}

export function loadRegistry() {
  const files = fs
    .readdirSync(REGISTRY_DIR)
    .filter((f) => f.endsWith(".json"))
    .map((f) => path.join(REGISTRY_DIR, f));

  // (chainId:address) → descriptor
  const byDeployment = new Map();
  // selector → array of { descriptor, formatKey, formatSpec }
  const bySelector = new Map();
  // (chainId:verifyingContract) → eip712 descriptor (same shape; routes through
  // the descriptor's `context.eip712` block instead of `context.contract`).
  const byEip712 = new Map();
  // selector → signature  (4byte fallback, last resort)
  const fallback = new Map();

  for (const file of files) {
    let descriptor;
    try {
      descriptor = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
      console.error(`[clearsign] skip ${file}: invalid JSON: ${e?.message}`);
      continue;
    }
    descriptor.__source = path.basename(file);

    // Special-case the 4byte fallback dict — it doesn't follow the 7730
    // schema, just maps `selector → signature` grouped under arbitrary
    // category keys for readability.
    if (path.basename(file) === "4byte.json") {
      for (const [_category, entries] of Object.entries(descriptor)) {
        if (typeof entries !== "object" || entries === null) continue;
        for (const [sel, sig] of Object.entries(entries)) {
          if (/^0x[0-9a-fA-F]{8}$/.test(sel) && typeof sig === "string") {
            fallback.set(sel.toLowerCase(), sig);
          }
        }
      }
      continue;
    }

    const deployments = descriptor?.context?.contract?.deployments ?? [];
    for (const d of deployments) {
      if (typeof d?.chainId === "number" && typeof d?.address === "string") {
        const key = `${d.chainId}:${d.address.toLowerCase()}`;
        byDeployment.set(key, descriptor);
      }
    }

    // EIP-712 descriptors bind via context.eip712.deployments (chainId +
    // verifyingContract) instead of context.contract.deployments.
    const eip712Deployments = descriptor?.context?.eip712?.deployments ?? [];
    for (const d of eip712Deployments) {
      if (typeof d?.chainId === "number" && typeof d?.verifyingContract === "string") {
        const key = `${d.chainId}:${d.verifyingContract.toLowerCase()}`;
        byEip712.set(key, descriptor);
      }
    }

    const formats = descriptor?.display?.formats ?? {};
    for (const [formatKey, formatSpec] of Object.entries(formats)) {
      // EIP-712 format keys use the encodeType string ("Mail(Person from,...)"),
      // which we never want to hash as a function selector. Detect: if the key
      // doesn't look like a function ABI fragment ("name(args)"), skip the
      // selector index — this format is for EIP-712 messages.
      if (!/^[A-Za-z_][A-Za-z0-9_]*\(/.test(formatKey)) continue;
      const sel = formatKeyToSelector(formatKey);
      if (!sel) {
        console.error(`[clearsign] skip selector for "${formatKey}": unparseable signature`);
        continue;
      }
      if (!bySelector.has(sel)) bySelector.set(sel, []);
      bySelector.get(sel).push({ descriptor, formatKey, formatSpec });
    }
  }

  return { byDeployment, bySelector, byEip712, fallback };
}
