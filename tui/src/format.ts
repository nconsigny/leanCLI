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

/** Decode a `0x`-prefixed hex string to bigint. Returns 0n on bad input.
 *  Widened to `unknown` because daemon responses occasionally surface a
 *  non-string in the balance field (observed on mainnet via Colibri); the
 *  previous `if (!hex)` guard let truthy non-strings through and crashed
 *  WalletsHub with "hex.startsWith is not a function". */
export function hexToBigInt(hex: unknown): bigint {
  if (typeof hex !== "string" || hex.length === 0) return 0n;
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

/** Parse a decimal-ETH string ("0", "0.001") to wei (bigint). Returns
 *  null on bad input. Mirrors the daemon's `LeanCli.Util.Units.parseUnits`
 *  so the TUI can compute value-hex for `tx.simulate` before any signing
 *  RPC round-trips. */
export function parseEthToWei(s: string): bigint | null {
  const t = s.trim();
  if (!/^[0-9]+(\.[0-9]+)?$/.test(t)) return null;
  const [whole = "0", frac = ""] = t.split(".");
  if (frac.length > 18) return null;
  const padded = (frac + "0".repeat(18)).slice(0, 18);
  try { return BigInt(whole) * 10n ** 18n + BigInt(padded || "0"); }
  catch { return null; }
}

/** bigint → '0x'-prefixed hex (no leading zeros, '0x0' for zero). */
export function bigIntToHex(n: bigint): string {
  return "0x" + n.toString(16);
}

/** Honest "source" line for a simulation panel, derived from the daemon's
 *  `_verification` verdict — which backend actually executed the sim and the
 *  block height proven against. Never claims verification for a raw-RPC sim:
 *  the badge must reflect what was cryptographically checked, not merely
 *  which backend the request was routed to. Shared by every confirm screen
 *  (SendRaw / Send / DecodeIntent) so the wording can't drift between them. */
export function verificationSourceLine(sim: any): string {
  const v = sim?._verification;
  const blk = v?.provenAtBlock;
  const at =
    blk != null
      ? ` @ block ${typeof blk === "string" && blk.startsWith("0x") ? parseInt(blk, 16) : blk}`
      : "";
  if (v?.verifiedBy === "helios")
    return `eth_call + eth_estimateGas via Helios — consensus-verified REVM${at}`;
  if (v?.verifiedBy === "colibri")
    return `eth_call + eth_estimateGas via Colibri — committee-verified${v?.verified ? "" : " (proof unconfirmed)"}${at}`;
  return "eth_call + eth_estimateGas on the configured RPC endpoint — UNVERIFIED (untrusted execution node)";
}

/* ---------- approvals-audit rendering ---------- */

export type ApprovalAuditData = {
  wallet?: string;
  approvals: Array<{
    token: string; spender: string; amount?: string; amountHuman?: string;
    tokenSymbol?: string; spenderLabel?: string; lastSeenBlock?: number;
  }>;
  nftApprovals?: Array<{
    token: string; operator: string; tokenSymbol?: string;
    operatorLabel?: string; lastSeenBlock?: number;
  }>;
  permit2Approvals?: Array<{
    token: string; spender: string; amount?: string; amountHuman?: string;
    tokenSymbol?: string; spenderLabel?: string; expiration?: number;
  }>;
};

export type ApprovalRow = { text: string; warn: boolean };

/** Format an approvals audit as aligned single-line rows, riskiest first:
 *  unlimited ERC-20 grants and NFT operator approvals carry a ⚠ and sort
 *  to the top; bounded grants follow. Spenders render as their protocol
 *  label (daemon-side table), as "your <name>" when they're one of the
 *  user's own wallets, or as a short address. Shared by the in-pane chat
 *  and the full chat so the two renderings can't drift. */
export function approvalAuditRows(
  d: ApprovalAuditData,
  wallets: Array<{ name: string; address: string }> = [],
): ApprovalRow[] {
  const who = (addr: string, label?: string): string => {
    const w = wallets.find((x) => x.address.toLowerCase() === addr.toLowerCase());
    if (w) return `your ${w.name}`;
    return label ?? shortAddr(addr);
  };
  const unlimited = (h?: string) => (h ?? "").startsWith("unlimited");
  const sym = (s?: string, addr?: string) => (s || shortAddr(addr ?? "")).padEnd(8);
  const rows: ApprovalRow[] = [];
  const erc20 = [...d.approvals].sort(
    (a, b) => (unlimited(a.amountHuman) ? 0 : 1) - (unlimited(b.amountHuman) ? 0 : 1),
  );
  for (const a of erc20) {
    const warn = unlimited(a.amountHuman);
    rows.push({
      warn,
      text: `${warn ? "⚠" : " "} ${sym(a.tokenSymbol, a.token)} → ${who(a.spender, a.spenderLabel).padEnd(32)} ${a.amountHuman || a.amount || "?"}`,
    });
  }
  for (const n of d.nftApprovals ?? []) {
    rows.push({
      warn: true,
      text: `⚠ ${sym(n.tokenSymbol, n.token)} → ${who(n.operator, n.operatorLabel).padEnd(32)} can move ALL NFTs (ApprovalForAll)`,
    });
  }
  for (const p of d.permit2Approvals ?? []) {
    const warn = unlimited(p.amountHuman);
    rows.push({
      warn,
      text: `${warn ? "⚠" : " "} ${sym(p.tokenSymbol, p.token)} → ${who(p.spender, p.spenderLabel).padEnd(32)} ${p.amountHuman || p.amount || "?"} · via Permit2`,
    });
  }
  return rows;
}
