// Tornado Cash sidecar handlers (@kohaku-eth/tornado-cash).
//
// Lazily imported by bridge.mjs only on `shielded.tornado.*` methods, after the
// LEANCLI_PRIVACY enablement gate. Kept in its own module so bridge.mjs stays
// lean and so tornado's async-host plumbing (plugins alpha.11) is isolated from
// the sync-host PP/railgun code (plugins alpha.8).
//
// SECURITY: this process is UNTRUSTED for transaction structure. Deposit
// handlers return UNSIGNED calldata that the Lean daemon re-decodes and signs
// through its own TPM-rooted path (decode → simulate → ConfirmGate → eoa.send).
// Withdraw handlers carry NO EOA signature — a groth16 proof authorizes
// spending the note and a relayer/paymaster submits it — so confirming the
// quoted terms IS the pre-broadcast gate, exactly like Privacy Pools unshield.
//
// Note model: unlike classic Tornado, this SDK derives note secrets
// deterministically from the wallet keystore (BIP-32 under m/29795'/1', bound
// to chain+pool). There is NO note string to save — the wallet seed recovers
// every note. Notes are identified by (pool, depositIndex).

import { createPublicClient, http, parseEther } from "viem";
import { sepolia, mainnet } from "viem/chains";
import { HDKey } from "@scure/bip32";
import { mnemonicToSeedSync } from "@scure/bip39";
import { withChunkedGetLogs } from "./chunked-get-logs.mjs";

// Fixed ETH pool denominations, per chain (ETH-only for now; token pools are
// not supported). Mainnet (1) deploys 0.1 / 1 / 10 / 100 ETH; Sepolia
// (11155111) only deploys 0.1 / 1 ETH — attempting 10/100 there would fail at
// the pool level, so we reject it up front with a chain-specific message.
const ETH_DENOMINATIONS_BY_CHAIN = {
  1: ["0.1", "1", "10", "100"],
  11155111: ["0.1", "1"],
};
const MIN_DENOMINATION_WEI = parseEther("0.1");

function ethDenominationsEth(chainId) {
  return ETH_DENOMINATIONS_BY_CHAIN[Number(chainId)] ?? ["0.1", "1", "10", "100"];
}

function ethDenominationsWei(chainId) {
  return ethDenominationsEth(chainId).map((d) => parseEther(d));
}

// Lazy import: @kohaku-eth/tornado-cash spins up comlink worker threads and
// (on first withdraw) downloads groth16 proving artifacts, so we only pay that
// on a tornado method. provider/viem alpha.7 and alpha.8 share an identical
// interface, so the top-level provider works for the alpha.11-hosted plugin.
async function loadTornado() {
  const tc = await import("@kohaku-eth/tornado-cash");
  const provider = await import("@kohaku-eth/provider/viem");
  return { tc, provider };
}

function chainFromId(id) {
  switch (Number(id)) {
    case 1: return mainnet;
    case 11155111: return sepolia;
    default: throw new Error(`unsupported chainId: ${id}`);
  }
}

function inMemoryNetwork() {
  return { fetch: (input, init) => fetch(input, init) };
}

// Async, string-valued, file-backed Storage (plugins alpha.11 Host.storage
// contract: get→Promise<string|null>, set(key, string)→Promise<void>). The
// tornado plugin persists its indexer state (commitments, merkle leaves,
// which deposit indices are ours) here so it survives one-shot invocations.
function asyncFileStorage(storagePath, fsSync, pathMod) {
  let store = {};
  try {
    store = JSON.parse(fsSync.readFileSync(storagePath, "utf8"));
    console.error(`[bridge] loaded TC storage from ${storagePath} (${Object.keys(store).length} keys)`);
  } catch (e) {
    if (e?.code !== "ENOENT") {
      console.error(`[bridge] TC storage read failed: ${e?.message ?? e}; starting empty`);
    }
  }
  function flush() {
    try {
      fsSync.mkdirSync(pathMod.dirname(storagePath), { recursive: true });
      const tmp = `${storagePath}.tmp`;
      fsSync.writeFileSync(tmp, JSON.stringify(store));
      fsSync.renameSync(tmp, storagePath);
    } catch (e) {
      console.error(`[bridge] TC storage write failed: ${e?.message ?? e}`);
    }
  }
  return {
    _brand: "Storage",
    async get(key) { return key in store ? store[key] : null; },
    async set(key, value) { store[key] = value; flush(); },
  };
}

