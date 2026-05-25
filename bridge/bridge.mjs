#!/usr/bin/env node
// Why: re-exec under our ESM loader if it isn't active yet. The loader
// patches one extension-less import in @kohaku-eth/privacy-pools' bundle.
if (!process.env.__LEANKOHAKU_BRIDGE_LOADED) {
  const { spawnSync } = await import("node:child_process");
  const { fileURLToPath } = await import("node:url");
  const { dirname, join } = await import("node:path");
  const here = dirname(fileURLToPath(import.meta.url));
  const loader = join(here, "loader.mjs");
  const result = spawnSync(
    process.execPath,
    ["--no-warnings", "--experimental-loader", loader, fileURLToPath(import.meta.url), ...process.argv.slice(2)],
    { stdio: "inherit", env: { ...process.env, __LEANKOHAKU_BRIDGE_LOADED: "1" } },
  );
  process.exit(result.status ?? 1);
}

// leankohaku-kohaku-bridge — untrusted JSON-RPC sidecar for the leanKohaku
// daemon (LeanKohaku/Privacy/Bridge.lean).
//
// SECURITY: This process is trusted to perform Railgun / privacy-pools
// circuit work but UNTRUSTED for transaction structure. The Lean side
// must re-decode every prepared tx and only sign through the existing
// TPM-rooted path. Network egress from this process must be bound to the
// daemon's policy (LEANKOHAKU_RPC_URL passed by the daemon spawn site).

import { createPublicClient, http, parseEther } from "viem";
import { sepolia, mainnet } from "viem/chains";
import { HDKey } from "@scure/bip32";
import { mnemonicToSeedSync } from "@scure/bip39";
import { withChunkedGetLogs } from "./chunked-get-logs.mjs";
import * as fsSync from "node:fs";
import * as pathMod from "node:path";

// Why: @kohaku-eth/privacy-pools transitively imports `maci-crypto/...` with
// bare specifiers that Node ESM cannot resolve without an explicit loader.
// We dynamic-import it (and provider/viem) only inside shielded handlers so
// `ping` / `version` / `listProtocols` keep working without the loader hack.
async function loadKohaku() {
  const pp = await import("@kohaku-eth/privacy-pools");
  const provider = await import("@kohaku-eth/provider/viem");
  return { pp, provider };
}

// Why: @kohaku-eth/railgun's index does a top-level `await initialize()` that
// loads the wasm blob. We only want to pay that cost on shielded.railgun.*
// methods, so the import is lazy.
async function loadRailgun() {
  const rg = await import("@kohaku-eth/railgun");
  const provider = await import("@kohaku-eth/provider/viem");
  return { rg, provider };
}

const PROTOCOL_VERSION = "0.0.1";

function jsonrpcResult(id, result) {
  return JSON.stringify({ jsonrpc: "2.0", id: id ?? null, result });
}

function jsonrpcError(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  return JSON.stringify({ jsonrpc: "2.0", id: id ?? null, error });
}

function methodNotFound(id, method) {
  return jsonrpcError(id, -32601, `method not found: ${method}`);
}

// Why: BigInt does not survive JSON.stringify; the Lean side decodes hex/string
// numerics before re-encoding to typed-tx, so we render every BigInt as a
// 0x-prefixed hex string with a sentinel-free shape.
function jsonReplacer(_key, value) {
  if (typeof value === "bigint") return "0x" + value.toString(16);
  if (value instanceof Uint8Array) {
    return "0x" + Buffer.from(value).toString("hex");
  }
  return value;
}

function jsonifyResult(id, result) {
  return JSON.stringify({ jsonrpc: "2.0", id: id ?? null, result }, jsonReplacer);
}

