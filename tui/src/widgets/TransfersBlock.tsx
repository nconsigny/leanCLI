import React from "react";
import { Box, Text } from "ink";
import { theme } from "../theme.js";
import { parseTransfers, ParsedTransfer } from "../format/transfers.js";

/** Render a "tokens that move" panel from a tx.simulate response.
 *
 *  Hierarchy:
 *  - sim.trace present  → walk the call tree, render parsed transfers.
 *  - sim.traceUnavailable → friendly note explaining the RPC doesn't expose
 *    debug_traceCall.
 *  - neither            → render nothing (caller didn't request a trace). */
export function TransfersBlock({ sim }: { sim: any }) {
  if (!sim) return null;

  if (sim.traceUnavailable) {
    return (
      <Text color={theme.dim}>
        token-flow trace: unavailable on this RPC
      </Text>
    );
  }

  if (!sim.trace) return null;

  const transfers = parseTransfers(sim.trace);
  if (transfers.length === 0) {
    return <Text color={theme.dim}>token-flow trace: no ERC-20 transfers</Text>;
  }

  // Daemon-side `tx.simulate` walks the trace and prefetches metadata for
  // every Transfer-emitting token, returning `tokenMetadata: {addr: {decimals, symbol}}`
  // (lowercased keys). We pass it straight to the renderer.
  const tokenMeta: Record<string, { decimals: number; symbol: string }> =
    sim.tokenMetadata && typeof sim.tokenMetadata === "object"
      ? sim.tokenMetadata
      : {};

  return (
    <Box flexDirection="column">
      <Text color={theme.dim}>token movements ({transfers.length}):</Text>
      {transfers.map((t, i) => (
        <Text key={i}>
          {"  "}
          <Text color={theme.dim}>{shortAddr(t.from)}</Text>
          <Text> → </Text>
          <Text color={theme.dim}>{shortAddr(t.to)}</Text>
          <Text> {formatAmount(t, tokenMeta)} </Text>
          <Text color={theme.dim}>[{describeToken(t.token, tokenMeta)}]</Text>
        </Text>
      ))}
    </Box>
  );
}

function shortAddr(a: string): string {
  // Signing-time displays must show the full address — see `format.ts`.
  return typeof a === "string" ? a : String(a ?? "");
}

function metaFor(addr: string, tokenMeta: Record<string, { decimals: number; symbol: string }>) {
  return tokenMeta[addr.toLowerCase()];
}

function describeToken(addr: string, tokenMeta: Record<string, { decimals: number; symbol: string }>): string {
  const m = metaFor(addr, tokenMeta);
  return m?.symbol ? m.symbol : shortAddr(addr);
}

function formatAmount(
  t: ParsedTransfer,
  tokenMeta: Record<string, { decimals: number; symbol: string }>,
): string {
  const m = metaFor(t.token, tokenMeta);
  if (!m || typeof m.decimals !== "number") return t.amount.toString();
  const negative = t.amount < 0n;
  const abs = negative ? -t.amount : t.amount;
  const scale = 10n ** BigInt(m.decimals);
  const whole = abs / scale;
  const frac = abs % scale;
  if (frac === 0n) return `${negative ? "-" : ""}${whole}`;
  const fracStr = frac.toString().padStart(m.decimals, "0").replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}.${fracStr}`;
}
