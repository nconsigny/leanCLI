// Tool registry — the high-level chain probes the LLM may call while
// crafting a transaction. Each tool has:
//
//   * A JSONSchema definition (`schema`) — the OpenAI-compatible
//     `tools[]` entry the sidecar puts on the wire. Model-agnostic.
//   * An `impl(args)` function — the sidecar's translation of the tool
//     call into one or more daemon JSON-RPC calls. The daemon enforces
//     `Privacy.NetworkPolicy` on every read.
//   * A `summary(args, result)` — a compact, human-readable string the
//     sidecar appends to the tool message so a small model doesn't
//     have to re-parse JSON to use the result.
//
// Trust model: each tool is read-only on the chain. None of them sign,
// none of them encode calldata that ends up in the final Intent — the
// only path to signing is still IntentParser → encodeIntent → simulate
// → ConfirmGate. These tools exist purely to enrich the LLM's
// decision-making (e.g. "set allowance to 2× current").

import { encodeFunctionData, decodeFunctionResult, parseAbi, formatUnits } from "viem";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { dispatch, tryDispatch } from "../daemon-callback.mjs";

/** Map a chainId to the daemon's `chain` string parameter. The daemon
 *  endpointForChain only knows "mainnet" and "sepolia" today; anything
 *  else falls back to the daemon's default chain endpoint. */
function chainName(chainId) {
  if (chainId === 1) return "mainnet";
  if (chainId === 11155111) return "sepolia";
  return undefined;
}

/** Format a base-units uint256 (as bigint or "0x..." hex) into a
 *  human string when we know decimals. Falls back to the raw integer
 *  when we don't. */
function humanAmount(raw, decimals, symbol) {
  let big;
  try {
    big = typeof raw === "bigint" ? raw : BigInt(raw);
  } catch {
    return String(raw);
  }
  if (decimals === undefined || decimals === null) return big.toString();
  const human = formatUnits(big, decimals);
  return symbol ? `${human} ${symbol}` : human;
}

/** Read the (decimals, symbol) of a token via two `chain.ethCall`s.
 *  Daemon caches these per process via TokenMeta, so repeated calls in
 *  the same tool loop are free. Returns nulls on miss; tool keeps the
 *  raw integer in that case. */
async function readTokenMeta(chainId, token) {
  const chain = chainName(chainId);
  // decimals() = 0x313ce567, symbol() = 0x95d89b41
  const [decRes, symRes] = await Promise.all([
    tryDispatch("chain.ethCall", { chainId, chain, to: token, data: "0x313ce567" }),
    tryDispatch("chain.ethCall", { chainId, chain, to: token, data: "0x95d89b41" }),
  ]);
  let decimals = null;
  if (decRes.ok && typeof decRes.result?.returnData === "string") {
    try {
      decimals = Number(BigInt(decRes.result.returnData));
      if (decimals < 0 || decimals > 64) decimals = null;
    } catch {}
  }
  let symbol = null;
  if (symRes.ok && typeof symRes.result?.returnData === "string") {
    try {
      const decoded = decodeFunctionResult({
        abi: parseAbi(["function symbol() view returns (string)"]),
        functionName: "symbol",
        data: symRes.result.returnData,
      });
      if (typeof decoded === "string" && decoded.length > 0) symbol = decoded;
    } catch {
      // bytes32 legacy tokens (MKR etc.) — trim trailing nulls
      const raw = symRes.result.returnData;
      if (typeof raw === "string" && raw.startsWith("0x")) {
        const hex = raw.slice(2).replace(/(?:00)+$/, "");
        try {
          symbol = Buffer.from(hex, "hex").toString("utf8");
        } catch {}
      }
    }
  }
  return { decimals, symbol };
}

