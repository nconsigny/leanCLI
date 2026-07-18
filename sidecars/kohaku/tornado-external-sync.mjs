// Host ExternalSyncProvider backed by the FAT Solutions "saga" CDN.
//
// Tornado Cash cold-sync reads bulk historical Deposit/Withdrawal logs from
// this CDN instead of scanning every block via eth_getLogs, which on mainnet
// would be prohibitively slow inside a one-shot bridge invocation. The plugin
// uses this provider for the bulk of a range when a pool is more than
// `minExternalSyncBlocksAmount` blocks behind head, then fetches the recent
// tail from the chain.
//
// SECURITY: this is a convenience/perf source only. The CDN is UNTRUSTED — the
// tornado plugin re-derives commitments and proves inclusion against the pool's
// on-chain merkle root, so a lying CDN can at worst make sync fail, never forge
// a spendable note. A fetch failure here degrades to chain-only sync.
//
// Ported from kohaku-cli src/utils/saga-external-sync.ts (plain JS, no types).

import { createGunzip } from "node:zlib";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

/** CDN base URL for historical event sync (mainnet vs Sepolia). */
export function sagaBaseUrlForChain(chainId) {
  return BigInt(chainId) === 11155111n
    ? "https://saga.fatsolutions.xyz/sepolia"
    : "https://saga.fatsolutions.xyz";
}

function normalizeAddress(address) {
  return address.toLowerCase();
}

function hexToBigInt(hex) {
  return BigInt(hex);
}

function inclusiveLastBlock(chunk) {
  return hexToBigInt(chunk.toBlock) - 1n;
}

function collectSegments(entry) {
  const segments = [...(entry.chunks ?? [])];
  if (entry.hotHead) segments.push(entry.hotHead);
  return segments.sort(
    (a, b) =>
      Number(hexToBigInt(a.fromBlock) - hexToBigInt(b.fromBlock)) ||
      Number(hexToBigInt(a.toBlock) - hexToBigInt(b.toBlock)),
  );
}

async function loadIndex(network, baseUrl) {
  const res = await network.fetch(`${baseUrl}/index.json`);
  if (!res.ok) {
    throw new Error(`Saga index fetch failed (${res.status}): ${baseUrl}/index.json`);
  }
  return await res.json();
}

function findProtocolEntry(index, params) {
  const chainId = params.chainId.toLowerCase();
  const address = normalizeAddress(params.address);
  return Object.values(index.availableProtocols).find(
    (entry) =>
      entry.chainId.toLowerCase() === chainId &&
      entry.trackedAddresses.some((a) => a.toLowerCase() === address),
  );
}

async function readGunzipLines(network, url) {
  const res = await network.fetch(url);
  if (!res.ok) {
    throw new Error(`Saga chunk fetch failed (${res.status}): ${url}`);
  }
  const buf = Buffer.from(await res.arrayBuffer());
  const lines = [];
  const gunzip = createGunzip();
  const source = Readable.from(buf);
  let pending = "";
  gunzip.on("data", (chunk) => {
    pending += chunk.toString("utf8");
    let idx = pending.indexOf("\n");
    while (idx >= 0) {
      const line = pending.slice(0, idx).trim();
      if (line) lines.push(line);
      pending = pending.slice(idx + 1);
      idx = pending.indexOf("\n");
    }
  });
  await pipeline(source, gunzip);
  const tail = pending.trim();
  if (tail) lines.push(tail);
  return lines;
}

export function createSagaExternalSyncProvider(opts) {
  let indexPromise = null;

  const getIndex = () => {
    indexPromise ??= loadIndex(opts.network, opts.baseUrl);
    return indexPromise;
  };

  const getEntry = async (params) => {
    const entry = findProtocolEntry(await getIndex(), params);
    if (!entry) {
      throw new Error(
        `Saga has no protocol data for chain ${params.chainId} address ${params.address}`,
      );
    }
    return entry;
  };

  return {
    async firstCoveredBlock(params) {
      const segments = collectSegments(await getEntry(params));
      if (segments.length === 0) {
        throw new Error(
          `Saga has no segments for chain ${params.chainId} address ${params.address}`,
        );
      }
      const first = segments.reduce((min, seg) => {
        const from = hexToBigInt(seg.fromBlock);
        return from < min ? from : min;
      }, hexToBigInt(segments[0].fromBlock));
      return `0x${first.toString(16)}`;
    },

    async lastCoveredBlock(params) {
      const segments = collectSegments(await getEntry(params));
      if (segments.length === 0) return null;
      const last = segments.reduce((max, seg) => {
        const end = inclusiveLastBlock(seg);
        return end > max ? end : max;
      }, inclusiveLastBlock(segments[0]));
      return `0x${last.toString(16)}`;
    },

    async *streamEvents(params) {
      const entry = await getEntry(params);
      const fromBlock = hexToBigInt(params.fromBlock);
      const toBlock = hexToBigInt(params.toBlock);
      const segments = collectSegments(entry).filter((seg) => {
        const segFrom = hexToBigInt(seg.fromBlock);
        const segLast = inclusiveLastBlock(seg);
        return segFrom <= toBlock && segLast >= fromBlock;
      });

      const out = [];
      for (const seg of segments) {
        const url = `${opts.baseUrl}/${seg.file}`;
        const lines = await readGunzipLines(opts.network, url);
        for (const line of lines) {
          let parsed;
          try {
            parsed = JSON.parse(line);
          } catch {
            continue;
          }
          const block = hexToBigInt(parsed.blockNumber);
          if (block < fromBlock || block > toBlock) continue;
          out.push(parsed);
        }
      }

      out.sort((a, b) => {
        const blockCmp = Number(hexToBigInt(a.blockNumber) - hexToBigInt(b.blockNumber));
        if (blockCmp !== 0) return blockCmp;
        return Number(hexToBigInt(a.logIndex) - hexToBigInt(b.logIndex));
      });

      for (const event of out) {
        yield event;
      }
    },
  };
}

export function tornadoExternalSyncForChain(chainId, network) {
  return createSagaExternalSyncProvider({
    baseUrl: sagaBaseUrlForChain(chainId),
    network,
  });
}