// Keystore (plugins alpha.11 Host.keystore contract: deriveAt→Promise<Hex>).
// HDKey.fromMasterSeed(seed).derive(path) matches kohaku-cli's
// Mnemonic.to0xPrivateKey for the same seed, so notes are cross-recoverable.
function keystoreFromSeedBytes(seed) {
  const master = HDKey.fromMasterSeed(seed);
  return {
    async deriveAt(path) {
      const child = master.derive(path);
      if (!child.privateKey) throw new Error("keystore: no private key at " + path);
      return "0x" + Buffer.from(child.privateKey).toString("hex");
    },
  };
}

function keystoreFromSeedHex(seedHex) {
  const clean = seedHex.startsWith("0x") ? seedHex.slice(2) : seedHex;
  if (!/^[0-9a-fA-F]+$/.test(clean) || clean.length % 2 !== 0) {
    throw new Error("LEANCLI_TC_SEED_HEX must be 0x-prefixed even-length hex");
  }
  return keystoreFromSeedBytes(Buffer.from(clean, "hex"));
}

function keystoreFromMnemonic(mnemonic) {
  return keystoreFromSeedBytes(mnemonicToSeedSync(mnemonic));
}

function bundlerUrlFor(chainId, override) {
  return override && override.trim() !== ""
    ? override.trim()
    : `https://public.pimlico.io/v2/${Number(chainId)}/rpc`;
}

// Single-chain paymaster config with an optionally-overridden bundler URL.
// Shape matches the SDK default (TornadoPaymasterConfigs), so passing this is
// equivalent unless the operator overrides the bundler via LEANCLI_TC_BUNDLER_URL.
function tornadoPaymasterConfig(tc, chainId, bundlerOverride) {
  const staticCfg = tc.TornadoPaymasterConfigs[Number(chainId)];
  if (!staticCfg) return undefined;
  return {
    [Number(chainId)]: { ...staticCfg, bundlerUrl: bundlerUrlFor(chainId, bundlerOverride) },
  };
}

function tornadoEthAsset(tc) {
  return { __type: "erc20", contract: tc.E_ADDRESS };
}