const allowance = {
  name: "allowance",
  schema: {
    type: "function",
    function: {
      name: "allowance",
      description:
        "Read the current ERC-20 allowance the owner has granted to spender. " +
        "Call this BEFORE emitting an erc20Approve when the user wants a relative " +
        "change (e.g. 'double my current allowance', 'add 50 USDC to my allowance'). " +
        "Returns base units and a human string.",
      parameters: {
        type: "object",
        required: ["chainId", "token", "owner", "spender"],
        properties: {
          chainId: { type: "integer", description: "11155111 for sepolia, 1 for mainnet" },
          token: { type: "string", description: "0x-prefixed ERC-20 contract address" },
          owner: { type: "string", description: "0x-prefixed owner address (usually the sender wallet)" },
          spender: { type: "string", description: "0x-prefixed spender address" },
        },
      },
    },
  },
  async impl({ chainId, token, owner, spender }) {
    const chain = chainName(chainId);
    const data = encodeFunctionData({
      abi: parseAbi(["function allowance(address,address) view returns (uint256)"]),
      functionName: "allowance",
      args: [owner, spender],
    });
    const callRes = await tryDispatch("chain.ethCall", { chainId, chain, to: token, data });
    if (!callRes.ok) return { ok: false, error: callRes.error };
    const raw = callRes.result?.returnData;
    if (typeof raw !== "string") return { ok: false, error: "no returnData" };
    let value;
    try {
      value = BigInt(raw);
    } catch (e) {
      return { ok: false, error: `decode failed: ${e.message}` };
    }
    const meta = await readTokenMeta(chainId, token);
    return {
      ok: true,
      value: value.toString(),
      decimals: meta.decimals,
      symbol: meta.symbol,
      human: humanAmount(value, meta.decimals, meta.symbol),
    };
  },
  summary(args, result) {
    if (!result?.ok) return `allowance(${args.token}, ${args.owner}→${args.spender}) → error: ${result?.error}`;
    return `current allowance ${args.owner}→${args.spender} on ${args.token}: ${result.human}`;
  },
};

const balanceOf = {
  name: "balanceOf",
  schema: {
    type: "function",
    function: {
      name: "balanceOf",
      description:
        "Read an ERC-20 token balance. Call this when the user references their " +
        "balance ('send all my USDC', 'half my DAI'). Returns base units and a human string.",
      parameters: {
        type: "object",
        required: ["chainId", "token", "owner"],
        properties: {
          chainId: { type: "integer" },
          token: { type: "string", description: "0x-prefixed ERC-20 contract address" },
          owner: { type: "string", description: "0x-prefixed wallet address" },
        },
      },
    },
  },
  async impl({ chainId, token, owner }) {
    // The daemon already exposes `chain.tokenBalance` which wraps
    // balanceOf(owner); no viem-side encoding needed. Saves one
    // round-trip vs. ethCall + decode in the sidecar.
    const res = await tryDispatch("chain.tokenBalance", { token, owner });
    if (!res.ok) return { ok: false, error: res.error };
    const raw = res.result?.balance;
    if (typeof raw !== "string") return { ok: false, error: "no balance field" };
    let value;
    try {
      value = BigInt(raw);
    } catch (e) {
      return { ok: false, error: `decode failed: ${e.message}` };
    }
    const meta = await readTokenMeta(chainId, token);
    return {
      ok: true,
      value: value.toString(),
      decimals: meta.decimals,
      symbol: meta.symbol,
      human: humanAmount(value, meta.decimals, meta.symbol),
    };
  },
  summary(args, result) {
    if (!result?.ok) return `balanceOf(${args.token}, ${args.owner}) → error: ${result?.error}`;
    return `${args.owner} balance on ${args.token}: ${result.human}`;
  },
};

const ethBalance = {
  name: "ethBalance",
  schema: {
    type: "function",
    function: {
      name: "ethBalance",
      description:
        "Read a wallet's native ETH balance. Call this when the user references their " +
        "ETH balance ('send half my ETH', 'do I have enough for gas?'). " +
        "Returns wei and a human string in ETH.",
      parameters: {
        type: "object",
        required: ["chainId", "address"],
        properties: {
          chainId: { type: "integer" },
          address: { type: "string", description: "0x-prefixed wallet address" },
        },
      },
    },
  },
  async impl({ chainId, address }) {
    const chain = chainName(chainId);
    const res = await tryDispatch("chain.balance", { address, chain });
    if (!res.ok) return { ok: false, error: res.error };
    const raw = res.result?.balance;
    if (typeof raw !== "string") return { ok: false, error: "no balance field" };
    let value;
    try {
      value = BigInt(raw);
    } catch (e) {
      return { ok: false, error: `decode failed: ${e.message}` };
    }
    return {
      ok: true,
      wei: value.toString(),
      human: `${formatUnits(value, 18)} ETH`,
    };
  },
  summary(args, result) {
    if (!result?.ok) return `ethBalance(${args.address}) → error: ${result?.error}`;
    return `${args.address} native balance: ${result.human}`;
  },
};

