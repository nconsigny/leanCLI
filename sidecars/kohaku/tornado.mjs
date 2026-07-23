// Tornado Cash sidecar handlers (@kohaku-eth/tornado-cash).
//
// Lazily imported by bridge.mjs only on `shielded.tornado.*` methods, after the
// LEANCLI_PRIVACY enablement gate. Kept in its own module so bridge.mjs stays
// lean and so Tornado's worker/state plumbing stays isolated from the shared
// async Host used by Privacy Pools and Railgun.
//
// SECURITY: this process is UNTRUSTED for transaction structure. Deposit
// handlers return UNSIGNED calldata that the Lean daemon re-decodes and signs
// through its own TPM-rooted path (decode → simulate → ConfirmGate → eoa.send).
// A groth16 proof authorizes spending the note and a relayer/paymaster submits
// it. Paymaster tail calls also need an EIP-7702 authorization from the
// recipient EOA; the Lean daemon resolves that recipient's BIP-44 path from
// the selected wallet and re-derives the address before this sidecar sees it.
// Confirming the quoted terms remains the pre-broadcast gate.
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
// on a tornado method. All privacy plugins share the top-level provider
// alpha.8 transport.
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

function require32ByteHex(label, value) {
  const clean = String(value ?? "").replace(/^0x/, "");
  if (!/^[0-9a-fA-F]{64}$/.test(clean)) {
    throw new Error(`${label} must be exactly 32 bytes of hex`);
  }
  return Buffer.from(clean, "hex");
}

/**
 * Keystore exposing only the hardened m/29795'/1' subtree plus, while
 * preparing a paymaster operation, one explicitly approved BIP-44 key.
 */
