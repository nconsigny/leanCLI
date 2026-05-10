/** Format a wei amount as ETH with up to 18 trimmed decimals. */
export function formatEth(wei: bigint): string {
  const negative = wei < 0n;
  const abs = negative ? -wei : wei;
  const whole = abs / 10n ** 18n;
  const frac = abs % 10n ** 18n;
  if (frac === 0n) return `${negative ? "-" : ""}${whole} ETH`;
  const fracStr = frac.toString().padStart(18, "0").replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}.${fracStr} ETH`;
}

/** Compact ETH formatter for dense list rows. Caps at `decimals` fractional
 *  digits (default 6) so wallet rows fit half-screen without wrapping. The
 *  full-precision `formatEth` is still used wherever a user might verify
 *  amounts before signing. */
export function formatEthCompact(wei: bigint, decimals: number = 6): string {
  const negative = wei < 0n;
  const abs = negative ? -wei : wei;
  const whole = abs / 10n ** 18n;
  const frac = abs % 10n ** 18n;
  if (frac === 0n) return `${negative ? "-" : ""}${whole} ETH`;
  const padded = frac.toString().padStart(18, "0");
  const trimmed = padded.slice(0, decimals).replace(/0+$/, "");
  return trimmed.length === 0
    ? `${negative ? "-" : ""}${whole} ETH`
    : `${negative ? "-" : ""}${whole}.${trimmed} ETH`;
}

/** Short chain label for compact list rows. Falls back to the first 4 chars
 *  of an unknown chain name. */
export function shortChain(chain: string): string {
  if (chain === "sepolia") return "sep";
  if (chain === "mainnet") return "main";
  if (chain === "holesky") return "hol";
  return chain.slice(0, 4);
}

/** Decode a `0x`-prefixed hex string to bigint. Returns 0n on bad input. */
export function hexToBigInt(hex: string | undefined | null): bigint {
  if (!hex) return 0n;
  const body = hex.startsWith("0x") || hex.startsWith("0X") ? hex.slice(2) : hex;
  if (body.length === 0) return 0n;
  try {
    return BigInt("0x" + body);
  } catch {
    return 0n;
  }
}

/** Render an Ethereum address. Always returns the full 0x… string —
 *  signing flows must surface the entire 20-byte value so users can
 *  verify it character-by-character before approving. The legacy
 *  `0xAa65…C02C` shorthand was removed everywhere on request. */
export function shortAddr(addr: string): string {
  return addr;
}