// File-backed Storage. Why: the PP plugin's per-account bookkeeping (which
// deposit index is ours, secret hashes, etc) MUST survive across bridge
// invocations. Without it, prepareUnshield fails with "Leaf not found in
// the leaves array" because the plugin can't map our spending secrets back
// to on-chain commitments. Mirrors upstream kohaku-cli's encrypted store
// without the AES layer (the key material is in LEANKOHAKU_PP_MNEMONIC).
function fileStorage(storagePath) {
  let store = {};
  try {
    const raw = fsSync.readFileSync(storagePath, "utf8");
    store = JSON.parse(raw);
    console.error(`[bridge] loaded PP storage from ${storagePath} (${Object.keys(store).length} keys)`);
  } catch (e) {
    if (e?.code !== "ENOENT") {
      console.error(`[bridge] PP storage read failed: ${e?.message ?? e}; starting empty`);
    }
  }
  function flush() {
    try {
      fsSync.mkdirSync(pathMod.dirname(storagePath), { recursive: true });
      const tmp = `${storagePath}.tmp`;
      fsSync.writeFileSync(tmp, JSON.stringify(store));
      fsSync.renameSync(tmp, storagePath);
    } catch (e) {
      console.error(`[bridge] PP storage write failed: ${e?.message ?? e}`);
    }
  }
  return {
    _brand: "Storage",
    get(key) { return key in store ? store[key] : null; },
    set(key, value) { store[key] = value; flush(); },
  };
}

function inMemoryNetwork() {
  return {
    fetch: (input, init) => fetch(input, init),
  };
}

function chainFromId(id) {
  switch (Number(id)) {
    case 1: return mainnet;
    case 11155111: return sepolia;
    default: throw new Error(`unsupported chainId: ${id}`);
  }
}

function entrypointFor(chainId, presets) {
  const cfg = presets[Number(chainId)];
  if (!cfg) throw new Error(`PrivacyPools 0xBow has no entrypoint for chainId=${chainId}`);
  return cfg.entrypoint;
}

// Why: PPv1Plugin uses the host keystore via deriveAt(path) to derive its own
// nullifier/salt material. We back this with a dedicated mnemonic
// (LEANKOHAKU_PP_MNEMONIC) so the privacy-pools spending secret is separate
// from the EOA mnemonic the daemon manages for signing.
function keystoreFromMnemonic(mnemonic) {
  const seed = mnemonicToSeedSync(mnemonic);
  const master = HDKey.fromMasterSeed(seed);
  return {
    deriveAt(path) {
      const child = master.derive(path);
      if (!child.privateKey) throw new Error("keystore: no private key at " + path);
      return "0x" + Buffer.from(child.privateKey).toString("hex");
    },
  };
}

function buildHost({ rpcUrl, chainId, mnemonic, viemProvider, storagePath }) {
  if (!rpcUrl) throw new Error("LEANKOHAKU_RPC_URL is required");
  if (!chainId) throw new Error("LEANKOHAKU_CHAIN_ID is required");
  if (!mnemonic) throw new Error("LEANKOHAKU_PP_MNEMONIC is required (privacy-pools spending secret, separate from EOA mnemonic)");
  const chain = chainFromId(chainId);
  const client = createPublicClient({ chain, transport: http(rpcUrl) });
  return {
    network: inMemoryNetwork(),
    storage: storagePath ? fileStorage(storagePath) : { _brand: "Storage", get: () => null, set: () => {} },
    keystore: keystoreFromMnemonic(mnemonic),
    provider: withChunkedGetLogs(viemProvider(client)),
  };
}

async function loadBundledState(chainId) {
  const fs = await import("node:fs/promises");
  const path = await import("node:path");
  const { fileURLToPath } = await import("node:url");
  const here = path.dirname(fileURLToPath(import.meta.url));
  const file = Number(chainId) === 11155111
    ? path.join(here, "ppv1-sepolia-state.json")
    : Number(chainId) === 1
      ? path.join(here, "ppv1-mainnet-state.json")
      : null;
  if (!file) return undefined;
  try {
    const raw = await fs.readFile(file, "utf8");
    console.error(`[bridge] loaded bundled PP state for chainId=${chainId} (${raw.length} bytes)`);
    return JSON.parse(raw);
  } catch (e) {
    console.error(`[bridge] bundled PP state read failed: ${e?.message ?? e}`);
    return undefined;
  }
}

