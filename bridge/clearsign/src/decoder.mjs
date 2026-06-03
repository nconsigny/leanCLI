// Top-level: input { chainId, to, value, data } → structured intent.
//
// Pipeline:
//   1. Read leading 4-byte selector from `data`.
//   2. Find candidate (descriptor, formatKey) entries via the deployment
//      index keyed by (chainId, to). If none, fall back to the selector
//      index — this covers chain-agnostic descriptors like ERC-20.
//   3. Decode `data` against the format key's ABI item.
//   4. Walk the format spec's `fields` array, resolve paths, run formatters.
//
// Output shape is small + JSON-safe; the Lean side re-validates and renders.
import { parseAbiItem } from "viem";
import { decodeCalldata } from "./abi.mjs";
import { formatField } from "./formatters.mjs";
import { formatKeyToSelector } from "./registry.mjs";

export function decodeTxIntent(req, registry) {
  const chainId = Number(req.chainId);
  const to = (req.to ?? "").toLowerCase();
  const value = req.value ?? "0x0";
  const data = req.data ?? "0x";

  if (!data || data.length < 10) {
    return {
      matched: false,
      reason: "calldata too short for a function selector",
      selector: null,
    };
  }
  const selector = data.slice(0, 10).toLowerCase();

  // Candidate set: deployment first (more specific), then selector fallback.
  const candidates = [];
  const depKey = `${chainId}:${to}`;
  const depDescriptor = registry.byDeployment.get(depKey);
  if (depDescriptor) {
    const formats = depDescriptor.display?.formats ?? {};
    for (const [formatKey, formatSpec] of Object.entries(formats)) {
      candidates.push({
        descriptor: depDescriptor,
        formatKey,
        formatSpec,
        source: "deployment",
      });
    }
  }
  for (const entry of registry.bySelector.get(selector) ?? []) {
    candidates.push({ ...entry, source: "selector" });
  }

  // Pick the first candidate whose selector matches the calldata.
  let chosen = null;
  for (const c of candidates) {
    if (formatKeyToSelector(c.formatKey) === selector) {
      chosen = c;
      break;
    }
  }

  if (!chosen) {
    // Last resort: look the selector up in the bundled 4byte dict and
    // render a "signature-only" decode. No intent, no token metadata, but
    // the user at least sees what arguments are being passed instead of
    // raw hex. This is strictly better UX than "unknown contract" for the
    // long tail of contracts that don't have an ERC-7730 descriptor.
    const fallbackSig = registry.fallback?.get(selector);
    if (fallbackSig) {
      try {
        const decoded = decodeCalldata(fallbackSig, data);
        const structured = buildStructuredRoot(fallbackSig, decoded.args);
        const fields = Object.entries(structured)
          // Skip the positional index aliases ("0", "1", ...) so we render
          // each arg once under its named form.
          .filter(([k]) => /^[A-Za-z_]/.test(k))
          .map(([k, v]) => ({
            label: k,
            formatter: "raw",
            raw: jsonSafeArg(v),
            formatted: renderRaw(v),
          }));
        return {
          matched: true,
          partial: true,
          source: "4byte.json",
          contractName: null,
          owner: null,
          function: fallbackSig,
          intent: null,
          selector,
          fields,
          warning: "no ERC-7730 descriptor; arguments decoded by signature only",
        };
      } catch (e) {
        // fall through to the unmatched response
      }
    }
    return {
      matched: false,
      reason: depDescriptor
        ? `descriptor for ${depKey} has no format with selector ${selector}`
        : `no descriptor in registry matches (chainId=${chainId}, to=${to}) or selector ${selector}`,
      selector,
    };
  }

  let decoded;
  try {
    decoded = decodeCalldata(chosen.formatKey, data);
  } catch (e) {
    return {
      matched: true,
      partial: true,
      contractName:
        chosen.descriptor?.metadata?.contractName ??
        chosen.descriptor?.context?.$id ??
        null,
      owner: chosen.descriptor?.metadata?.owner ?? null,
      function: chosen.formatKey,
      intent: chosen.formatSpec.intent ?? null,
      selector,
      error: `calldata decode failed: ${e?.message ?? e}`,
    };
  }

  const structured = buildStructuredRoot(chosen.formatKey, decoded.args);

  // Daemon may inject a `tokenMetadata` map: { "0xaddr": {decimals,symbol} }.
  // Addresses are lowercased keys. The tokenAmount formatter consults this
  // before falling back to descriptor.metadata.token / address-tag display.
  const tokenMetadata = (req.tokenMetadata && typeof req.tokenMetadata === "object")
    ? Object.fromEntries(
        Object.entries(req.tokenMetadata).map(([k, v]) => [k.toLowerCase(), v]),
      )
    : {};

  // Daemon may inject an `ensNames` map: { "0x<namehash>": "vitalik.eth" }.
  // The `ensName` formatter consults this when rendering bytes32 node
  // arguments on PublicResolver calls. If the daemon hasn't populated the
  // map (or the namehash isn't in it), the formatter falls back to short
  // hex — NEVER to a wrong name. Wallet logic doesn't rely on this map.
  const ensNames = (req.ensNames && typeof req.ensNames === "object")
    ? Object.fromEntries(
        Object.entries(req.ensNames).map(([k, v]) => [k.toLowerCase(), v]),
      )
    : {};

  const ctx = {
    descriptor: chosen.descriptor,
    structured,
    container: { chainId, to, value, from: req.from ?? null },
    tokenMetadata,
    ensNames,
    // Threaded through so the `calldata` formatter can recursively decode
    // each element of a `multicall(bytes[])` against the same descriptor
    // set. Inner calls in a multicall execute via `delegatecall` from the
    // outer `to`, so we reuse {chainId, to} for the recursive lookup.
    registry,
  };

  const fields = (chosen.formatSpec.fields ?? []).map((f) =>
    formatField(f, ctx),
  );

  // Surface token identity for ERC-20-shaped descriptors. When a field
  // declares `format: "tokenAmount"` with `tokenPath: "@.to"`, the
  // contract being called IS the token, and the user otherwise has no
  // way to see "this approve is for WETH" — descriptor field rows only
  // expose function arguments (spender, value), not the to-address.
  // Resolve symbol/decimals from the daemon-fetched tokenMetadata when
  // available; fall back to address-only so the TUI always renders the
  // token contract, even on a cold cache.
  const tokenInfo = deriveTokenInfo(chosen.formatSpec, to, tokenMetadata);

  return {
    matched: true,
    partial: false,
    contractName:
      chosen.descriptor?.metadata?.contractName ??
      chosen.descriptor?.context?.$id ??
      null,
    owner: chosen.descriptor?.metadata?.owner ?? null,
    source: chosen.descriptor.__source,
    function: chosen.formatKey,
    intent: chosen.formatSpec.intent ?? null,
    selector,
    fields,
    tokenInfo,
  };
}