const simulateTx = {
  name: "simulateTx",
  schema: {
    type: "function",
    function: {
      name: "simulateTx",
      description:
        "Dry-run a candidate transaction before emitting it as the final Intent. " +
        "Returns whether it would succeed, the gas estimate, and the revert reason " +
        "if any. Use this when you're about to emit a non-trivial Intent and want " +
        "to verify it doesn't revert (e.g. multi-step swaps, transfer with insufficient balance).",
      parameters: {
        type: "object",
        required: ["chainId", "from", "to"],
        properties: {
          chainId: { type: "integer" },
          from: { type: "string", description: "sender 0x address" },
          to: { type: "string", description: "destination 0x address" },
          value: {
            type: "string",
            description: "wei as 0x-hex (omit or '0x0' for token-only tx)",
          },
          data: {
            type: "string",
            description: "0x-prefixed calldata (omit or '0x' for native transfer)",
          },
        },
      },
    },
  },
  async impl({ chainId, from, to, value, data }) {
    const chain = chainName(chainId);
    const res = await tryDispatch("tx.simulate", {
      chainId,
      chain,
      from,
      to,
      value: value ?? "0x0",
      data: data ?? "0x",
      block: "latest",
      trace: false,
    });
    if (!res.ok) return { ok: false, error: res.error };
    const r = res.result ?? {};
    return {
      ok: true,
      wouldSucceed: r.ok === true,
      gasEstimate: r.gasEstimate ?? null,
      revertReason: r.revertReason ?? null,
    };
  },
  summary(args, result) {
    if (!result?.ok) return `simulateTx → error: ${result?.error}`;
    if (result.wouldSucceed)
      return `simulateTx ✓ would succeed (gas ${result.gasEstimate ?? "?"})`;
    return `simulateTx ✗ would revert: ${result.revertReason ?? "(no reason)"}`;
  },
};

// ── Static "is this protocol wired?" knowledge ──────────────────────
// Source of truth: the clearsign registry files. We parse them at
// module load so the tool answer stays in sync with what the daemon's
// encoders actually accept. Each entry records (chainId, address) for
// the protocol's router; the Intent action tag the model should emit
// is hard-wired here because the encoder enum lives Lean-side and is
// stable.
const KNOWN_ROUTERS = (() => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const registryDir = path.resolve(here, "../../../clearsign/registry");
  // Map protocol → { intentTag, deployments: [{chainId, address}] }
  const out = {};
  const load = (file, key, intentTag) => {
    try {
      const j = JSON.parse(readFileSync(path.join(registryDir, file), "utf8"));
      const deps = j?.context?.contract?.deployments ?? [];
      out[key] = {
        intentTag,
        deployments: deps
          .filter((d) => typeof d?.chainId === "number" && typeof d?.address === "string")
          .map((d) => ({ chainId: d.chainId, address: d.address })),
      };
    } catch {
      // Missing or unparseable registry file → protocol unavailable.
    }
  };
  load("uniswap-v3-swap-router-02.json", "uniswap-v3", "uniswapV3SwapSingle");
  return out;
})();

// ── resolveToken ────────────────────────────────────────────────────
// One swap.tokens.list per (process, chainId). The registry is static
// for the daemon's lifetime, so a process-scoped cache is safe.
const tokensCache = new Map();

function chainStrForSwapRpc(chainId) {
  if (chainId === 1) return "mainnet";
  if (chainId === 11155111) return "sepolia";
  return String(chainId);
}

async function loadTokens(chainId) {
  const cached = tokensCache.get(chainId);
  if (cached) return cached;
  const res = await tryDispatch("swap.tokens.list", {
    chainId: chainStrForSwapRpc(chainId),
  });
  if (!res.ok) return { ok: false, error: res.error };
  const tokens = Array.isArray(res.result?.tokens) ? res.result.tokens : [];
  const entry = { ok: true, tokens };
  tokensCache.set(chainId, entry);
  return entry;
}