async function loadInitialState(statePath) {
  if (!statePath) return undefined;
  const fs = await import("node:fs/promises");
  try {
    const raw = await fs.readFile(statePath, "utf8");
    const parsed = JSON.parse(raw);
    console.error(`[bridge] loaded cached PP state from ${statePath} (${raw.length} bytes)`);
    return parsed;
  } catch (e) {
    if (e?.code !== "ENOENT") {
      console.error(`[bridge] cached PP state read failed (${e?.message ?? e}); doing full sync`);
    } else {
      console.error(`[bridge] no cached PP state at ${statePath}; doing full sync`);
    }
    return undefined;
  }
}

async function persistState(statePath, plugin) {
  if (!statePath) return;
  try {
    const fs = await import("node:fs/promises");
    const path = await import("node:path");
    const dump = plugin.dumpState();
    const tmp = `${statePath}.tmp`;
    await fs.mkdir(path.dirname(statePath), { recursive: true });
    await fs.writeFile(tmp, JSON.stringify(dump));
    await fs.rename(tmp, statePath);
    console.error(`[bridge] persisted PP state to ${statePath}`);
  } catch (e) {
    console.error(`[bridge] PP state persist failed (non-fatal): ${e?.message ?? e}`);
  }
}

async function buildPlugin(env) {
  const chainId = BigInt(env.LEANKOHAKU_CHAIN_ID);
  console.error(`[bridge] loading kohaku SDK (chainId=${chainId}, rpc=${env.LEANKOHAKU_RPC_URL})`);
  const t0 = Date.now();
  const { pp, provider } = await loadKohaku();
  console.error(`[bridge] SDK loaded in ${Date.now() - t0}ms`);
  const host = buildHost({
    rpcUrl: env.LEANKOHAKU_RPC_URL,
    chainId,
    mnemonic: env.LEANKOHAKU_PP_MNEMONIC,
    viemProvider: provider.viem,
    storagePath: env.LEANKOHAKU_PP_STORAGE_PATH,
  });
  const ep = entrypointFor(chainId, pp.PrivacyPoolsV1_0xBow);
  const entrypoint = {
    address: BigInt(ep.entrypointAddress),
    deploymentBlock: BigInt(ep.deploymentBlock),
  };
  const broadcasterUrl = env.LEANKOHAKU_PP_BROADCASTER_URL || "https://fastrelay.xyz/relayer";
  console.error(`[bridge] entrypoint=0x${ep.entrypointAddress.toString(16)} broadcaster=${broadcasterUrl}`);
  const cachedState = await loadInitialState(env.LEANKOHAKU_PP_STATE_PATH);
  const bundledState = cachedState ? undefined : await loadBundledState(chainId);
  const initialState = cachedState ?? bundledState;
  const aspParams = Number(chainId) === 11155111
    ? {
        aspServiceFactory: () => new pp.OxBowAspService({
          network: host.network,
          aspUrl: "https://dw.0xbow.io",
        }),
      }
    : {};
  const plugin = pp.createPPv1Plugin(host, {
    accountIndex: 0,
    entrypoint,
    broadcasterUrl,
    ...aspParams,
    ...(initialState ? { initialState } : {}),
  });
  plugin.__host = host;
  plugin.__pp = pp;
  plugin.__broadcasterUrl = broadcasterUrl;
  return plugin;
}