// Build the async Host + TornadoCashProtocol plugin.
async function buildTornadoPlugin(env) {
  const fsSync = await import("node:fs");
  const pathMod = await import("node:path");
  const chainId = BigInt(env.LEANCLI_CHAIN_ID);
  console.error(`[bridge] loading tornado SDK (chainId=${chainId}, rpc=${env.LEANCLI_RPC_URL})`);
  const t0 = Date.now();
  const { tc, provider } = await loadTornado();
  console.error(`[bridge] tornado SDK loaded in ${Date.now() - t0}ms`);

  const config = tc.TornadoCashConfigs[Number(chainId)];
  if (!config) throw new Error(`no Tornado Cash deployment config for chainId=${chainId}`);
  if (!env.LEANCLI_RPC_URL) throw new Error("LEANCLI_RPC_URL is required");
  if (!env.LEANCLI_TC_STORAGE_PATH) throw new Error("LEANCLI_TC_STORAGE_PATH is required (tornado plugin state file)");

  // Node ignores stateManagerWorkerUrl, so patch the bundled worker gas limits
  // on disk before the plugin spawns its worker. Idempotent, best-effort.
  try {
    const { ensureTornadoPaymasterGasPatched } = await import("./tornado-paymaster-gas.mjs");
    ensureTornadoPaymasterGasPatched();
  } catch (e) {
    console.error(`[bridge] tornado worker gas patch skipped: ${e?.message ?? e}`);
  }

  // Keystore source priority mirrors railgun: EOA seed (default, one phrase
  // backs everything) → dedicated mnemonic (compromise isolation).
  let keystore;
  if (env.LEANCLI_TC_SEED_HEX) keystore = keystoreFromSeedHex(env.LEANCLI_TC_SEED_HEX);
  else if (env.LEANCLI_TC_MNEMONIC) keystore = keystoreFromMnemonic(env.LEANCLI_TC_MNEMONIC);
  else throw new Error("LEANCLI_TC_SEED_HEX or LEANCLI_TC_MNEMONIC is required (tornado keystore source)");

  const chain = chainFromId(chainId);
  const client = createPublicClient({ chain, transport: http(env.LEANCLI_RPC_URL) });
  const network = inMemoryNetwork();

  // Saga-CDN external sync for fast cold sync (best-effort; degrades to
  // chain-only on failure). The CDN is untrusted — inclusion is proven against
  // the on-chain merkle root, so a lying CDN can only make sync fail.
  let externalSyncProvider;
  if (env.LEANCLI_TC_EXTERNAL_SYNC_DISABLE !== "1") {
    try {
      const { tornadoExternalSyncForChain } = await import("./tornado-external-sync.mjs");
      externalSyncProvider = tornadoExternalSyncForChain(chainId, network);
    } catch (e) {
      console.error(`[bridge] tornado external sync unavailable (${e?.message ?? e}); chain-only sync`);
    }
  }

  const host = {
    network,
    storage: asyncFileStorage(env.LEANCLI_TC_STORAGE_PATH, fsSync, pathMod),
    keystore,
    provider: withChunkedGetLogs(provider.viem(client)),
    ...(externalSyncProvider ? { externalSyncProvider } : {}),
  };

  const plugin = tc.createTCPlugin(host, {
    accountIndex: 0,
    protocolConfig: config,
    paymasterConfig: tornadoPaymasterConfig(tc, chainId, env.LEANCLI_TC_BUNDLER_URL),
    minExternalSyncBlocksAmount: 1000,
  });
  plugin.__tc = tc;
  plugin.__host = host;
  plugin.__chainId = chainId;
  return plugin;
}

function requireRecipient(params) {
  const recipient = params?.recipient;
  if (!recipient || !/^0x[0-9a-fA-F]{40}$/.test(recipient)) {
    throw new Error("recipient must be a 0x-prefixed 20-byte address");
  }
  return recipient;
}

function amountWeiOf(params) {
  return params?.amountWei ? BigInt(params.amountWei) : parseEther(String(params?.amountEth ?? "0"));
}

function assertDepositAmount(amountWei) {
  if (amountWei <= 0n) throw new Error("amount must be > 0");
  if (amountWei % MIN_DENOMINATION_WEI !== 0n) {
    throw new Error("tornado shield amount must be a positive multiple of 0.1 ETH (fixed pool denominations)");
  }
}

function assertWithdrawDenomination(amountWei, chainId) {
  if (!ethDenominationsWei(chainId).some((d) => d === amountWei)) {
    throw new Error(
      `tornado withdraw amount must be exactly one pool denomination on chain ` +
      `${Number(chainId)} (${ethDenominationsEth(chainId).join("/")} ETH); ` +
      `multi-note drains are performed one denomination per call`,
    );
  }
}

// ---- Handlers -------------------------------------------------------------

async function tornadoBalance(env) {
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  console.error("[bridge] tornado: syncing pool state for balance");
  const ts = Date.now();
  if (plugin.sync) await plugin.sync();
  console.error(`[bridge] tornado: sync complete in ${Date.now() - ts}ms`);
  const balances = await plugin.balance([tornadoEthAsset(tc)]);
  return { chainId: env.LEANCLI_CHAIN_ID, asset: tc.E_ADDRESS, balances };
}