const resolveToken = {
  name: "resolveToken",
  schema: {
    type: "function",
    function: {
      name: "resolveToken",
      description:
        "Resolve a token symbol (e.g. 'USDC', 'WETH') to its canonical 0x address, " +
        "decimals, and full name on a given chain. Call this BEFORE emitting an " +
        "Intent whenever the user names a token by symbol — never ask the user for " +
        "an address you can look up. 'ETH' is special: it has no contract address " +
        "(returned address is null); swap encoders treat 'ETH' as the wrap source.",
      parameters: {
        type: "object",
        required: ["chainId", "symbol"],
        properties: {
          chainId: { type: "integer", description: "11155111 for sepolia, 1 for mainnet" },
          symbol: { type: "string", description: "Case-insensitive token symbol, e.g. 'USDC'" },
        },
      },
    },
  },
  async impl({ chainId, symbol }) {
    if (typeof symbol !== "string" || symbol.length === 0) {
      return { ok: false, error: "symbol required" };
    }
    const want = symbol.trim().toUpperCase();
    if (want === "ETH") {
      return {
        ok: true,
        symbol: "ETH",
        name: "Ether",
        address: null,
        decimals: 18,
        note: "native ETH — swap encoders accept the literal string 'ETH' in tokenIn/tokenOut",
      };
    }
    const r = await loadTokens(chainId);
    if (!r.ok) return { ok: false, error: r.error };
    const match = r.tokens.find(
      (t) => typeof t?.symbol === "string" && t.symbol.toUpperCase() === want,
    );
    if (!match) {
      return {
        ok: false,
        error: `unknown token '${symbol}' on chainId ${chainId}`,
        knownSymbols: r.tokens.map((t) => t.symbol).filter(Boolean),
      };
    }
    return {
      ok: true,
      symbol: match.symbol,
      name: match.name ?? null,
      address: match.address ?? null,
      decimals: typeof match.decimals === "number" ? match.decimals : null,
    };
  },
  summary(args, result) {
    if (!result?.ok) {
      return `resolveToken(${args.symbol}, chainId=${args.chainId}) → ${result?.error ?? "error"}`;
    }
    if (result.address === null) return `resolveToken(${args.symbol}) → native ETH (no contract)`;
    return `resolveToken(${args.symbol}) → ${result.address} (${result.decimals} decimals)`;
  },
};