// Build a Railgun plugin for alpha-21. Same host shape as PP plugin
// ({ network, storage, keystore, provider }); separate env vars + storage
// file so PP and Railgun never clobber each other's persisted state.
//
// `needBundler` controls whether the bundler + delegating signer must be
// configured. Balance/prepareShield don't need them; unshield/transfer do
// (the broadcast path is ERC-4337 + EIP-7702, not Waku). When
// `needBundler=true`, both LEANKOHAKU_RG_BUNDLER_URL and
// LEANKOHAKU_RG_DELEGATING_KEY must be set.
//
// EIP-7702 delegation model (per crates/userop-kit/src/railgun.rs in
// upstream ethereum/kohaku):
// - Railgun's paymaster (PAYMASTER = 0xBbbc…bB74) verifies on-chain that
//   each broadcast UserOp's eip7702Auth delegates the sender EOA to a
//   single hardcoded implementation (IMPL = 0x304a1b31d6cc77616951579bd373a4bd8aef4b4c).
// - Custom delegate targets (Ambire, Simple7702Account, etc.) are NOT
//   supported by the paymaster — the UserOp would fail verification.
// - The SDK builds AND signs the 7702 Authorization internally for every
//   broadcast. There is no separate one-time "delegate the EOA" step to
//   run; each UserOp carries its own auth, consumed on inclusion.
// - The delegating EOA only needs (a) to exist as a regular keypair, and
//   (b) enough gas to bootstrap if the bundler asks for it (Railgun pays
//   gas through a shielded fee note to the protocol paymaster, so the
//   EOA's ETH balance is largely incidental).
//
// EntryPoint version: railgun-rs targets EntryPoint 0.8 (ENTRY_POINT_08).
// The bundler URL must serve EP 0.8. Some bundlers expose distinct
// endpoints per EP version; using a 0.7/0.9-only endpoint will fail at
// estimateUserOperationGas or sendUserOperation.
//
// Why first invocation is slow: createRailgunPlugin syncs from Subsquid
// and (with POI enabled, the default) coordinates POI proofs via
// `ppoi.fdi.network/`. Subsequent calls reuse the persisted provider
// state in host.storage.
async function buildRailgunPlugin(env, { needBundler = false } = {}) {
  const chainId = BigInt(env.LEANKOHAKU_CHAIN_ID);
  console.error(`[bridge] loading railgun SDK (chainId=${chainId}, rpc=${env.LEANKOHAKU_RPC_URL})`);
  const t0 = Date.now();
  const { rg, provider } = await loadRailgun();
  console.error(`[bridge] railgun SDK loaded in ${Date.now() - t0}ms`);
  if (!env.LEANKOHAKU_RG_MNEMONIC) {
    throw new Error("LEANKOHAKU_RG_MNEMONIC is required (railgun keystore seed)");
  }
  if (!env.LEANKOHAKU_RG_STORAGE_PATH) {
    throw new Error("LEANKOHAKU_RG_STORAGE_PATH is required (railgun plugin state file)");
  }
  const chain = chainFromId(chainId);
  const client = createPublicClient({ chain, transport: http(env.LEANKOHAKU_RPC_URL) });
  const host = {
    network: inMemoryNetwork(),
    storage: fileStorage(env.LEANKOHAKU_RG_STORAGE_PATH),
    keystore: keystoreFromMnemonic(env.LEANKOHAKU_RG_MNEMONIC),
    provider: withChunkedGetLogs(provider.viem(client)),
  };

  let bundler;
  let delegating_account;
  if (needBundler) {
    if (!env.LEANKOHAKU_RG_BUNDLER_URL) {
      throw new Error("LEANKOHAKU_RG_BUNDLER_URL is required for railgun unshield/transfer (4337 bundler URL, e.g. Pimlico)");
    }
    if (!env.LEANKOHAKU_RG_DELEGATING_KEY) {
      throw new Error("LEANKOHAKU_RG_DELEGATING_KEY is required for railgun unshield/transfer (hex private key of the EIP-7702 delegating EOA)");
    }
    bundler = rg.Bundler.pimlico(env.LEANKOHAKU_RG_BUNDLER_URL);
    const key = env.LEANKOHAKU_RG_DELEGATING_KEY.startsWith("0x")
      ? env.LEANKOHAKU_RG_DELEGATING_KEY
      : "0x" + env.LEANKOHAKU_RG_DELEGATING_KEY;
    delegating_account = rg.Signer.privateKey(key);
  }

  const plugin = await rg.createRailgunPlugin(host, {
    keyIndex: 0,
    // POI defaults to true. The alpha-21 wasm has the working
    // ppoi.fdi.network/ endpoint baked in, so this works on both
    // mainnet and Sepolia. Set to false only for debugging.
    poi: true,
    ...(needBundler ? { bundler: { bundler, delegating_account } } : {}),
  });
  plugin.__rg = rg;
  plugin.__chain = chain;
  return plugin;
}

