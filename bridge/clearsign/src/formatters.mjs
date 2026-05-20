// ERC-7730 formatters — render raw decoded values into user-facing strings.
//
// Implemented: tokenAmount, addressName, amount, date, raw, enum, calldata.
// Not implemented (Phase 2+): nftName, duration, percentage. Unknown
// formatters fall back to "raw".
import { getAddress } from "viem";
import { resolvePath } from "./paths.mjs";
// `calldata` formatter recursively decodes each `bytes[]` element against
// the same descriptor set. Import is at top level — ESM handles the cycle
// with decoder.mjs because `decodeTxIntent` is only invoked at call time,
// not at module init time.
import { decodeTxIntent } from "./decoder.mjs";

const ETHER_DECIMALS = 18;

export function formatField(field, ctx) {
  const raw = resolvePath(field.path, ctx);
  const fmt = field.format ?? "raw";
  const params = field.params ?? {};
  let formatted;
  try {
    formatted = renderValue(fmt, raw, params, ctx);
  } catch (e) {
    formatted = `(formatter ${fmt} failed: ${e?.message ?? e})`;
  }
  return {
    label: field.label ?? field.path,
    formatter: fmt,
    raw: jsonSafe(raw),
    formatted,
  };
}

function renderValue(formatter, raw, params, ctx) {
  switch (formatter) {
    case "addressName":
      return formatAddress(raw, params, ctx);
    case "tokenAmount":
      return formatTokenAmount(raw, params, ctx);
    case "amount":
      return formatNativeAmount(raw);
    case "date":
      return formatDate(raw, params);
    case "enum":
      return formatEnumValue(raw, params, ctx);
    case "calldata":
      return formatCalldataArray(raw, params, ctx);
    case "raw":
    default:
      return formatRaw(raw);
  }
}

function formatAddress(raw, params, ctx) {
  if (typeof raw !== "string") return formatRaw(raw);
  let checksum;
  try {
    checksum = getAddress(raw);
  } catch {
    return raw;
  }
  const tokenMeta = ctx.descriptor?.metadata?.token;
  if (tokenMeta?.name && ctx.container?.to?.toLowerCase() === checksum.toLowerCase()) {
    return `${tokenMeta.name} (${shortAddr(checksum)})`;
  }
  return checksum;
}

function formatTokenAmount(raw, params, ctx) {
  const amount = bigintFromAny(raw);
  if (amount === null) return formatRaw(raw);

  let decimals = ETHER_DECIMALS;
  let ticker = "";

  // Resolution priority for token metadata, most-specific first:
  //   1. ctx.tokenMetadata[<addr>] — daemon-fetched eth_call(decimals/symbol).
  //      Authoritative, fresh, and works for arbitrary tokens.
  //   2. descriptor.metadata.token — pre-baked into the ERC-7730 file. Used
  //      when the registry vendors a per-token descriptor.
  //   3. Short-address tag — graceful fallback when neither is available.
  if (params.tokenPath) {
    const tokenAddr = resolvePath(params.tokenPath, ctx);
    const lowAddr = typeof tokenAddr === "string" ? tokenAddr.toLowerCase() : null;
    const fromDaemon = lowAddr ? ctx.tokenMetadata?.[lowAddr] : null;

    if (fromDaemon && typeof fromDaemon.decimals === "number") {
      decimals = fromDaemon.decimals;
      ticker = fromDaemon.symbol ?? "";
    } else {
      const descMeta = ctx.descriptor?.metadata?.token;
      if (descMeta) {
        decimals = descMeta.decimals ?? ETHER_DECIMALS;
        ticker = descMeta.ticker ?? "";
      } else if (typeof tokenAddr === "string") {
        ticker = `[${shortAddr(tokenAddr)}]`;
      }
    }
  }

  const display = formatBigIntWithDecimals(amount, decimals);
  return ticker ? `${display} ${ticker}` : display;
}

function formatNativeAmount(raw) {
  const amount = bigintFromAny(raw);
  if (amount === null) return formatRaw(raw);
  return `${formatBigIntWithDecimals(amount, ETHER_DECIMALS)} ETH`;
}

function formatDate(raw, params) {
  const v = bigintFromAny(raw);
  if (v === null) return formatRaw(raw);
  const enc = params.encoding ?? "timestamp";
  if (enc === "timestamp") {
    const d = new Date(Number(v) * 1000);
    return Number.isNaN(d.getTime()) ? formatRaw(raw) : d.toISOString();
  }
  return `block #${v}`;
}

function formatEnumValue(raw, params, ctx) {
  const enums = ctx.descriptor?.metadata?.enums;
  if (!enums || !params?.$ref) return formatRaw(raw);
  const m = /^\$\.metadata\.enums\.(.+)$/.exec(params.$ref);
  if (!m) return formatRaw(raw);
  const map = enums[m[1]];
  if (!map) return formatRaw(raw);
  return map[String(raw)] ?? formatRaw(raw);
}