// ── resolveWallet ───────────────────────────────────────────────────
// Accepts "name" or "name/sub" where sub is a numeric BIP-32 index or
// a user-assigned label. Unique match → {address, kind}. Multiple
// candidates → {ok:false, candidates:[...]} so the model can ask the
// user to disambiguate instead of guessing.
const resolveWallet = {
  name: "resolveWallet",
  schema: {
    type: "function",
    function: {
      name: "resolveWallet",
      description:
        "Resolve a wallet label (e.g. 'leanWallet', 'leanWallet/0', 'leanWallet/ops', " +
        "'R1test01') to a 0x address and wallet kind ('eoa' or 'tpm'). EOA wallets " +
        "have BIP-32 sub-accounts; the label after '/' is either the numeric index " +
        "or the per-account label string. Call this whenever the user names a " +
        "wallet to act from. If multiple sub-accounts match (bare EOA name with >1 " +
        "subs), the response lists candidates so you can ask the user which one.",
      parameters: {
        type: "object",
        required: ["label"],
        properties: {
          label: {
            type: "string",
            description: "Wallet label: 'name' for TPM wallets or single-sub EOAs, " +
              "'name/sub' to disambiguate an EOA sub-account",
          },
        },
      },
    },
  },
  async impl({ label }) {
    if (typeof label !== "string" || label.length === 0) {
      return { ok: false, error: "label required" };
    }
    const slash = label.indexOf("/");
    const head = (slash >= 0 ? label.slice(0, slash) : label).trim();
    const sub = slash >= 0 ? label.slice(slash + 1).trim() : null;
    if (head.length === 0) return { ok: false, error: "empty wallet name" };

    const listRes = await tryDispatch("account.list", {});
    if (!listRes.ok) return { ok: false, error: listRes.error };
    const accounts = Array.isArray(listRes.result?.accounts) ? listRes.result.accounts : [];

    const w = accounts.find(
      (a) => typeof a?.name === "string" && a.name.toLowerCase() === head.toLowerCase(),
    );
    if (!w) {
      return {
        ok: false,
        error: `no wallet named '${head}'`,
        knownNames: accounts.map((a) => a.name).filter(Boolean),
      };
    }

    if (w.type === "tpm") {
      if (sub) {
        return { ok: false, error: `TPM wallet '${head}' has no sub-accounts; drop the '/${sub}'` };
      }
      return { ok: true, kind: "tpm", name: w.name, address: w.address };
    }
    if (w.type !== "eoa") {
      return { ok: false, error: `unknown wallet type '${w.type}'` };
    }

    // EOA — fetch sub-accounts to honour `/sub`.
    const subsRes = await tryDispatch("eoa.account.list", { name: w.name });
    if (!subsRes.ok) return { ok: false, error: subsRes.error };
    const subs = Array.isArray(subsRes.result?.accounts) ? subsRes.result.accounts : [];

    const renderCandidate = (s) => ({
      label: `${w.name}/${s.label ?? String(s.index)}`,
      address: s.address,
      index: s.index,
      path: s.path,
    });

    if (sub) {
      const wantNum = /^\d+$/.test(sub) ? Number(sub) : null;
      const match = subs.find((s) => {
        if (wantNum !== null && s?.index === wantNum) return true;
        if (typeof s?.label === "string" && s.label.toLowerCase() === sub.toLowerCase()) return true;
        return false;
      });
      if (!match) {
        return {
          ok: false,
          error: `no sub-account '${sub}' on '${head}'`,
          candidates: subs.map(renderCandidate),
        };
      }
      return {
        ok: true,
        kind: "eoa",
        name: `${w.name}/${match.label ?? String(match.index)}`,
        address: match.address,
        index: match.index,
        path: match.path,
      };
    }

    // No sub specified. Single sub → return it. Multiple → ambiguous.
    if (subs.length === 1) {
      const only = subs[0];
      return {
        ok: true,
        kind: "eoa",
        name: `${w.name}/${only.label ?? String(only.index)}`,
        address: only.address,
        index: only.index,
        path: only.path,
      };
    }
    if (subs.length === 0) {
      // No sub-account expansion available — fall back to record address.
      return { ok: true, kind: "eoa", name: w.name, address: w.address };
    }
    return {
      ok: false,
      error: `'${head}' has ${subs.length} sub-accounts — ask the user which one`,
      candidates: subs.map(renderCandidate),
    };
  },
  summary(args, result) {
    if (!result?.ok) {
      const cand = result?.candidates;
      if (Array.isArray(cand) && cand.length > 0) {
        const list = cand.map((c) => `${c.label} (${c.address})`).join(", ");
        return `resolveWallet(${args.label}) → ambiguous: ${list}`;
      }
      return `resolveWallet(${args.label}) → ${result?.error ?? "error"}`;
    }
    return `resolveWallet(${args.label}) → ${result.kind} ${result.address}`;
  },
};