async function shieldedRailgunBalance(env) {
  const plugin = await buildRailgunPlugin(env);
  console.error("[bridge] railgun: querying balance (implicit sync + POI check)");
  const ts = Date.now();
  const balances = await plugin.balance(undefined);
  console.error(`[bridge] railgun: balance complete in ${Date.now() - ts}ms (${balances.length} asset entries)`);
  return {
    chainId: env.LEANKOHAKU_CHAIN_ID,
    balances,
  };
}

// Build a Railgun asset for shield. tokenAddress=null → native ETH
// (plugin wraps to WETH inside the shield op via shieldNative).
function railgunShieldAsset(tokenAddress) {
  if (!tokenAddress || tokenAddress === "") {
    return { __type: "native" };
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(tokenAddress)) {
    throw new Error(`tokenAddress must be 0x-prefixed 20 bytes or empty for native ETH; got ${tokenAddress}`);
  }
  return { __type: "erc20", contract: tokenAddress };
}

// Build a Railgun asset for unshield. In alpha-21 native ETH is supported:
// the plugin unshields as WETH and appends a `withdraw` tail call.
function railgunUnshieldAsset(tokenAddress) {
  if (!tokenAddress || tokenAddress === "") {
    return { __type: "native" };
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(tokenAddress)) {
    throw new Error(`tokenAddress must be 0x-prefixed 20 bytes or empty for native ETH; got ${tokenAddress}`);
  }
  return { __type: "erc20", contract: tokenAddress };
}

// Build a Railgun asset for transfer. ERC20-only at the SDK level —
// prepareTransfer's tokenGuard rejects non-erc20.
function railgunTransferAsset(tokenAddress) {
  if (!tokenAddress || !/^0x[0-9a-fA-F]{40}$/.test(tokenAddress)) {
    throw new Error(`tokenAddress required for railgun transfer (ERC20 only); got ${tokenAddress ?? "null"}`);
  }
  return { __type: "erc20", contract: tokenAddress };
}

async function shieldedRailgunPrepareShield(env, params) {
  const amountWei = params?.amountWei
    ? BigInt(params.amountWei)
    : parseEther(String(params?.amountEth ?? "0"));
  if (amountWei <= 0n) throw new Error("amount must be > 0");
  const asset = railgunShieldAsset(params?.tokenAddress);
  const plugin = await buildRailgunPlugin(env);
  console.error(`[bridge] railgun: prepareShield amount=${amountWei} asset=${JSON.stringify(asset)}`);
  const ts = Date.now();
  const txns = await plugin.prepareShield({ asset, amount: amountWei });
  console.error(`[bridge] railgun: prepareShield returned ${txns.length} tx(s) in ${Date.now() - ts}ms`);
  if (!txns || txns.length === 0) {
    throw new Error("railgun prepareShield returned no txns");
  }
  return {
    chainId: env.LEANKOHAKU_CHAIN_ID,
    asset,
    amountWei,
    txns,
  };
}

