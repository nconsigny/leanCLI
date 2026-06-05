// ERC-7730 path resolver.
//
// Roots per spec (§"Path References"):
//   `#`  structured data (decoded function args / EIP-712 fields)
//   `$`  merged ERC-7730 file values (descriptor itself)
//   `@`  container values (`from`, `value`, `to`, `chainId`)
//
// Relative paths default to the enclosing structured-data root (`#`).
// Field names with `.` are walked as nested object keys (e.g. `params.tokenIn`).

export function resolvePath(spec, ctx) {
  if (typeof spec !== "string" || spec.length === 0) return undefined;
  const { root, rest } = splitRoot(spec);
  let base;
  switch (root) {
    case "@":
      base = ctx.container;
      break;
    case "$":
      base = ctx.descriptor;
      break;
    case "#":
    default:
      base = ctx.structured;
      break;
  }
  return walk(base, rest);
}

function splitRoot(spec) {
  if (spec.startsWith("@.")) return { root: "@", rest: spec.slice(2) };
  if (spec.startsWith("$.")) return { root: "$", rest: spec.slice(2) };
  if (spec.startsWith("#.")) return { root: "#", rest: spec.slice(2) };
  if (spec === "@" || spec === "$" || spec === "#") return { root: spec, rest: "" };
  return { root: "#", rest: spec };
}

function walk(base, rest) {
  if (rest === "") return base;
  const parts = rest.split(".");
  let cur = base;
  for (const p of parts) {
    if (cur === undefined || cur === null) return undefined;
    // Numeric segments index arrays; otherwise key into an object.
    if (/^\d+$/.test(p) && Array.isArray(cur)) cur = cur[Number(p)];
    else cur = cur[p];
  }
  return cur;
}