async function tornadoNotes(env, params) {
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  if (plugin.sync) await plugin.sync();
  const includeSpent = params?.includeSpent === true;
  const notes = await plugin.notes([tornadoEthAsset(tc)], includeSpent);
  return {
    chainId: env.LEANCLI_CHAIN_ID,
    notes: notes.map((n) => ({
      pool: n.pool,
      denominationWei: n.amount,
      balanceWei: n.balance,
      depositIndex: n.depositIndex,
      leafIndex: n.leafIndex,
      commitment: n.commitment,
      timestamp: n.timestamp,
      status: BigInt(n.balance ?? 0) > 0n ? "spendable" : "spent",
    })),
  };
}

async function tornadoPrepareDeposit(env, params) {
  const amountWei = amountWeiOf(params);
  assertDepositAmount(amountWei);
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  console.error(`[bridge] tornado: syncing for prepareShield(${amountWei} wei)`);
  const ts = Date.now();
  if (plugin.sync) await plugin.sync();
  console.error(`[bridge] tornado: sync complete in ${Date.now() - ts}ms; preparing shield`);
  const op = await plugin.prepareShield(
    { asset: tornadoEthAsset(tc), amount: amountWei },
    { strategy: tc.DepositStrategy.MaxAnonimitySet },
  );
  const txns = op && Array.isArray(op.txns) ? op.txns : Array.isArray(op) ? op : null;
  if (!txns || txns.length === 0) {
    console.error(`[bridge] tornado prepareShield op shape: ${JSON.stringify(op).slice(0, 400)}`);
    throw new Error("tornado prepareShield returned no txns");
  }
  console.error(`[bridge] tornado: prepareShield returned ${txns.length} tx(s)`);
  return { chainId: env.LEANCLI_CHAIN_ID, asset: tc.E_ADDRESS, amountWei, txns };
}

// Local paymaster fee terms for the ConfirmGate (paymaster mode). No proof is
// built here — the fee is a deterministic function of the bundler gas price —
// so a quote stays cheap. Relayer mode returns note context; the precise
// relayer fee is applied by the relayer at execute time.
async function tornadoQuoteWithdraw(env, params) {
  const recipient = requireRecipient(params);
  const amountWei = amountWeiOf(params);
  assertWithdrawDenomination(amountWei, BigInt(env.LEANCLI_CHAIN_ID));
  const mode = params?.mode === "relayer" ? "relayer" : "paymaster";
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  if (plugin.sync) await plugin.sync();
  const notes = await plugin.notes([tornadoEthAsset(tc)]);
  const spendable = notes.filter((n) => BigInt(n.balance ?? 0) > 0n);
  const spendableTotal = spendable.reduce((s, n) => s + BigInt(n.balance), 0n);
  const matching = spendable.filter((n) => BigInt(n.amount) === amountWei).length;
  if (matching === 0) {
    throw new Error(
      `no spendable ${params?.amountEth ?? amountWei} note available to withdraw ` +
      `(have ${spendable.length} spendable note(s), total ${spendableTotal} wei)`,
    );
  }

  const base = {
    chainId: env.LEANCLI_CHAIN_ID,
    recipient,
    denominationWei: amountWei,
    mode,
    spendableTotalWei: spendableTotal,
    matchingNoteCount: matching,
  };
  if (mode === "paymaster") {
    const bundlerUrl = bundlerUrlFor(plugin.__chainId, env.LEANCLI_TC_BUNDLER_URL);
    const { estimateTornadoPaymasterFee, fetchTornadoMaxFeePerGas } =
      await import("./tornado-paymaster-gas.mjs");
    const maxFeePerGas = await fetchTornadoMaxFeePerGas(bundlerUrl);
    const feeWei = estimateTornadoPaymasterFee(maxFeePerGas);
    const netWei = amountWei - feeWei;
    if (netWei <= 0n) {
      throw new Error(`withdrawal amount too small to cover the tornado paymaster fee (~${feeWei} wei)`);
    }
    return { ...base, paymasterFeeWei: feeWei, netWei, maxFeePerGasWei: maxFeePerGas };
  }
  return base;
}