async function shieldedRailgunUnshield(env, params) {
  const recipient = params?.recipient;
  if (!recipient || !/^0x[0-9a-fA-F]{40}$/.test(recipient)) {
    throw new Error("recipient must be a 0x-prefixed 20-byte address");
  }
  const amountWei = params?.amountWei
    ? BigInt(params.amountWei)
    : parseEther(String(params?.amountEth ?? "0"));
  if (amountWei <= 0n) throw new Error("amount must be > 0");
  const asset = railgunUnshieldAsset(params?.tokenAddress);
  const plugin = await buildRailgunPlugin(env, { needBundler: true });
  console.error(`[bridge] railgun: prepareUnshield amount=${amountWei} to=${recipient} asset=${JSON.stringify(asset)}`);
  const op = await plugin.prepareUnshield({ asset, amount: amountWei }, recipient);
  console.error(`[bridge] railgun: broadcasting unshield via 4337 bundler`);
  await plugin.broadcast(op);
  return {
    chainId: env.LEANKOHAKU_CHAIN_ID,
    recipient,
    asset,
    amountWei,
    relay: { ok: true, transport: "erc4337" },
  };
}

async function shieldedRailgunTransfer(env, params) {
  const recipient = params?.recipient;
  if (!recipient || !/^0zk/.test(recipient)) {
    throw new Error("recipient must be a 0zk-prefixed RailgunAddress");
  }
  const amountWei = params?.amountWei
    ? BigInt(params.amountWei)
    : parseEther(String(params?.amountEth ?? "0"));
  if (amountWei <= 0n) throw new Error("amount must be > 0");
  const asset = railgunTransferAsset(params?.tokenAddress);
  const plugin = await buildRailgunPlugin(env, { needBundler: true });
  console.error(`[bridge] railgun: prepareTransfer amount=${amountWei} to=${recipient}`);
  const op = await plugin.prepareTransfer({ asset, amount: amountWei }, recipient);
  console.error(`[bridge] railgun: broadcasting transfer via 4337 bundler`);
  await plugin.broadcast(op);
  return {
    chainId: env.LEANKOHAKU_CHAIN_ID,
    recipient,
    tokenAddress: asset.contract,
    amountWei,
    relay: { ok: true, transport: "erc4337" },
  };
}

const E_ADDRESS = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

// Why: upstream kohaku-cli uses { __type: "erc20", contract: ETH_AS_ERC20 } for
// PP+ETH (string forms like "erc20:0xee.." silently mismatched).
function ethAsset() {
  return { __type: "erc20", contract: E_ADDRESS };
}

// Why: prepareShield may return either an array of TxData OR { txns: [...] }
// depending on SDK version. Mirrors kohaku-cli's toShieldTxs.
function extractTxns(op) {
  if (Array.isArray(op)) return op;
  if (op && Array.isArray(op.txns)) return op.txns;
  return null;
}

async function shieldedBalance(env) {
  const plugin = await buildPlugin(env);
  console.error("[bridge] syncing pool state");
  const ts = Date.now();
  if (plugin.sync) await plugin.sync();
  console.error(`[bridge] sync complete in ${Date.now() - ts}ms`);
  const balances = await plugin.balance([ethAsset()]);
  await persistState(env.LEANKOHAKU_PP_STATE_PATH, plugin);
  return {
    chainId: env.LEANKOHAKU_CHAIN_ID,
    asset: E_ADDRESS,
    balances,
  };
}

async function shieldedPrepareDeposit(env, params) {
  const amountWei = params?.amountWei
    ? BigInt(params.amountWei)
    : parseEther(String(params?.amountEth ?? "0"));
  if (amountWei <= 0n) throw new Error("amount must be > 0");
  const plugin = await buildPlugin(env);
  console.error(`[bridge] syncing for prepareShield(${amountWei} wei)`);
  const ts = Date.now();
  if (plugin.sync) await plugin.sync();
  console.error(`[bridge] sync complete in ${Date.now() - ts}ms; preparing shield op`);
  const op = await plugin.prepareShield({ asset: ethAsset(), amount: amountWei });
  const txns = extractTxns(op);
  if (!txns || txns.length === 0) {
    console.error(`[bridge] prepareShield op shape: ${JSON.stringify(op, jsonReplacer).slice(0, 400)}`);
    throw new Error("prepareShield returned no txns");
  }
  console.error(`[bridge] prepareShield returned ${txns.length} tx(s)`);
  await persistState(env.LEANKOHAKU_PP_STATE_PATH, plugin);
  return {
    chainId: env.LEANKOHAKU_CHAIN_ID,
    asset: E_ADDRESS,
    amountWei,
    txns,
  };
}