export function keystoreFromScopedRoot({
  rootKeyHex,
  rootChainCodeHex,
  delegatorPath,
  delegatorKeyHex,
}) {
  const root = new HDKey({
    privateKey: require32ByteHex("LEANCLI_TC_ROOT_KEY_HEX", rootKeyHex),
    chainCode: require32ByteHex(
      "LEANCLI_TC_ROOT_CHAIN_CODE_HEX",
      rootChainCodeHex,
    ),
  });
  const approvedDelegatorKey =
    delegatorKeyHex == null
      ? null
      : `0x${require32ByteHex(
          "LEANCLI_TC_DELEGATOR_KEY_HEX",
          delegatorKeyHex,
        ).toString("hex")}`;
  if ((delegatorPath == null) !== (approvedDelegatorKey == null)) {
    throw new Error(
      "LEANCLI_TC_DELEGATOR_PATH and LEANCLI_TC_DELEGATOR_KEY_HEX must be set together",
    );
  }
  const prefix = "m/29795'/1'";
  return {
    async deriveAt(path) {
      if (delegatorPath != null && path === delegatorPath) {
        return approvedDelegatorKey;
      }
      if (path !== prefix && !path.startsWith(`${prefix}/`)) {
        throw new Error(`keystore: derivation outside Tornado subtree denied: ${path}`);
      }
      const relativePath = path === prefix ? "m" : `m${path.slice(prefix.length)}`;
      const child = root.derive(relativePath);
      if (!child.privateKey) throw new Error(`keystore: no private key at ${path}`);
      return `0x${Buffer.from(child.privateKey).toString("hex")}`;
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

// The daemon passes a hardened Tornado subtree plus at most one approved
// delegator key. Full-seed/mnemonic inputs remain for standalone compatibility.
function keystoreFromEnv(env) {
  if (env.LEANCLI_TC_ROOT_KEY_HEX || env.LEANCLI_TC_ROOT_CHAIN_CODE_HEX) {
    if (!env.LEANCLI_TC_ROOT_KEY_HEX || !env.LEANCLI_TC_ROOT_CHAIN_CODE_HEX) {
      throw new Error(
        "LEANCLI_TC_ROOT_KEY_HEX and LEANCLI_TC_ROOT_CHAIN_CODE_HEX must be set together",
      );
    }
    return keystoreFromScopedRoot({
      rootKeyHex: env.LEANCLI_TC_ROOT_KEY_HEX,
      rootChainCodeHex: env.LEANCLI_TC_ROOT_CHAIN_CODE_HEX,
      delegatorPath: env.LEANCLI_TC_DELEGATOR_PATH,
      delegatorKeyHex: env.LEANCLI_TC_DELEGATOR_KEY_HEX,
    });
  }
  // Legacy standalone compatibility. The Lean daemon never uses this path.
  if (env.LEANCLI_TC_SEED_HEX) return keystoreFromSeedHex(env.LEANCLI_TC_SEED_HEX);
  if (env.LEANCLI_TC_MNEMONIC) return keystoreFromMnemonic(env.LEANCLI_TC_MNEMONIC);
  throw new Error("scoped Tornado root credentials are required");
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

  const keystore = keystoreFromEnv(env);

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

function requireRecipientDerivationPath(params) {
  const path = params?.recipientDerivationPath;
  if (typeof path !== "string" || !/^m\/44'\/60'\/[0-9]+'\/[01]\/[0-9]+$/.test(path)) {
    throw new Error("recipientDerivationPath must be a canonical Ethereum BIP-44 path");
  }
  return path;
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

function assertWithdrawAmount(amountWei, chainId, mode = "paymaster") {
  if (mode === "relayer" && !ethDenominationsWei(chainId).includes(amountWei)) {
    throw new Error(
      `tornado relayer withdrawals must be exactly one pool denomination on ` +
      `chain ${Number(chainId)} (${ethDenominationsEth(chainId).join("/")} ETH)`,
    );
  }
  if (mode !== "relayer" && (amountWei <= 0n || amountWei % MIN_DENOMINATION_WEI !== 0n)) {
    throw new Error(
      "tornado paymaster withdrawal amount must be a positive exact multiple of 0.1 ETH",
    );
  }
}

export function totalTornadoSpendableBalance(notes) {
  let total = 0n;
  for (const note of notes ?? []) {
    if (BigInt(note.balance ?? 0) <= 0n) continue;
    total += BigInt(note.amount ?? 0);
  }
  return total;
}

export function largestTornadoSpendableDenomination(notes) {
  let largest = 0n;
  for (const note of notes ?? []) {
    if (BigInt(note.balance ?? 0) <= 0n) continue;
    const denomination = BigInt(note.amount ?? 0);
    if (denomination > largest) largest = denomination;
  }
  return largest;
}

/**
 * Select the fewest spendable notes that exactly cover `amountWei`.
 * Tornado ETH denominations form a canonical 10x series, so descending greedy
 * selection is exact whenever the wallet's finite note inventory can cover the
 * requested 0.1-ETH multiple.
 */
export function selectTornadoWithdrawals(notes, amountWei) {
  if (amountWei <= 0n) {
    throw new Error("tornado withdrawal amount must be positive");
  }
  const counts = new Map();
  for (const note of notes ?? []) {
    if (BigInt(note.balance ?? 0) <= 0n) continue;
    const denomination = BigInt(note.amount ?? 0);
    if (denomination <= 0n) continue;
    counts.set(denomination, (counts.get(denomination) ?? 0) + 1);
  }
  const denominations = [...counts.keys()].sort((a, b) =>
    a > b ? -1 : a < b ? 1 : 0
  );
  let coveredWei = 0n;
  let withdrawalCount = 0;
  for (const denomination of denominations) {
    let remaining = counts.get(denomination);
    while (remaining > 0 && coveredWei + denomination <= amountWei) {
      coveredWei += denomination;
      withdrawalCount++;
      remaining--;
    }
  }
  if (coveredWei !== amountWei) {
    throw new Error(
      `spendable Tornado notes cannot exactly cover ${amountWei} wei ` +
        `(best exact-prefix coverage ${coveredWei} wei)`,
    );
  }
  return { amountWei, coveredWei, withdrawalCount };
}

function withdrawAmountWei(params, notes, mode) {
  if (params?.amountMax === true || String(params?.amountEth).toLowerCase() === "max") {
    return mode === "relayer"
      ? largestTornadoSpendableDenomination(notes)
      : totalTornadoSpendableBalance(notes);
  }
  return amountWeiOf(params);
}

function isMaxWithdrawAmount(params) {
  return params?.amountMax === true || String(params?.amountEth).toLowerCase() === "max";
}

function withdrawMode(params) {
  const mode = params?.mode ?? "paymaster";
  if (mode !== "paymaster" && mode !== "relayer") {
    throw new Error(`mode must be "paymaster" or "relayer" (got ${mode})`);
  }
  return mode;
}

// User-supplied tail calls, validated by the Lean daemon and re-validated
// here (defense in depth). Wire shape: [{to, data, valueWei}] with valueWei a
// decimal string; values are paid out of the withdrawal after the fee.
export function parseTailCallsParam(params) {
  const raw = params?.tailCalls;
  if (raw == null) return [];
  if (!Array.isArray(raw)) throw new Error("tailCalls must be an array");
  return raw.map((entry, index) => {
    const to = String(entry?.to ?? "");
    const data = String(entry?.data ?? "0x");
    const valueRaw = entry?.valueWei ?? entry?.value ?? 0;
    if (!/^0x[0-9a-fA-F]{40}$/.test(to)) {
      throw new Error(`invalid tail call target at index ${index}: ${to}`);
    }
    if (!/^0x(?:[0-9a-fA-F]{2})*$/.test(data)) {
      throw new Error(`invalid tail call calldata at index ${index}: expected 0x-prefixed byte-aligned hex`);
    }
    let value;
    try {
      value = BigInt(valueRaw);
    } catch {
      throw new Error(`invalid tail call value at index ${index}: ${valueRaw}`);
    }
    if (value < 0n) throw new Error(`invalid tail call value at index ${index}: must be >= 0`);
    return { to, data, value };
  });
}

export function totalTailCallValue(tailCalls) {
  return tailCalls.reduce((sum, call) => sum + call.value, 0n);
}

export function tornadoPaymasterUnshieldOptions(
  recipientDerivationPath,
  tailCalls = [],
  tailCallsGasEstimate,
) {
  return {
    mode: "paymaster",
    delegation: { mode: "deterministic", path: recipientDerivationPath },
    ...(tailCallsGasEstimate !== undefined ? { tailCallsGasEstimate } : {}),
    // The deterministic delegator is the recipient itself. With no user calls,
    // omit `tailCalls` so alpha.18 uses its cheaper automatic-forward path.
    // With user calls, unspent proceeds remain on that recipient account.
    ...(tailCalls.length > 0
      ? {
          tailCalls: async () =>
            tailCalls.map((call) => ({
              to: call.to,
              data: call.data,
              value: call.value,
            })),
        }
      : {}),
  };
}

/** Extract the exact fee embedded in the SDK-created sponsoring proof. */
export function paymasterFeeWeiFromOperation(operation) {
  const withdrawals = operation?.withdrawals;
  if (!Array.isArray(withdrawals) || withdrawals.length !== 1) {
    throw new Error("tornado paymaster prepare returned an invalid withdrawal batch");
  }
  const withdrawal = withdrawals[0];
  if (withdrawal?.mode !== "paymaster" || !Array.isArray(withdrawal?.proof?.args)) {
    throw new Error("tornado paymaster prepare returned no sponsoring proof");
  }
  const rawFee = withdrawal.proof.args[4];
  try {
    const fee = BigInt(rawFee);
    if (fee < 0n) throw new Error("negative fee");
    return fee;
  } catch {
    throw new Error("tornado paymaster prepare returned an invalid proof fee");
  }
}

/** Sum the exact fees embedded in SDK-created relayer proofs. */
export function relayerFeeWeiFromOperation(operation) {
  const withdrawals = operation?.withdrawals;
  if (!Array.isArray(withdrawals) || withdrawals.length === 0) {
    throw new Error("tornado relayer prepare returned no withdrawals");
  }
  let total = 0n;
  for (const withdrawal of withdrawals) {
    if (withdrawal?.mode !== "relayer" || !Array.isArray(withdrawal?.proof?.args)) {
      throw new Error("tornado relayer prepare returned an invalid proof");
    }
    try {
      const fee = BigInt(withdrawal.proof.args[4]);
      if (fee < 0n) throw new Error("negative fee");
      total += fee;
    } catch {
      throw new Error("tornado relayer prepare returned an invalid proof fee");
    }
  }
  return total;
}

export function assertTornadoBroadcastResults(operation, relay) {
  const expected = operation?.withdrawals?.length;
  if (!Number.isSafeInteger(expected) || expected <= 0) {
    throw new Error("tornado broadcast received an invalid prepared operation");
  }
  if (!Array.isArray(relay) || relay.length !== expected) {
    throw new Error(
      `tornado broadcaster reported ${Array.isArray(relay) ? relay.length : 0} ` +
        `successful submission(s) for ${expected} prepared withdrawal(s)`,
    );
  }
  return relay;
}

async function assertPaymasterReceiptsSucceeded(bundlerUrl, relay) {
  for (const result of relay) {
    const userOpHash = result?.id;
    if (typeof userOpHash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(userOpHash)) {
      throw new Error("tornado paymaster broadcaster returned an invalid UserOperation hash");
    }
    const response = await fetch(bundlerUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_getUserOperationReceipt",
        params: [userOpHash],
      }),
    });
    if (!response.ok) {
      throw new Error(
        `unable to verify Tornado UserOperation ${userOpHash}: HTTP ${response.status}`,
      );
    }
    const body = await response.json();
    if (body?.result?.success !== true) {
      throw new Error(
        body?.result?.success === false
          ? `Tornado UserOperation ${userOpHash} was included but reverted`
          : `unable to verify successful inclusion of Tornado UserOperation ${userOpHash}`,
      );
    }
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

// Build but do not broadcast the withdrawal. The SDK may replace its baseline
// gas values after a bundler estimate, so only the fee embedded in the prepared
// proof is safe to present as a confirmation ceiling.
async function tornadoQuoteWithdraw(env, params) {
  const recipient = requireRecipient(params);
  requireRecipientDerivationPath(params);
  const explicitAmountWei = isMaxWithdrawAmount(params) ? null : amountWeiOf(params);
  const mode = withdrawMode(params);
  if (explicitAmountWei !== null) {
    assertWithdrawAmount(explicitAmountWei, BigInt(env.LEANCLI_CHAIN_ID), mode);
  }
  const tailCalls = parseTailCallsParam(params);
  if (mode !== "paymaster" && tailCalls.length > 0) {
    throw new Error("tail calls are only supported in paymaster mode");
  }
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  if (plugin.sync) await plugin.sync();
  const notes = await plugin.notes([tornadoEthAsset(tc)]);
  const amountWei = explicitAmountWei ?? withdrawAmountWei(params, notes, mode);
  assertWithdrawAmount(amountWei, BigInt(env.LEANCLI_CHAIN_ID), mode);
  const spendable = notes.filter((n) => BigInt(n.balance ?? 0) > 0n);
  const spendableTotal = totalTornadoSpendableBalance(spendable);
  const selection = selectTornadoWithdrawals(spendable, amountWei);
  if (mode === "relayer" && selection.withdrawalCount !== 1) {
    throw new Error("tornado relayer mode supports exactly one note per withdrawal");
  }

  const base = {
    chainId: env.LEANCLI_CHAIN_ID,
    recipient,
    amountWei,
    // Kept for older clients. It is the total only for a multi-note quote.
    denominationWei: amountWei,
    mode,
    spendableTotalWei: spendableTotal,
    withdrawalCount: selection.withdrawalCount,
  };
  if (mode === "paymaster") {
    const bundlerUrl = bundlerUrlFor(plugin.__chainId, env.LEANCLI_TC_BUNDLER_URL);
    const {
      estimateTornadoPaymasterFee,
      fetchTornadoMaxFeePerGas,
      tornadoWithdrawalCallGasLimit,
    } =
      await import("./tornado-paymaster-gas.mjs");
    const maxFeePerGas = await fetchTornadoMaxFeePerGas(bundlerUrl);
    const { resolveTornadoTailCallsGasEstimate } =
      await import("./tornado-tail-gas.mjs");
    const tailCallsGasEstimate = await resolveTornadoTailCallsGasEstimate({
      rpcUrl: env.LEANCLI_RPC_URL,
      account: recipient,
      amountWei,
      maxFeePerGas,
      extraWithdrawals: selection.withdrawalCount - 1,
      userTailCalls: tailCalls,
    });
    const callGasLimit = tornadoWithdrawalCallGasLimit(
      selection.withdrawalCount - 1,
      tailCallsGasEstimate,
    );
    const baselineFeeWei = estimateTornadoPaymasterFee(maxFeePerGas, {
      callGasLimit,
    });
    const baselineAfterFeeWei = amountWei - baselineFeeWei;
    if (baselineAfterFeeWei <= 0n) {
      throw new Error(
        `withdrawal amount too small to cover the tornado paymaster fee (~${baselineFeeWei} wei)`,
      );
    }
    const tailValueWei = totalTailCallValue(tailCalls);
    if (tailValueWei > baselineAfterFeeWei) {
      throw new Error(
        `tail call value total (${tailValueWei} wei) exceeds the amount remaining after the tornado paymaster fee (${baselineAfterFeeWei} wei)`,
      );
    }
    console.error(
      `[bridge] tornado: preparing paymaster quote to=${recipient} notes=${selection.withdrawalCount}`,
    );
    const operation = await plugin.prepareUnshield(
      { asset: tornadoEthAsset(tc), amount: amountWei },
      recipient,
      tornadoPaymasterUnshieldOptions(
        requireRecipientDerivationPath(params),
        tailCalls,
        tailCallsGasEstimate,
      ),
    );
    const feeWei = paymasterFeeWeiFromOperation(operation);
    const afterFeeWei = amountWei - feeWei;
    if (afterFeeWei <= 0n) {
      throw new Error(
        `withdrawal amount too small to cover the prepared tornado paymaster fee (${feeWei} wei)`,
      );
    }
    if (tailValueWei > afterFeeWei) {
      throw new Error(
        `tail call value total (${tailValueWei} wei) exceeds the amount remaining after the prepared tornado paymaster fee (${afterFeeWei} wei)`,
      );
    }
    const netWei = afterFeeWei - tailValueWei;
    return {
      ...base,
      paymasterFeeWei: feeWei,
      baselinePaymasterFeeWei: baselineFeeWei,
      netWei,
      maxFeePerGasWei: maxFeePerGas,
      callGasLimit,
      tailCallsGasEstimate,
      tailCallCount: tailCalls.length,
      tailValueWei,
    };
  }
  const ens = Array.isArray(params?.preferredRelayersEns)
    ? params.preferredRelayersEns
    : undefined;
  console.error(`[bridge] tornado: preparing relayer quote to=${recipient}`);
  const operation = await plugin.prepareUnshield(
    { asset: tornadoEthAsset(tc), amount: amountWei },
    recipient,
    {
      mode: "relayer",
      ...(ens && ens.length ? { preferredRelayersEns: ens } : {}),
    },
  );
  const relayerFeeWei = relayerFeeWeiFromOperation(operation);
  if (relayerFeeWei >= amountWei) {
    throw new Error(
      `tornado relayer fee ${relayerFeeWei} wei consumes the withdrawal`,
    );
  }
  return {
    ...base,
    relayerFeeWei,
    netWei: amountWei - relayerFeeWei,
  };
}

async function tornadoExecuteWithdraw(env, params) {
  const recipient = requireRecipient(params);
  const recipientDerivationPath = requireRecipientDerivationPath(params);
  const explicitAmountWei = isMaxWithdrawAmount(params) ? null : amountWeiOf(params);
  const mode = withdrawMode(params);
  if (explicitAmountWei !== null) {
    assertWithdrawAmount(explicitAmountWei, BigInt(env.LEANCLI_CHAIN_ID), mode);
  }
  const tailCalls = parseTailCallsParam(params);
  if (mode !== "paymaster" && tailCalls.length > 0) {
    throw new Error("tail calls are only supported in paymaster mode");
  }
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  if (plugin.sync) await plugin.sync();
  const notes = await plugin.notes([tornadoEthAsset(tc)]);
  const amountWei = explicitAmountWei ?? withdrawAmountWei(params, notes, mode);
  assertWithdrawAmount(amountWei, BigInt(env.LEANCLI_CHAIN_ID), mode);
  const asset = { asset: tornadoEthAsset(tc), amount: amountWei };
  const selection = selectTornadoWithdrawals(notes, amountWei);
  if (mode === "relayer" && selection.withdrawalCount !== 1) {
    throw new Error("tornado relayer mode supports exactly one note per withdrawal");
  }

  let op;
  if (params?.maxFeeWei == null) {
    throw new Error(`${mode} execution requires maxFeeWei from a confirmed quote`);
  }
  const maxFeeWei = BigInt(params.maxFeeWei);
  if (maxFeeWei < 0n) throw new Error("maxFeeWei must be non-negative");
  if (mode === "paymaster") {
    const bundlerUrl = bundlerUrlFor(plugin.__chainId, env.LEANCLI_TC_BUNDLER_URL);
    const {
      estimateTornadoPaymasterFee,
      fetchTornadoMaxFeePerGas,
      tornadoWithdrawalCallGasLimit,
    } =
      await import("./tornado-paymaster-gas.mjs");
    const maxFeePerGas = await fetchTornadoMaxFeePerGas(bundlerUrl);
    const { resolveTornadoTailCallsGasEstimate } =
      await import("./tornado-tail-gas.mjs");
    const tailCallsGasEstimate = await resolveTornadoTailCallsGasEstimate({
      rpcUrl: env.LEANCLI_RPC_URL,
      account: recipient,
      amountWei,
      maxFeePerGas,
      extraWithdrawals: selection.withdrawalCount - 1,
      userTailCalls: tailCalls,
    });
    const callGasLimit = tornadoWithdrawalCallGasLimit(
      selection.withdrawalCount - 1,
      tailCallsGasEstimate,
    );
    const feeWei = estimateTornadoPaymasterFee(maxFeePerGas, { callGasLimit });
    // H2: the fee is recomputed here from a fresh (untrusted) bundler gas
    // price, decoupled from the quote the user confirmed. Enforce the
    // confirmed ceiling so a gas spike, or a bundler reporting an inflated
    // price, cannot silently increase the fee paid from the withdrawn notes.
    // The caller passes the quoted proof fee as `maxFeeWei`.
    if (feeWei > maxFeeWei) {
      throw new Error(
        `tornado paymaster fee ${feeWei} wei exceeds the confirmed ceiling ${maxFeeWei} wei ` +
        `(gas price rose since the quote) — re-quote and confirm before withdrawing`,
      );
    }
    const afterFeeWei = amountWei - feeWei;
    if (afterFeeWei <= 0n) {
      throw new Error(`withdrawal amount too small to cover the tornado paymaster fee (~${feeWei} wei)`);
    }
    const tailValueWei = totalTailCallValue(tailCalls);
    if (tailValueWei > afterFeeWei) {
      throw new Error(
        `tail call value total (${tailValueWei} wei) exceeds the amount remaining after the tornado paymaster fee (${afterFeeWei} wei)`,
      );
    }
    console.error(`[bridge] tornado: prepareUnshield paymaster to=${recipient} notes=${selection.withdrawalCount} tails=${tailCalls.length}`);
    op = await plugin.prepareUnshield(
      asset,
      recipient,
      tornadoPaymasterUnshieldOptions(
        recipientDerivationPath,
        tailCalls,
        tailCallsGasEstimate,
      ),
    );
    // Enforce the confirmed ceiling against the fee actually encoded in this
    // freshly prepared proof before handing the operation to the broadcaster.
    const preparedFeeWei = paymasterFeeWeiFromOperation(op);
    if (preparedFeeWei > maxFeeWei) {
      throw new Error(
        `prepared tornado paymaster fee ${preparedFeeWei} wei exceeds the ` +
          `confirmed ceiling ${maxFeeWei} wei — re-quote and confirm`,
      );
    }
  } else {
    const ens = Array.isArray(params?.preferredRelayersEns) ? params.preferredRelayersEns : undefined;
    console.error(`[bridge] tornado: prepareUnshield relayer to=${recipient}`);
    op = await plugin.prepareUnshield(asset, recipient, {
      mode: "relayer",
      ...(ens && ens.length ? { preferredRelayersEns: ens } : {}),
    });
    const preparedFeeWei = relayerFeeWeiFromOperation(op);
    if (preparedFeeWei > maxFeeWei) {
      throw new Error(
        `prepared tornado relayer fee ${preparedFeeWei} wei exceeds the ` +
          `confirmed ceiling ${maxFeeWei} wei — re-quote and confirm`,
      );
    }
  }

  const broadcaster = tc.createTCBroadcaster(plugin.__host, {
    paymasterConfig: tornadoPaymasterConfig(tc, plugin.__chainId, env.LEANCLI_TC_BUNDLER_URL),
  });
  console.error(`[bridge] tornado: broadcasting ${mode} withdrawal`);
  const relay = assertTornadoBroadcastResults(
    op,
    await broadcaster.broadcast(op),
  );
  if (mode === "paymaster") {
    await assertPaymasterReceiptsSucceeded(
      bundlerUrlFor(plugin.__chainId, env.LEANCLI_TC_BUNDLER_URL),
      relay,
    );
  }
  return {
    chainId: env.LEANCLI_CHAIN_ID,
    recipient,
    amountWei,
    withdrawalCount: selection.withdrawalCount,
    mode,
    relay,
  };
}

// ---- Note vault (export / verify) -----------------------------------------
//
// This SDK derives note secrets deterministically under the wallet's hardened
// m/29795'/1' subtree, so there is no classic "note string" to save. The vault
// exists to (a) let a user back up the derived secrets so a note remains
// recoverable even if the on-disk indexer state is lost, and (b) let a user
// import a backup taken elsewhere and confirm which notes belong to *this*
// wallet before trusting them. The secrets are sensitive: the Lean daemon
// encrypts the exported blob under a user password (LeanCli/Privacy/NoteVault)
// before it touches disk, and re-derives from the seed on import to verify.

// Build a SecretManager bound to this wallet's keystore. Mirrors the plugin's
// own internal derivation, so a re-derived commitment must match the on-chain
// note's commitment iff the note belongs to this wallet.
async function tornadoSecretManager(env) {
  const { tc } = await loadTornado();
  return tc.SecretManager({ host: { keystore: keystoreFromEnv(env) }, accountIndex: 0 });
}

// Derive the full secret set for one note (pool + depositIndex).
async function deriveNoteSecrets(secretManager, chainId, note) {
  const s = await secretManager.getDepositSecrets({
    chainId,
    poolAddress: BigInt(note.pool),
    depositIndex: Number(note.depositIndex),
  });
  return {
    nullifier: s.nullifier,
    salt: s.salt,
    commitment: s.commitment,
    nullifierHash: s.nullifierHash,
  };
}

// Export every note (optionally including spent) with its derived secrets, so
// the daemon can seal the blob under a user password. BigInts render as hex.
async function tornadoExportNotes(env, params) {
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  if (plugin.sync) await plugin.sync();
  const chainId = BigInt(env.LEANCLI_CHAIN_ID);
  const includeSpent = params?.includeSpent !== false; // default: include spent
  const notes = await plugin.notes([tornadoEthAsset(tc)], includeSpent);
  const secretManager = await tornadoSecretManager(env);
  const exported = [];
  for (const n of notes) {
    const secrets = await deriveNoteSecrets(secretManager, chainId, n);
    exported.push({
      pool: n.pool,
      denominationWei: n.amount,
      balanceWei: n.balance,
      depositIndex: n.depositIndex,
      leafIndex: n.leafIndex,
      commitment: n.commitment,
      timestamp: n.timestamp,
      status: BigInt(n.balance ?? 0) > 0n ? "spendable" : "spent",
      secrets,
    });
  }
  return { chainId: env.LEANCLI_CHAIN_ID, asset: tc.E_ADDRESS, count: exported.length, notes: exported };
}

// Verify imported note descriptors against this wallet's seed: re-derive each
// note's commitment from (pool, depositIndex) and check it matches the imported
// commitment. A match proves the note is recoverable from the current seed.
// Cross-reference the live indexer to report current spent/spendable status.
async function tornadoVerifyNotes(env, params) {
  const imported = Array.isArray(params?.notes) ? params.notes : null;
  if (!imported) throw new Error("verifyNotes requires a `notes` array");
  const plugin = await buildTornadoPlugin(env);
  const tc = plugin.__tc;
  if (plugin.sync) await plugin.sync();
  const chainId = BigInt(env.LEANCLI_CHAIN_ID);
  const live = await plugin.notes([tornadoEthAsset(tc)], true);
  const liveByKey = new Map(
    live.map((n) => [`${BigInt(n.pool)}-${Number(n.depositIndex)}`, n]),
  );
  const secretManager = await tornadoSecretManager(env);
  // Project down to non-secret identifiers only. NEVER spread `...n` back: an
  // imported note carries its derived `secrets` (nullifier/salt/…), and the
  // daemon returns this result verbatim, so echoing the whole note would leak
  // seed-derived secrets through the RPC response even on the failure branches.
  const view = (n, mine, extra) => ({
    pool: n?.pool ?? null,
    depositIndex: n?.depositIndex ?? null,
    commitment: n?.commitment ?? null,
    mine,
    ...extra,
  });
  // BigInt() throws on non-numeric input; imported descriptors are untrusted,
  // so coerce defensively — a bad field yields a per-note failure, never a
  // whole-call abort.
  const asBig = (v) => { try { return BigInt(v); } catch { return null; } };
  const results = [];
  for (const n of imported) {
    if (n?.pool == null || n?.depositIndex == null || n?.commitment == null) {
      results.push(view(n, false, { reason: "missing pool/depositIndex/commitment" }));
      continue;
    }
    let derived;
    try {
      derived = await deriveNoteSecrets(secretManager, chainId, n);
    } catch (e) {
      results.push(view(n, false, { reason: `derive failed: ${e?.message ?? e}` }));
      continue;
    }
    const importedCommitment = asBig(n.commitment);
    if (importedCommitment === null) {
      results.push(view(n, false, { reason: "malformed commitment" }));
      continue;
    }
    const mine = BigInt(derived.commitment) === importedCommitment;
    const liveNote = liveByKey.get(`${BigInt(n.pool)}-${Number(n.depositIndex)}`);
    const status = liveNote
      ? (BigInt(liveNote.balance ?? 0) > 0n ? "spendable" : "spent")
      : "unknown";
    results.push({
      ...view(n, mine, {}),
      denominationWei: n.denominationWei ?? liveNote?.amount,
      status,
      onChain: liveNote != null,
    });
  }
  return {
    chainId: env.LEANCLI_CHAIN_ID,
    count: results.length,
    mineCount: results.filter((r) => r.mine).length,
    notes: results,
  };
}

/**
 * Dispatch a `shielded.tornado.*` method. Returns the result object (BigInts
 * are rendered as hex by bridge.mjs's jsonifyResult); throws on error.
 */
export async function dispatchTornado(method, env, params) {
  switch (method) {
    case "shielded.tornado.balance": return await tornadoBalance(env);
    case "shielded.tornado.notes": return await tornadoNotes(env, params);
    case "shielded.tornado.maxUnshield": {
      const plugin = await buildTornadoPlugin(env);
      const tc = plugin.__tc;
      if (plugin.sync) await plugin.sync();
      const notes = await plugin.notes([tornadoEthAsset(tc)]);
      return {
        chainId: env.LEANCLI_CHAIN_ID,
        amountWei: totalTornadoSpendableBalance(notes),
        scope: "total-spendable-balance",
      };
    }
    case "shielded.tornado.prepareDeposit": return await tornadoPrepareDeposit(env, params);
    case "shielded.tornado.quoteWithdraw": return await tornadoQuoteWithdraw(env, params);
    case "shielded.tornado.executeWithdraw": return await tornadoExecuteWithdraw(env, params);
    case "shielded.tornado.exportNotes": return await tornadoExportNotes(env, params);
    case "shielded.tornado.verifyNotes": return await tornadoVerifyNotes(env, params);
    default: throw new Error(`unknown tornado method: ${method}`);
  }
}

export const TORNADO_METHODS = new Set([
  "shielded.tornado.balance",
  "shielded.tornado.notes",
  "shielded.tornado.maxUnshield",
  "shielded.tornado.prepareDeposit",
  "shielded.tornado.quoteWithdraw",
  "shielded.tornado.executeWithdraw",
  "shielded.tornado.exportNotes",
  "shielded.tornado.verifyNotes",
]);
