// Walk a debug_traceCall (callTracer + withLog) tree and pull out ERC-20
// transfers. The trace shape is recursive — top-level call has `calls?: []`
// and each call has `logs?: []`. Logs with topic[0] = the canonical Transfer
// event signature carry {token = log.address, from = topics[1], to = topics[2],
// amount = data}. Addresses in topics are right-padded 32-byte words; we
// extract the trailing 20 bytes.

const ERC20_TRANSFER_TOPIC =
  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

export type ParsedTransfer = {
  token: string;
  from: string;
  to: string;
  amount: bigint;
};

export function parseTransfers(trace: any): ParsedTransfer[] {
  const transfers: ParsedTransfer[] = [];
  walk(trace, transfers);
  return transfers;
}

function walk(node: any, acc: ParsedTransfer[]): void {
  if (!node || typeof node !== "object") return;
  if (Array.isArray(node.logs)) {
    for (const log of node.logs) {
      const t = parseTransferLog(log);
      if (t) acc.push(t);
    }
  }
  if (Array.isArray(node.calls)) {
    for (const child of node.calls) walk(child, acc);
  }
}

function parseTransferLog(log: any): ParsedTransfer | null {
  if (!log || typeof log !== "object") return null;
  const topics: string[] = Array.isArray(log.topics) ? log.topics : [];
  if (topics.length < 3) return null;
  if ((topics[0] ?? "").toLowerCase() !== ERC20_TRANSFER_TOPIC) return null;
  const token = typeof log.address === "string" ? log.address : null;
  const from = topicToAddress(topics[1]);
  const to = topicToAddress(topics[2]);
  if (!token || !from || !to) return null;
  let amount = 0n;
  try {
    amount = BigInt(log.data ?? "0x0");
  } catch {
    amount = 0n;
  }
  return { token, from, to, amount };
}

// 32-byte topic word → checksummed-ish 20-byte address (lowercased here;
// the renderer can re-checksum if it cares).
function topicToAddress(word: unknown): string | null {
  if (typeof word !== "string" || !word.startsWith("0x")) return null;
  if (word.length !== 66) return null;
  return "0x" + word.slice(26).toLowerCase();
}
