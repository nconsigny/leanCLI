// Ported from kassandraoftroy/kohaku-cli src/host/chunked-get-logs.ts.
// Why: PP plugin sync calls eth_getLogs over huge ranges; most RPCs reject
// or stall. We wrap the provider so every getLogs fans out into fixed
// inclusive windows (default 499 blocks; override via env).

const DEFAULT_MAX_BLOCK_SPAN = 499n;

function logGetLogsChunkFailure(path, label, from, to, err) {
  const message = err instanceof Error ? err.message : String(err);
  console.error("[kohaku:getlogs]", path, `chunk ${label} failed`, {
    from: from.toString(),
    to: to.toString(),
    message,
  });
  if (err instanceof Error && err.cause !== undefined) {
    console.error("[kohaku:getlogs]", "cause:", err.cause);
  }
}

function parseEnvMaxBlockSpan() {
  const raw = process.env.KOHAKU_GETLOGS_MAX_BLOCK_SPAN?.trim();
  if (!raw) return null;
  try {
    const n = BigInt(raw);
    return n > 0n ? n : null;
  } catch {
    return null;
  }
}

function resolveMaxBlockSpan() {
  return parseEnvMaxBlockSpan() ?? DEFAULT_MAX_BLOCK_SPAN;
}

function toRpcBlockQuantity(n) {
  if (n < 0n) throw new Error("block number must be non-negative");
  if (n === 0n) return "0x0";
  return `0x${n.toString(16)}`;
}

function blockSpecToBigInt(value) {
  if (value === undefined || value === null) return null;
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isFinite(value)) {
    const t = Math.trunc(value);
    if (t < 0 || !Number.isSafeInteger(t)) return null;
    return BigInt(t);
  }
  if (typeof value === "string") {
    if (
      value === "latest" || value === "pending" || value === "earliest" ||
      value === "safe" || value === "finalized"
    ) return null;
    if (value.startsWith("0x") || value.startsWith("0X")) {
      try { return BigInt(value); } catch { return null; }
    }
    if (/^\d+$/.test(value)) {
      try { return BigInt(value); } catch { return null; }
    }
  }
  return null;
}

function asLogArray(result) {
  if (Array.isArray(result)) return result;
  throw new Error(`expected eth_getLogs result to be an array, got ${typeof result}`);
}

async function fetchLogsChunked(path, fromBn, toBn, chunkSpan, invoke) {
  const out = [];
  let windowFrom = fromBn;
  let w = 0;
  while (windowFrom <= toBn) {
    const windowTo =
      windowFrom + chunkSpan - 1n > toBn ? toBn : windowFrom + chunkSpan - 1n;
    w += 1;
    let raw;
    try {
      raw = await invoke(windowFrom, windowTo);
    } catch (e) {
      logGetLogsChunkFailure(path, `#${w}`, windowFrom, windowTo, e);
      throw e;
    }
    out.push(...asLogArray(raw));
    windowFrom = windowTo + 1n;
  }
  return out;
}

export function withChunkedGetLogs(provider) {
  const chunkSpan = resolveMaxBlockSpan();
  const baseGetLogs = provider.getLogs.bind(provider);
  const baseRequest = provider.request.bind(provider);

  return {
    ...provider,
    getLogs: async (filter) => {
      const fromBn = blockSpecToBigInt(filter.fromBlock);
      const toBn = blockSpecToBigInt(filter.toBlock);
      if (fromBn === null || toBn === null || fromBn > toBn) {
        return baseGetLogs(filter);
      }
      const merged = await fetchLogsChunked(
        "getLogs", fromBn, toBn, chunkSpan,
        (from, to) => baseGetLogs({ ...filter, fromBlock: from, toBlock: to }),
      );
      return merged;
    },
    request: async (req) => {
      if (req.method !== "eth_getLogs") return baseRequest(req);
      const params = req.params;
      if (!Array.isArray(params) || params.length < 1) return baseRequest(req);
      const rawFilter = params[0];
      if (rawFilter === null || typeof rawFilter !== "object") return baseRequest(req);
      const fromBn = blockSpecToBigInt(rawFilter.fromBlock);
      const toBn = blockSpecToBigInt(rawFilter.toBlock);
      if (fromBn === null || toBn === null || fromBn > toBn) return baseRequest(req);
      return fetchLogsChunked(
        "request.eth_getLogs", fromBn, toBn, chunkSpan,
        (from, to) => baseRequest({
          method: "eth_getLogs",
          params: [{
            ...rawFilter,
            fromBlock: toRpcBlockQuantity(from),
            toBlock: toRpcBlockQuantity(to),
          }],
        }),
      );
    },
  };
}