async function shieldedPrepareWithdraw(env, params) {
  const recipient = params?.recipient;
  if (!recipient || !/^0x[0-9a-fA-F]{40}$/.test(recipient)) {
    throw new Error("recipient must be a 0x-prefixed 20-byte address");
  }
  const amountWei = params?.amountWei
    ? BigInt(params.amountWei)
    : parseEther(String(params?.amountEth ?? "0"));
  if (amountWei <= 0n) throw new Error("amount must be > 0");
  const plugin = await buildPlugin(env);
  if (plugin.sync) await plugin.sync();
  let privateOp;
  try {
    privateOp = await plugin.prepareUnshield(
      { asset: ethAsset(), amount: amountWei },
      recipient,
    );
  } catch (e) {
    const msg = e?.message ?? String(e);
    if (msg.includes("Leaf not found")) {
      throw new Error(
        "Your deposit is not yet approved by the OxBow ASP (Approval Service Provider). " +
        "Privacy Pools v1 requires deposits to be in the ASP's merkle tree before they can be unshielded. " +
        "On Sepolia, OxBow processes approvals in batches — wait some time and try again. " +
        "Underlying SDK error: " + msg,
      );
    }
    throw e;
  }
  await persistState(env.LEANKOHAKU_PP_STATE_PATH, plugin);
  const broadcaster = plugin.__pp.createPPv1Broadcaster(plugin.__host, {
    broadcasterUrl: plugin.__broadcasterUrl,
  });
  console.error(`[bridge] broadcasting unshield via ${plugin.__broadcasterUrl}`);
  const relayResult = await broadcaster.broadcast(privateOp);
  return {
    chainId: env.LEANKOHAKU_CHAIN_ID,
    recipient,
    amountWei,
    relay: relayResult ?? { ok: true },
  };
}

// Why: PP v1 has no prepareUnshieldMulti. To drain a target larger than any
// single note we loop prepareUnshield + broadcast in this one bridge call,
// chunking by the largest available approved note each iteration.
async function shieldedUnshieldDrain(env, params) {
  const recipient = params?.recipient;
  if (!recipient || !/^0x[0-9a-fA-F]{40}$/.test(recipient)) {
    throw new Error("recipient must be a 0x-prefixed 20-byte address");
  }
  const target = params?.amountWei
    ? BigInt(params.amountWei)
    : parseEther(String(params?.amountEth ?? "0"));
  if (target <= 0n) throw new Error("amount must be > 0");
  const plugin = await buildPlugin(env);
  if (plugin.sync) await plugin.sync();
  const broadcaster = plugin.__pp.createPPv1Broadcaster(plugin.__host, {
    broadcasterUrl: plugin.__broadcasterUrl,
  });
  const sent = [];
  let remaining = target;
  let iter = 0;
  while (remaining > 0n) {
    iter += 1;
    const allNotes = await plugin.notes([ethAsset()]);
    const usable = allNotes
      .filter((n) => (n.approved ?? true) && BigInt(n.balance ?? 0) > 0n)
      .map((n) => ({ ...n, balanceBn: BigInt(n.balance) }))
      .sort((a, b) => (a.balanceBn < b.balanceBn ? 1 : a.balanceBn > b.balanceBn ? -1 : 0));
    if (usable.length === 0) {
      console.error(`[bridge] drain stop: no usable approved notes left; drained=${target - remaining} of ${target}`);
      break;
    }
    const biggest = usable[0].balanceBn;
    const chunk = remaining < biggest ? remaining : biggest;
    console.error(`[bridge] drain iter ${iter}: notes=${usable.length} biggest=${biggest} chunk=${chunk} remaining=${remaining}`);
    let op;
    try {
      op = await plugin.prepareUnshield({ asset: ethAsset(), amount: chunk }, recipient);
    } catch (e) {
      const msg = e?.message ?? String(e);
      if (msg.includes("Leaf not found")) {
        throw new Error(
          "ASP has not yet approved one of your deposits. Wait for OxBow ASP indexing and retry. Underlying: " + msg,
        );
      }
      throw e;
    }
    const relay = await broadcaster.broadcast(op);
    console.error(`[bridge] drain iter ${iter}: relay ${relay?.txHash ?? "unknown"}`);
    sent.push({ amountWei: chunk, relay: relay ?? { ok: true } });
    remaining -= chunk;
  }
  await persistState(env.LEANKOHAKU_PP_STATE_PATH, plugin);
  return {
    chainId: env.LEANKOHAKU_CHAIN_ID,
    recipient,
    targetWei: target,
    drainedWei: target - remaining,
    iterations: sent.length,
    sent,
  };
}