// Return `{ address, symbol?, decimals? }` when the descriptor's fields
// indicate the call-target IS the token contract (tokenAmount + tokenPath
// "@.to"). Otherwise null. Symbol/decimals come from the daemon-injected
// tokenMetadata map; address-only is still a useful render — the user
// sees they're poking 0xfff9…6b14 instead of being shown only "Spender"
// and "Amount" with no token context. The wallet does not trust this
// for signing; ConfirmGate displays it for human review.
function deriveTokenInfo(formatSpec, to, tokenMetadata) {
  if (!to) return null;
  const fields = formatSpec?.fields ?? [];
  const usesSelfToken = fields.some(
    (f) =>
      f?.format === "tokenAmount" &&
      typeof f?.params?.tokenPath === "string" &&
      f.params.tokenPath === "@.to",
  );
  if (!usesSelfToken) return null;
  const lookup = tokenMetadata?.[to.toLowerCase()] ?? null;
  return {
    address: to,
    symbol: typeof lookup?.symbol === "string" ? lookup.symbol : null,
    decimals: typeof lookup?.decimals === "number" ? lookup.decimals : null,
  };
}

// JSON-safe rendering for fallback fields (BigInt, Uint8Array, nested).
function jsonSafeArg(v) {
  if (typeof v === "bigint") return "0x" + v.toString(16);
  if (v instanceof Uint8Array) return "0x" + Buffer.from(v).toString("hex");
  if (Array.isArray(v)) return v.map(jsonSafeArg);
  if (v && typeof v === "object") {
    const out = {};
    for (const [k, val] of Object.entries(v)) out[k] = jsonSafeArg(val);
    return out;
  }
  return v;
}

function renderRaw(v) {
  if (v === undefined || v === null) return "(empty)";
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "string") return v;
  if (v instanceof Uint8Array) return "0x" + Buffer.from(v).toString("hex");
  try {
    return JSON.stringify(v, (_k, x) => {
      if (typeof x === "bigint") return "0x" + x.toString(16);
      if (x instanceof Uint8Array) return "0x" + Buffer.from(x).toString("hex");
      return x;
    });
  } catch {
    return String(v);
  }
}

// Parse the format key via viem to extract input names + positions, then
// expose each arg under its declared name (e.g. "to", "value", "params")
// so descriptor paths address them directly. viem also resolves nested
// tuples — for `(address tokenIn,…) params`, the outer parameter is named
// `params` and viem already returns the inner components as an object
// keyed by component name (so `params.tokenIn` resolves correctly).
function buildStructuredRoot(formatKey, args) {
  let item;
  try {
    item = parseAbiItem(`function ${formatKey}`);
  } catch {
    return {};
  }
  const inputs = item?.inputs ?? [];
  const root = {};
  for (let i = 0; i < inputs.length; i++) {
    const name = inputs[i]?.name || `arg${i}`;
    root[name] = args[i];
    root[String(i)] = args[i];
  }
  return root;
}
