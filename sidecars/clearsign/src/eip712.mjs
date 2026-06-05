// EIP-712 typed-data decoder.
//
// Input: { chainId, domain: {...}, types: {...}, primaryType, message }.
// Output: same shape as tx.decodeIntent — { matched, intent, fields[], ... }.
//
// Lookup strategy:
//   1. Build the canonical encodeType string from the message's primaryType
//      and the supplied `types` (this is the EIP-712 §"Encode types"
//      definition). It's what 7730 uses as the format key.
//   2. Look up a descriptor by (chainId, domain.verifyingContract) in the
//      byEip712 index.
//   3. Find a `display.formats[encodeType]` entry; walk its `fields`.
//
// Without the deployment binding, fall back to none-matched. We don't
// implement the optional `domainSeparator` exact-match path — most
// descriptors use the deployments form.
import { formatField } from "./formatters.mjs";

export function decodeEip712Intent(req, registry) {
  const chainId = Number(req.chainId ?? req.domain?.chainId ?? 0);
  const domain = req.domain ?? {};
  const types = req.types ?? {};
  const primaryType = req.primaryType ?? "";
  const message = req.message ?? {};

  if (!primaryType || typeof types !== "object") {
    return { matched: false, reason: "missing primaryType or types" };
  }

  const verifying = (domain.verifyingContract ?? "").toLowerCase();
  if (!verifying) {
    return { matched: false, reason: "domain.verifyingContract is required" };
  }

  const depKey = `${chainId}:${verifying}`;
  const descriptor = registry.byEip712?.get(depKey);
  if (!descriptor) {
    return {
      matched: false,
      reason: `no EIP-712 descriptor for ${depKey}`,
      primaryType,
      domain,
    };
  }

  // Build the encodeType string: primaryType followed by every referenced
  // sub-struct in alphabetical order, in the form "TypeName(field1Type
  // field1Name,...)". This is what 7730 uses as the format key.
  const encodeType = buildEncodeType(primaryType, types);
  const formatSpec = descriptor.display?.formats?.[encodeType];
  if (!formatSpec) {
    return {
      matched: false,
      reason: `descriptor has no format for "${encodeType}"`,
      primaryType,
      domain,
    };
  }

  // For EIP-712, structured-data root is the `message` object. Paths address
  // it directly (e.g. "to.wallet" walks message.to.wallet).
  const ctx = {
    descriptor,
    structured: message,
    container: { chainId, domain, primaryType },
    tokenMetadata: req.tokenMetadata ?? {},
  };

  const fields = (formatSpec.fields ?? []).map((f) => formatField(f, ctx));

  return {
    matched: true,
    partial: false,
    source: descriptor.__source,
    owner: descriptor.metadata?.owner ?? null,
    contractName: descriptor.metadata?.contractName ?? descriptor.context?.$id ?? null,
    primaryType,
    encodeType,
    intent: formatSpec.intent ?? null,
    fields,
  };
}

// Per EIP-712 §"Encode types": referenced sub-structs are sorted by name,
// each rendered as "TypeName(fieldType fieldName,...)".
function buildEncodeType(primaryType, types) {
  const visited = new Set();
  const order = [];

  function visit(t) {
    if (visited.has(t)) return;
    if (!types[t]) return;
    visited.add(t);
    order.push(t);
    for (const field of types[t]) {
      // Strip array suffix to find the referenced type.
      const baseType = field.type.replace(/\[.*\]$/, "");
      if (types[baseType]) visit(baseType);
    }
  }

  visit(primaryType);

  // Primary first, the rest alphabetically (per spec).
  const head = order[0];
  const rest = order.slice(1).sort();
  const all = head ? [head, ...rest] : order;

  return all
    .map((name) => {
      const fields = types[name] ?? [];
      const inner = fields.map((f) => `${f.type} ${f.name}`).join(",");
      return `${name}(${inner})`;
    })
    .join("");
}