// ── knownRouters ────────────────────────────────────────────────────
const knownRouters = {
  name: "knownRouters",
  schema: {
    type: "function",
    function: {
      name: "knownRouters",
      description:
        "Check whether a named protocol (e.g. 'uniswap-v3') is wired into the " +
        "daemon's encoder on a given chain. Returns the wired router address and " +
        "the canonical Intent action tag the model must emit — do NOT encode " +
        "calldata to a router by hand; emit the structured Intent instead.",
      parameters: {
        type: "object",
        required: ["chainId", "protocol"],
        properties: {
          chainId: { type: "integer" },
          protocol: {
            type: "string",
            description: "Lowercase protocol key, e.g. 'uniswap-v3'",
          },
        },
      },
    },
  },
  async impl({ chainId, protocol }) {
    const entry = KNOWN_ROUTERS[String(protocol ?? "").toLowerCase()];
    if (!entry) {
      return {
        ok: false,
        error: `protocol '${protocol}' is not wired`,
        knownProtocols: Object.keys(KNOWN_ROUTERS),
      };
    }
    const dep = entry.deployments.find((d) => d.chainId === chainId);
    if (!dep) {
      return {
        ok: false,
        error: `protocol '${protocol}' has no deployment on chainId ${chainId}`,
        knownChainIds: entry.deployments.map((d) => d.chainId),
      };
    }
    return {
      ok: true,
      protocol,
      chainId,
      router: dep.address,
      intentTag: entry.intentTag,
      note: "Emit an Intent with this action tag; do NOT hand-encode calldata to the router",
    };
  },
  summary(args, result) {
    if (!result?.ok) {
      return `knownRouters(${args.protocol}, chainId=${args.chainId}) → ${result?.error ?? "error"}`;
    }
    return `knownRouters(${args.protocol}) → ${result.router} (emit ${result.intentTag} Intent)`;
  },
};

// ── quoteUniV3 ──────────────────────────────────────────────────────
// Wraps `swap.uniV3.quote`. The model needs this to convert a
// user-stated slippage ("0.5%") into the absolute minAmountOut
// (uint256, base units) the encoder requires. Returns the best-priced
// fee tier the quoter accepts plus the expected output amount; the
// model is expected to compute `minAmountOut = expected * (1 - slippage)`
// itself (small integer math, no precision pitfalls at this scale).
const quoteUniV3 = {
  name: "quoteUniV3",
  schema: {
    type: "function",
    function: {
      name: "quoteUniV3",
      description:
        "Quote a Uniswap V3 single-pool swap. Returns the expected " +
        "amountOut (base units) and the matching fee tier. Call this when " +
        "the user gave slippage as a percentage — you need the quote to " +
        "compute the absolute minAmountOut the encoder requires. The 'ETH' " +
        "literal is accepted on either side; the daemon resolves it to WETH " +
        "internally for the pool lookup.",
      parameters: {
        type: "object",
        required: ["chainId", "tokenIn", "tokenOut", "amountIn"],
        properties: {
          chainId: { type: "integer" },
          tokenIn: {
            type: "string",
            description: "0x address or the literal 'ETH'",
          },
          tokenOut: {
            type: "string",
            description: "0x address or the literal 'ETH'",
          },
          amountIn: {
            type: "string",
            description: "Base-units integer as a decimal string (NOT human units)",
          },
        },
      },
    },
  },
  async impl({ chainId, tokenIn, tokenOut, amountIn }) {
    const res = await tryDispatch("swap.uniV3.quote", {
      chainId: chainStrForSwapRpc(chainId),
      tokenIn,
      tokenOut,
      amountIn,
    });
    if (!res.ok) return { ok: false, error: res.error };
    const r = res.result ?? {};
    // Daemon returns whichever fee tier quoted successfully + the
    // resulting amountOut. We surface both verbatim.
    return {
      ok: true,
      fee: r.fee ?? null,
      amountOut: r.amountOut ?? null,
    };
  },
  summary(args, result) {
    if (!result?.ok) {
      return `quoteUniV3(${args.tokenIn}→${args.tokenOut}) → ${result?.error ?? "error"}`;
    }
    return `quoteUniV3 → ${result.amountOut} out @ fee=${result.fee}`;
  },
};

const ALL_TOOLS = {
  allowance,
  balanceOf,
  ethBalance,
  simulateTx,
  resolveToken,
  resolveWallet,
  knownRouters,
  quoteUniV3,
};

/** Resolve a list of tool names to their full definitions. Unknown
 *  names are dropped silently so a typo in a SKILL.md doesn't take the
 *  whole tool loop down. */
export function selectTools(names) {
  if (!Array.isArray(names)) return [];
  return names.map((n) => ALL_TOOLS[n]).filter(Boolean);
}

/** OpenAI-compatible `tools` array for the chat completion request. */
export function toolSchemas(tools) {
  return tools.map((t) => t.schema);
}

/** Look up a tool by name (for dispatch from a tool_call). */
export function findTool(tools, name) {
  return tools.find((t) => t.name === name);
}