async function tornadoExecuteWithdraw(env, params) {
  const recipient = requireRecipient(params);
  const amountWei = amountWeiOf(params);
  assertWithdrawDenomination(amountWei, BigInt(env.LEANCLI_CHAIN_ID));
  const mode = params?.mode === "relayer" ? "relayer" : "paymaster";
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  if (plugin.sync) await plugin.sync();
  const asset = { asset: tornadoEthAsset(tc), amount: amountWei };

  let op;
  if (mode === "paymaster") {
    const bundlerUrl = bundlerUrlFor(plugin.__chainId, env.LEANCLI_TC_BUNDLER_URL);
    const { estimateTornadoPaymasterFee, fetchTornadoMaxFeePerGas } =
      await import("./tornado-paymaster-gas.mjs");
    const maxFeePerGas = await fetchTornadoMaxFeePerGas(bundlerUrl);
    const feeWei = estimateTornadoPaymasterFee(maxFeePerGas);
    // H2: the fee is recomputed here from a fresh (untrusted) bundler gas
    // price, decoupled from the quote the user confirmed. Enforce the
    // confirmed ceiling so a gas spike — or a bundler reporting an inflated
    // price — cannot silently shrink the recipient's `forwardValue` (the
    // difference is kept by the paymaster). The caller passes the quoted
    // paymasterFeeWei (optionally with headroom) as `maxFeeWei`.
    const maxFeeWei = params?.maxFeeWei != null ? BigInt(params.maxFeeWei) : null;
    if (maxFeeWei !== null && feeWei > maxFeeWei) {
      throw new Error(
        `tornado paymaster fee ${feeWei} wei exceeds the confirmed ceiling ${maxFeeWei} wei ` +
        `(gas price rose since the quote) — re-quote and confirm before withdrawing`,
      );
    }
    const forwardValue = amountWei - feeWei;
    if (forwardValue <= 0n) {
      throw new Error(`withdrawal amount too small to cover the tornado paymaster fee (~${feeWei} wei)`);
    }
    console.error(`[bridge] tornado: prepareUnshield paymaster to=${recipient} forward=${forwardValue}`);
    op = await plugin.prepareUnshield(asset, recipient, {
      mode: "paymaster",
      tailCalls: async () => [{ to: recipient, data: "0x", value: forwardValue }],
    });
  } else {
    const ens = Array.isArray(params?.preferredRelayersEns) ? params.preferredRelayersEns : undefined;
    console.error(`[bridge] tornado: prepareUnshield relayer to=${recipient}`);
    op = await plugin.prepareUnshield(asset, recipient, {
      mode: "relayer",
      ...(ens && ens.length ? { preferredRelayersEns: ens } : {}),
    });
  }

  const broadcaster = tc.createTCBroadcaster(plugin.__host, {
    paymasterConfig: tornadoPaymasterConfig(tc, plugin.__chainId, env.LEANCLI_TC_BUNDLER_URL),
  });
  console.error(`[bridge] tornado: broadcasting ${mode} withdrawal`);
  const relay = await broadcaster.broadcast(op);
  return { chainId: env.LEANCLI_CHAIN_ID, recipient, denominationWei: amountWei, mode, relay: relay ?? { ok: true } };
}

/**
 * Dispatch a `shielded.tornado.*` method. Returns the result object (BigInts
 * are rendered as hex by bridge.mjs's jsonifyResult); throws on error.
 */
export async function dispatchTornado(method, env, params) {
  switch (method) {
    case "shielded.tornado.balance": return await tornadoBalance(env);
    case "shielded.tornado.notes": return await tornadoNotes(env, params);
    case "shielded.tornado.prepareDeposit": return await tornadoPrepareDeposit(env, params);
    case "shielded.tornado.quoteWithdraw": return await tornadoQuoteWithdraw(env, params);
    case "shielded.tornado.executeWithdraw": return await tornadoExecuteWithdraw(env, params);
    default: throw new Error(`unknown tornado method: ${method}`);
  }
}

export const TORNADO_METHODS = new Set([
  "shielded.tornado.balance",
  "shielded.tornado.notes",
  "shielded.tornado.prepareDeposit",
  "shielded.tornado.quoteWithdraw",
  "shielded.tornado.executeWithdraw",
]);