async function dispatch(req) {
  const { method, params, id } = req;
  const env = process.env;
  switch (method) {
    case "ping":
      return jsonrpcResult(id, {
        ok: true,
        bridge: "leankohaku-kohaku-bridge",
        protocol: PROTOCOL_VERSION,
        node: process.versions.node,
      });
    case "version":
      return jsonrpcResult(id, {
        bridge: PROTOCOL_VERSION,
        node: process.versions.node,
      });
    case "listProtocols":
      return jsonrpcResult(id, {
        protocols: [
          { name: "privacy-pools", status: "live", chains: [11155111, 1] },
          { name: "railgun", status: "live", chains: [11155111, 1] },
        ],
      });
    case "shielded.balance":
      return jsonifyResult(id, await shieldedBalance(env));
    case "shielded.prepareDeposit":
      return jsonifyResult(id, await shieldedPrepareDeposit(env, params));
    case "shielded.unshieldDrain":
      return jsonifyResult(id, await shieldedUnshieldDrain(env, params));
    case "shielded.prepareWithdraw":
      return jsonifyResult(id, await shieldedPrepareWithdraw(env, params));
    case "shielded.railgun.balance":
      return jsonifyResult(id, await shieldedRailgunBalance(env));
    case "shielded.railgun.prepareShield":
      return jsonifyResult(id, await shieldedRailgunPrepareShield(env, params));
    case "shielded.railgun.unshield":
      return jsonifyResult(id, await shieldedRailgunUnshield(env, params));
    case "shielded.railgun.transfer":
      return jsonifyResult(id, await shieldedRailgunTransfer(env, params));
    default:
      return methodNotFound(id, method);
  }
}

function parseArgvRpc(argv) {
  const i = argv.indexOf("--rpc");
  if (i < 0 || i + 1 >= argv.length) return null;
  try {
    return JSON.parse(argv[i + 1]);
  } catch (e) {
    return { __parseError: e.message };
  }
}

async function main() {
  const argv = process.argv.slice(2);
  const req = parseArgvRpc(argv);
  if (req === null) {
    process.stdout.write(
      jsonrpcError(null, -32700, "expected --rpc <json-rpc-request>") + "\n"
    );
    process.exit(2);
  }
  if (req.__parseError) {
    process.stdout.write(
      jsonrpcError(null, -32700, `parse error: ${req.__parseError}`) + "\n"
    );
    process.exit(2);
  }
  if (!req || typeof req.method !== "string") {
    process.stdout.write(
      jsonrpcError(req?.id ?? null, -32600, "invalid request") + "\n"
    );
    process.exit(2);
  }
  try {
    const out = await dispatch(req);
    process.stdout.write(out + "\n");
    process.exit(0);
  } catch (e) {
    process.stdout.write(
      jsonrpcError(req.id ?? null, -32000, `bridge error: ${e?.message ?? e}`,
        e?.stack ? { stack: String(e.stack).slice(0, 4000) } : undefined) + "\n",
    );
    process.exit(1);
  }
}

main();