// Render a `bytes[]` argument by recursively decoding each element against
// the same descriptor registry. Used for `multicall(bytes[])` — without it,
// ETH↔token Uniswap V3 swaps (which wrap exactInputSingle + refundETH /
// unwrapWETH9 in a multicall) render as raw hex.
//
// Inner calls of a router-side multicall execute via delegatecall, so they
// target the same (chainId, to). We reuse the outer container's tokenMetadata
// so per-token decimals/symbol resolved by the daemon still apply.
function formatCalldataArray(raw, _params, ctx) {
  if (!Array.isArray(raw)) return formatRaw(raw);
  if (raw.length === 0) return "(empty)";
  const registry = ctx.registry;
  const chainId = ctx.container?.chainId;
  const to = ctx.container?.to;
  const tokenMetadata = ctx.tokenMetadata ?? {};
  const out = [`${raw.length} call${raw.length === 1 ? "" : "s"}:`];
  for (let i = 0; i < raw.length; i++) {
    const sub = renderInnerCall(raw[i], { registry, chainId, to, tokenMetadata });
    // sub is `{ head: string, fields: [{label, formatted}] }`. Render the
    // header line with the `[i]` tag and each field on its own indented
    // line. The ConfirmGate renders this whole string under one `Text`
    // node, so `\n` inside is honored by Ink.
    out.push(`  [${i}] ${sub.head}`);
    const labelWidth = Math.max(0, ...sub.fields.map((f) => f.label.length));
    for (const f of sub.fields) {
      out.push(`        ${(f.label + ":").padEnd(labelWidth + 2)} ${f.formatted}`);
    }
  }
  return out.join("\n");
}

function renderInnerCall(element, { registry, chainId, to, tokenMetadata }) {
  const hex = toCalldataHex(element);
  if (!hex || hex.length < 10) return { head: `(too short: ${hex || "0x"})`, fields: [] };
  if (!registry) return { head: `${hex.slice(0, 10)} (registry unavailable)`, fields: [] };
  try {
    const r = decodeTxIntent(
      { chainId, to, value: "0x0", data: hex, tokenMetadata },
      registry,
    );
    if (r.matched) {
      return {
        head: r.intent ?? r.function ?? r.selector ?? "(matched)",
        fields: (r.fields ?? []).map((f) => ({ label: f.label, formatted: f.formatted })),
      };
    }
    return { head: `${hex.slice(0, 10)} (no descriptor)`, fields: [] };
  } catch (e) {
    return { head: `${hex.slice(0, 10)} (decode error: ${e?.message ?? e})`, fields: [] };
  }
}

function toCalldataHex(v) {
  if (typeof v === "string") return v.startsWith("0x") ? v : `0x${v}`;
  if (v instanceof Uint8Array) return "0x" + Buffer.from(v).toString("hex");
  return "0x";
}

function formatRaw(raw) {
  if (raw === undefined || raw === null) return "(empty)";
  if (typeof raw === "bigint") return raw.toString();
  if (typeof raw === "string") return raw;
  if (raw instanceof Uint8Array) return "0x" + Buffer.from(raw).toString("hex");
  try {
    return JSON.stringify(raw, jsonReplacer);
  } catch {
    return String(raw);
  }
}

function bigintFromAny(raw) {
  if (typeof raw === "bigint") return raw;
  if (typeof raw === "number" && Number.isFinite(raw)) return BigInt(raw);
  if (typeof raw === "string" && /^(0x[0-9a-fA-F]+|\d+)$/.test(raw)) {
    return BigInt(raw);
  }
  return null;
}

function formatBigIntWithDecimals(v, decimals) {
  const negative = v < 0n;
  const abs = negative ? -v : v;
  const scale = 10n ** BigInt(decimals);
  const whole = abs / scale;
  const frac = abs % scale;
  if (frac === 0n) return `${negative ? "-" : ""}${whole.toString()}`;
  const fracStr = frac.toString().padStart(decimals, "0").replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole.toString()}.${fracStr}`;
}

function shortAddr(a) {
  if (typeof a !== "string" || a.length < 12) return a;
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

function jsonReplacer(_k, v) {
  if (typeof v === "bigint") return "0x" + v.toString(16);
  if (v instanceof Uint8Array) return "0x" + Buffer.from(v).toString("hex");
  return v;
}

function jsonSafe(v) {
  if (typeof v === "bigint") return "0x" + v.toString(16);
  if (v instanceof Uint8Array) return "0x" + Buffer.from(v).toString("hex");
  if (Array.isArray(v)) return v.map(jsonSafe);
  if (v && typeof v === "object") {
    const out = {};
    for (const [k, val] of Object.entries(v)) out[k] = jsonSafe(val);
    return out;
  }
  return v;
}
