#!/usr/bin/env node
// Why: re-exec under our ESM loader if it isn't active yet. The loader
// patches one extension-less import in @kohaku-eth/privacy-pools' bundle.
if (!process.env.__LEANCLI_BRIDGE_LOADED) {
  const { spawnSync } = await import("node:child_process");
  const { fileURLToPath } = await import("node:url");
  const { dirname, join } = await import("node:path");
  const here = dirname(fileURLToPath(import.meta.url));
  const loader = join(here, "loader.mjs");
  const result = spawnSync(
    process.execPath,
    ["--no-warnings", "--experimental-loader", loader, fileURLToPath(import.meta.url), ...process.argv.slice(2)],
    { stdio: "inherit", env: { ...process.env, __LEANCLI_BRIDGE_LOADED: "1" } },
  );
  process.exit(result.status ?? 1);
}

// leancli-bridge — untrusted JSON-RPC sidecar for the leanCLI
// daemon (LeanCli/Privacy/Bridge.lean).
//
// SECURITY: This process is trusted to perform Railgun / privacy-pools
// circuit work but UNTRUSTED for transaction structure. The Lean side
// must re-decode every prepared tx and only sign through the existing
// TPM-rooted path. Network egress from this process must be bound to the
// daemon's policy (LEANCLI_RPC_URL passed by the daemon spawn site).
//
// STDOUT IS RESERVED FOR JSON-RPC. The Railgun SDK (`@kohaku-eth/railgun`)
// uses `console.log(...)` internally for progress diagnostics, which
// would pollute the response line the daemon reads back. We redirect
// all stdout console output to stderr at startup so the only thing that
// ever lands on stdout is the single JSON-RPC response line written by
// `main()` below.
console.log = (...args) => console.error(...args);
console.info = (...args) => console.error(...args);
console.warn = (...args) => console.error(...args);
console.debug = (...args) => console.error(...args);

import { createPublicClient, http, parseEther } from "viem";
import { sepolia, mainnet } from "viem/chains";
import { HDKey } from "@scure/bip32";
import { mnemonicToSeedSync } from "@scure/bip39";
import { withChunkedGetLogs } from "./chunked-get-logs.mjs";
import * as fsSync from "node:fs";
import * as pathMod from "node:path";
import {
  estimateRailgunBundlerFeeWei,
  fetchPimlicoMaxFeePerGas,
  largestSpendableNote,
  railgunMaxReceivableFromBalance,
} from "./max-amount.mjs";

// Why: @kohaku-eth/privacy-pools transitively imports `maci-crypto/...` with
// bare specifiers that Node ESM cannot resolve without an explicit loader.
// We dynamic-import it (and provider/viem) only inside shielded handlers so
// `ping` / `version` / `listProtocols` keep working without the loader hack.
async function loadLeancli() {
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

// --- Privacy-plugin enablement (LEANCLI_PRIVACY flag surface) ---------------
//
// `LEANCLI_PRIVACY` is a comma-separated allow-list of privacy plugins the
// daemon has enabled for this run (e.g. "railgun,privacy-pools"). Empty /
// unset means no privacy plugin is enabled. The wallet daemon
// (`LeanCli/Privacy/Bridge.lean`) passes this through the spawn env.
//
// Pinned-and-lazy model: every plugin is version-pinned in package-lock.json
// (and mirrored in plugins.lock.json) and is `import()`-ed only inside its
// handler. The gate below short-circuits a disabled plugin's method BEFORE
// the lazy import fires, so a disabled plugin's code is never loaded into the
// process. See docs/PLUGIN_ARCHITECTURE.md.
const PRIVACY_PLUGINS = ["railgun", "privacy-pools", "tornado"];

function enabledPrivacyPlugins(env) {
  const raw = (env.LEANCLI_PRIVACY ?? "").trim();
  if (raw === "") return [];
  return raw
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s) => PRIVACY_PLUGINS.includes(s));
}

// Map a shielded method name to the privacy plugin it requires. Methods that
// are not plugin-specific (ping/version/listProtocols/listEnabled) return
// null and are never gated.
function pluginForMethod(method) {
  if (method.startsWith("shielded.railgun.")) return "railgun";
  if (method.startsWith("shielded.tornado.")) return "tornado";
  if (method.startsWith("shielded.")) return "privacy-pools";
  return null;
}


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
// without the AES layer (the key material is in LEANCLI_PP_MNEMONIC).
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
    async get(key) { return key in store ? store[key] : null; },
    async set(key, value) { store[key] = value; flush(); },
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

function blockNumberHex(value) {
  return `0x${value.toString(16)}`;
}

// Adapts Kohaku's EthereumProvider to the EIP-1193-like interface expected by
// Railgun's SimpleSmartAccount. This mirrors kohaku-cli's target-version
// RailgunEthereumProviderAdapter.
class RailgunEthereumProviderAdapter {
  constructor(provider) {
    this.provider = provider;
  }

  async getChainId() { return await this.provider.getChainId(); }
  async getBlockNumber() { return await this.provider.getBlockNumber(); }

  async getLogs(address, eventSignature, fromBlock, toBlock) {
    const filter = { address };
    if (fromBlock !== undefined) filter.fromBlock = blockNumberHex(fromBlock);
    if (toBlock !== undefined) filter.toBlock = blockNumberHex(toBlock);
    if (eventSignature) filter.topics = [eventSignature];
    const logs = await this.provider.request({ method: "eth_getLogs", params: [filter] });
    return logs.map((log) => {
      if (!log.transactionHash?.startsWith("0x")) {
        throw new Error("railgun eth_getLogs entry missing transactionHash");
      }
      return {
        blockNumber: log.blockNumber != null ? Number(BigInt(log.blockNumber)) : null,
        blockTimestamp: null,
        transactionHash: log.transactionHash,
        address: log.address ?? address,
        topics: log.topics ?? [],
        data: log.data ?? "0x",
      };
    });
  }

  async ethCall(to, data) {
    return (await this.provider.call({ to, input: data })) ?? "0x";
  }

  async estimateGas(to, from, data) {
    return await this.provider.estimateGas({ to, from, input: data });
  }

  async getGasPrice() { return await this.provider.getGasPrice(); }

  async getTransactionCount(address, block) {
    const blockTag = block !== undefined ? blockNumberHex(block) : "latest";
    const count = await this.provider.request({
      method: "eth_getTransactionCount",
      params: [address, blockTag],
    });
    return BigInt(count);
  }
}

function entrypointFor(chainId, presets) {
  const cfg = presets[Number(chainId)];
  if (!cfg) throw new Error(`PrivacyPools 0xBow has no entrypoint for chainId=${chainId}`);
  return cfg.entrypoint;
}

// Why: PPv1Plugin uses the host keystore via deriveAt(path) to derive its own
// nullifier/salt material. We back this with a dedicated mnemonic
// (LEANCLI_PP_MNEMONIC) so the privacy-pools spending secret is separate
// from the EOA mnemonic the daemon manages for signing.
function keystoreFromMnemonic(mnemonic) {
  const seed = mnemonicToSeedSync(mnemonic);
  return keystoreFromSeedBytes(seed);
}

// Build a host keystore from a raw 64-byte BIP-39 master seed (hex).
// Used by the Railgun path: the daemon passes the unlocked EOA's
// `slot.seed` (hex-encoded) directly. Railgun derives at its own
// BIP-32 paths (via RailgunSigner.spendingKeyPath / viewingKeyPath),
// disjoint from BIP-44 Ethereum, so the same seed root yields
// independent Railgun keys without cross-domain reuse. Lets the EOA's
// existing unlock surface (master KEK / TPM / per-slot passphrase)
// also unlock the Railgun keystore — one stored secret total.
function keystoreFromSeedHex(seedHex) {
  const clean = seedHex.startsWith("0x") ? seedHex.slice(2) : seedHex;
  if (!/^[0-9a-fA-F]+$/.test(clean) || clean.length % 2 !== 0) {
    throw new Error("LEANCLI_RG_SEED_HEX must be 0x-prefixed even-length hex");
  }
  const bytes = Buffer.from(clean, "hex");
  return keystoreFromSeedBytes(bytes);
}

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

function buildHost({ rpcUrl, chainId, mnemonic, viemProvider, storagePath }) {
  if (!rpcUrl) throw new Error("LEANCLI_RPC_URL is required");
  if (!chainId) throw new Error("LEANCLI_CHAIN_ID is required");
  if (!mnemonic) throw new Error("LEANCLI_PP_MNEMONIC is required (privacy-pools spending secret, separate from EOA mnemonic)");
  const chain = chainFromId(chainId);
  const client = createPublicClient({ chain, transport: http(rpcUrl) });
  return {
    network: inMemoryNetwork(),
    storage: storagePath
      ? fileStorage(storagePath)
      : { _brand: "Storage", async get() { return null; }, async set() {} },
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
  const chainId = BigInt(env.LEANCLI_CHAIN_ID);
  console.error(`[bridge] loading kohaku SDK (chainId=${chainId}, rpc=${env.LEANCLI_RPC_URL})`);
  const t0 = Date.now();
  const { pp, provider } = await loadLeancli();
  console.error(`[bridge] SDK loaded in ${Date.now() - t0}ms`);
  const host = buildHost({
    rpcUrl: env.LEANCLI_RPC_URL,
    chainId,
    mnemonic: env.LEANCLI_PP_MNEMONIC,
    viemProvider: provider.viem,
    storagePath: env.LEANCLI_PP_STORAGE_PATH,
  });
  const ep = entrypointFor(chainId, pp.PrivacyPoolsV1_0xBow);
  const entrypoint = {
    address: BigInt(ep.entrypointAddress),
    deploymentBlock: BigInt(ep.deploymentBlock),
  };
  const broadcasterUrl = env.LEANCLI_PP_BROADCASTER_URL || "https://fastrelay.xyz/relayer";
  console.error(`[bridge] entrypoint=0x${ep.entrypointAddress.toString(16)} broadcaster=${broadcasterUrl}`);
  const cachedState = await loadInitialState(env.LEANCLI_PP_STATE_PATH);
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
    ...(initialState ? { initialState: async () => initialState } : {}),
  });
  plugin.__host = host;
  plugin.__pp = pp;
  plugin.__broadcasterUrl = broadcasterUrl;
  return plugin;
}

// Build a Railgun plugin for the unified async Host API. Same host shape as PP plugin
// ({ network, storage, keystore, provider }); separate env vars + storage
// file so PP and Railgun never clobber each other's persisted state.
//
// `needBundler` controls whether the bundler + delegating signer must be
// configured. Balance/prepareShield don't need them; unshield/transfer do
// (the broadcast path is ERC-4337 + EIP-7702, not Waku). When
// `needBundler=true`, both LEANCLI_RG_BUNDLER_URL and
// LEANCLI_RG_DELEGATING_KEY must be set.
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
  const chainId = BigInt(env.LEANCLI_CHAIN_ID);
  console.error(`[bridge] loading railgun SDK (chainId=${chainId}, rpc=${env.LEANCLI_RPC_URL})`);
  const t0 = Date.now();
  const { rg, provider } = await loadRailgun();
  console.error(`[bridge] railgun SDK loaded in ${Date.now() - t0}ms`);
  // Keystore source priority:
  //   1. LEANCLI_RG_SEED_HEX — raw BIP-39 master seed from the
  //      daemon's unlocked EOA slot. This is the default flow: one
  //      mnemonic on disk, shared with the EOA, Railgun derives at
  //      its own BIP-32 paths so the keys don't collide.
  //   2. LEANCLI_RG_MNEMONIC — explicit BIP-39 phrase. Legacy /
  //      compromise-isolation path: user wants a Railgun-only
  //      mnemonic separate from any EOA. Still supported but no
  //      longer the default.
  let keystore;
  if (env.LEANCLI_RG_SEED_HEX) {
    keystore = keystoreFromSeedHex(env.LEANCLI_RG_SEED_HEX);
  } else if (env.LEANCLI_RG_MNEMONIC) {
    keystore = keystoreFromMnemonic(env.LEANCLI_RG_MNEMONIC);
  } else {
    throw new Error("LEANCLI_RG_SEED_HEX or LEANCLI_RG_MNEMONIC is required (railgun keystore source)");
  }
  if (!env.LEANCLI_RG_STORAGE_PATH) {
    throw new Error("LEANCLI_RG_STORAGE_PATH is required (railgun plugin state file)");
  }
  // Cold-start seed: if the user's railgun storage file doesn't exist
  // yet AND a bundled snapshot ships alongside bridge.mjs, copy it in
  // so the SDK starts from an already-synced state instead of from the
  // Railgun smart-wallet deployment block. The snapshot file contains
  // only chain-wide indexer state (UTXO commitments, merkle tree,
  // POI metadata) — no per-user keys, since the SDK derives signers
  // fresh from host.keystore each call. Skipping the cold-sync turns
  // first-balance latency from minutes into seconds.
  // Set LEANCLI_RG_SNAPSHOT_DISABLE=1 to opt out (e.g. when
  // generating a new snapshot via the leancli-railgun-snapshot tool).
  if (
    !fsSync.existsSync(env.LEANCLI_RG_STORAGE_PATH) &&
    env.LEANCLI_RG_SNAPSHOT_DISABLE !== "1"
  ) {
    try {
      const here = pathMod.dirname(new URL(import.meta.url).pathname);
      const snapshotName =
        Number(chainId) === 11155111
          ? "railgun-sepolia-snapshot.json"
          : Number(chainId) === 1
            ? "railgun-mainnet-snapshot.json"
            : null;
      const snapshotPath = snapshotName ? pathMod.join(here, snapshotName) : null;
      if (snapshotPath && fsSync.existsSync(snapshotPath)) {
        fsSync.mkdirSync(pathMod.dirname(env.LEANCLI_RG_STORAGE_PATH), { recursive: true });
        fsSync.copyFileSync(snapshotPath, env.LEANCLI_RG_STORAGE_PATH);
        const sz = fsSync.statSync(env.LEANCLI_RG_STORAGE_PATH).size;
        console.error(`[bridge] railgun: seeded storage from bundled snapshot ${snapshotPath} (${sz} bytes)`);
      }
    } catch (e) {
      console.error(`[bridge] railgun: snapshot seeding skipped (${e?.message ?? e})`);
    }
  }
  const chain = chainFromId(chainId);
  const client = createPublicClient({ chain, transport: http(env.LEANCLI_RPC_URL) });
  const host = {
    network: inMemoryNetwork(),
    storage: fileStorage(env.LEANCLI_RG_STORAGE_PATH),
    keystore,
    provider: withChunkedGetLogs(provider.viem(client)),
  };

  let delegatingKey;
  if (needBundler) {
    if (!env.LEANCLI_RG_BUNDLER_URL) {
      throw new Error("LEANCLI_RG_BUNDLER_URL is required for railgun unshield/transfer (4337 bundler URL, e.g. Pimlico)");
    }
    if (!env.LEANCLI_RG_DELEGATING_KEY) {
      throw new Error("LEANCLI_RG_DELEGATING_KEY is required for railgun unshield/transfer (hex private key of the EIP-7702 delegating EOA)");
    }
    delegatingKey = env.LEANCLI_RG_DELEGATING_KEY.startsWith("0x")
      ? env.LEANCLI_RG_DELEGATING_KEY
      : "0x" + env.LEANCLI_RG_DELEGATING_KEY;
  }

  const plugin = await rg.createRailgunPlugin(host, {
    keyIndex: 0,
    // POI defaults to true. The pinned wasm has the working
    // ppoi.fdi.network/ endpoint baked in, so this works on both
    // mainnet and Sepolia. Set to false only for debugging.
    poi: true,
  });
  if (needBundler) {
    // alpha.28 initializes WASM inside createRailgunPlugin, so Signer must be
    // constructed after plugin creation. Configure 4337/7702 through setters.
    const signer = rg.Signer.privateKey(delegatingKey);
    const smartAccount = new rg.SimpleSmartAccount(
      signer.address,
      chainId,
      new RailgunEthereumProviderAdapter(host.provider),
    );
    plugin.setBundler(rg.Bundler.pimlico(env.LEANCLI_RG_BUNDLER_URL));
    plugin.setSmartAccount(smartAccount, signer);
  }
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
    chainId: env.LEANCLI_CHAIN_ID,
    balances,
  };
}

function assetAddressLower(asset) {
  if (!asset || asset.__type !== "erc20") return null;
  if (typeof asset.contract === "bigint") {
    return `0x${asset.contract.toString(16).padStart(40, "0")}`.toLowerCase();
  }
  return String(asset.contract ?? "").toLowerCase();
}

async function railgunMaxUnshield(env, params, { strictGas = false, plugin: pluginOverride } = {}) {
  const plugin = pluginOverride ?? await buildRailgunPlugin(env);
  const chainId = BigInt(env.LEANCLI_CHAIN_ID);
  const chain = plugin.__rg.chainConfig(chainId);
  if (!chain) throw new Error(`Railgun is not supported on chainId ${chainId}`);
  const native = !params?.tokenAddress;
  const wrappedBaseToken = chain.wrappedBaseToken.toLowerCase();
  const target = (native ? wrappedBaseToken : params.tokenAddress).toLowerCase();
  const paysGasFromBalance = target === wrappedBaseToken;
  const balances = await plugin.balance(undefined);
  const balanceWei = balances.reduce((sum, row) => {
    if (row?.tag === "pending" || assetAddressLower(row?.asset) !== target) return sum;
    return sum + BigInt(row?.amount ?? 0);
  }, 0n);
  let estimatedGasFeeWei = 0n;
  let gasEstimateFailed = false;
  if (paysGasFromBalance) {
    try {
      if (!env.LEANCLI_RG_BUNDLER_URL) throw new Error("LEANCLI_RG_BUNDLER_URL is required");
      const maxFeePerGas = await fetchPimlicoMaxFeePerGas(env.LEANCLI_RG_BUNDLER_URL);
      estimatedGasFeeWei = estimateRailgunBundlerFeeWei(maxFeePerGas, { nativeUnwrap: native });
    } catch (error) {
      if (strictGas) throw new Error(`could not price Railgun max unshield: ${error?.message ?? error}`);
      gasEstimateFailed = true;
    }
  }
  const amountWei = railgunMaxReceivableFromBalance(
    balanceWei,
    chain.unshieldFeeBps,
    estimatedGasFeeWei,
  );
  return {
    chainId,
    balanceWei,
    amountWei,
    estimatedGasFeeWei,
    unshieldFeeBps: chain.unshieldFeeBps,
    paysGasFromBalance,
    gasEstimateFailed,
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

// Build a Railgun asset for unshield. Native ETH is supported:
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
    chainId: env.LEANCLI_CHAIN_ID,
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
  const plugin = await buildRailgunPlugin(env, { needBundler: true });
  const quotedMax = await railgunMaxUnshield(env, params, { strictGas: true, plugin });
  const amountWei = params?.amountMax === true || String(params?.amountEth).toLowerCase() === "max"
    ? quotedMax.amountWei
    : params?.amountWei
      ? BigInt(params.amountWei)
      : parseEther(String(params?.amountEth ?? "0"));
  if (amountWei <= 0n) throw new Error("amount must be > 0");
  if (amountWei > quotedMax.amountWei) {
    throw new Error(`amount exceeds current Railgun max after fees (${quotedMax.amountWei} wei)`);
  }
  const asset = railgunUnshieldAsset(params?.tokenAddress);
  console.error(`[bridge] railgun: prepareUnshield amount=${amountWei} to=${recipient} asset=${JSON.stringify(asset)}`);
  const op = await plugin.prepareUnshield({ asset, amount: amountWei }, recipient);
  console.error(`[bridge] railgun: broadcasting unshield via 4337 bundler`);
  await plugin.broadcast(op);
  return {
    chainId: env.LEANCLI_CHAIN_ID,
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
    chainId: env.LEANCLI_CHAIN_ID,
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
  await persistState(env.LEANCLI_PP_STATE_PATH, plugin);
  return {
    chainId: env.LEANCLI_CHAIN_ID,
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
  await persistState(env.LEANCLI_PP_STATE_PATH, plugin);
  return {
    chainId: env.LEANCLI_CHAIN_ID,
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
  await persistState(env.LEANCLI_PP_STATE_PATH, plugin);
  const broadcaster = plugin.__pp.createPPv1Broadcaster(plugin.__host, {
    broadcasterUrl: plugin.__broadcasterUrl,
  });
  console.error(`[bridge] broadcasting unshield via ${plugin.__broadcasterUrl}`);
  const relayResult = await broadcaster.broadcast(privateOp);
  return {
    chainId: env.LEANCLI_CHAIN_ID,
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
  const plugin = await buildPlugin(env);
  if (plugin.sync) await plugin.sync();
  const initialNotes = await plugin.notes([ethAsset()]);
  const maxNoteWei = largestSpendableNote(
    initialNotes.filter((n) => (n.approved ?? true)),
  );
  const target = params?.amountMax === true || String(params?.amountEth).toLowerCase() === "max"
    ? maxNoteWei
    : params?.amountWei
      ? BigInt(params.amountWei)
      : parseEther(String(params?.amountEth ?? "0"));
  if (target <= 0n) throw new Error("amount must be > 0");
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
    let relay;
    try {
      relay = await broadcaster.broadcast(op);
    } catch (e) {
      // Surface relayer-side failures with actionable context instead of
      // letting the raw on-chain revert string bubble up. Persist whatever
      // we drained so far so the user knows where they stand and the
      // PP state file reflects any successful relays.
      await persistState(env.LEANCLI_PP_STATE_PATH, plugin);
      const raw = e?.message ?? String(e);
      const drainedSoFar = target - remaining;
      const partial = sent.length > 0 ? ` (drained ${drainedSoFar} of ${target} before failure)` : "";
      if (/RelayFeeGreaterThanMax/i.test(raw)) {
        throw new Error(
          `Privacy Pools relayer quoted a relay fee above the pool's on-chain cap (RelayFeeGreaterThanMax)${partial}. ` +
          `This is a relayer/pool config mismatch — nothing was deducted. Try again later, ` +
          `or override the relayer with LEANCLI_PP_BROADCASTER_URL=<url>. Underlying: ${raw}`,
        );
      }
      throw new Error(`relayer rejected unshield at iter ${iter}${partial}: ${raw}`);
    }
    console.error(`[bridge] drain iter ${iter}: relay ${relay?.txHash ?? "unknown"}`);
    sent.push({ amountWei: chunk, relay: relay ?? { ok: true } });
    remaining -= chunk;
  }
  await persistState(env.LEANCLI_PP_STATE_PATH, plugin);
  return {
    chainId: env.LEANCLI_CHAIN_ID,
    recipient,
    targetWei: target,
    drainedWei: target - remaining,
    iterations: sent.length,
    sent,
  };
}

// Why: quote an unshield WITHOUT broadcasting, so the daemon/TUI can show
// recipient + amount + relayer fee in a ConfirmGate before any relay fires.
// A Privacy Pools v1 withdraw carries NO EOA signature — the relayer submits
// the ZK proof — so confirming the quoted terms IS the pre-broadcast gate
// (there is no daemon-local signature to perform). We build a real proof
// here (prepareUnshield) only to read its bundled relayer quote, then
// discard it: an un-broadcast proof has no on-chain effect, so the
// subsequent shielded.unshieldDrain rebuilding + broadcasting is safe. We do
// NOT persist state on a quote.
async function shieldedQuoteUnshield(env, params) {
  const recipient = params?.recipient;
  if (!recipient || !/^0x[0-9a-fA-F]{40}$/.test(recipient)) {
    throw new Error("recipient must be a 0x-prefixed 20-byte address");
  }
  const plugin = await buildPlugin(env);
  if (plugin.sync) await plugin.sync();
  // Largest single approved note tells us whether this is one relay or a
  // multi-note drain (each note relays separately, each with its own fee).
  const allNotes = await plugin.notes([ethAsset()]);
  const usable = allNotes
    .filter((n) => (n.approved ?? true) && BigInt(n.balance ?? 0) > 0n)
    .map((n) => BigInt(n.balance))
    .sort((a, b) => (a < b ? 1 : a > b ? -1 : 0));
  const approvedTotal = usable.reduce((s, b) => s + b, 0n);
  const biggest = usable.length > 0 ? usable[0] : 0n;
  if (biggest <= 0n) {
    throw new Error(
      "no approved notes available to unshield — your deposit may still be " +
      "awaiting OxBow ASP approval. Wait for ASP indexing and retry.",
    );
  }
  const target = params?.amountMax === true || String(params?.amountEth).toLowerCase() === "max"
    ? biggest
    : params?.amountWei
      ? BigInt(params.amountWei)
      : parseEther(String(params?.amountEth ?? "0"));
  if (target <= 0n) throw new Error("amount must be > 0");
  const chunk = target < biggest ? target : biggest;
  let op;
  try {
    op = await plugin.prepareUnshield({ asset: ethAsset(), amount: chunk }, recipient);
  } catch (e) {
    const msg = e?.message ?? String(e);
    if (msg.includes("Leaf not found")) {
      throw new Error(
        "Your deposit is not yet approved by the OxBow ASP (Approval Service " +
        "Provider). Privacy Pools v1 requires deposits to be in the ASP's " +
        "merkle tree before they can be unshielded. Wait for ASP indexing and " +
        "retry. Underlying SDK error: " + msg,
      );
    }
    throw e;
  }
  const q = op?.quoteData?.quote ?? {};
  const relayData = op?.rawData?.relayData ?? {};
  return {
    chainId: env.LEANCLI_CHAIN_ID,
    recipient,
    requestedWei: target,
    chunkWei: chunk,                 // amount of the first (or only) relay
    multiRelay: target > biggest,    // true ⇒ spans multiple notes ⇒ more relays
    approvedTotalWei: approvedTotal,
    feeBPS: q.feeBPS ?? null,
    baseFeeBPS: q.baseFeeBPS ?? null,
    gasPriceWei: q.gasPrice ?? null,
    relayTxCostWei: q?.detail?.relayTxCost?.eth ?? null,
    relayFeeBps: relayData?.relayFeeBps ?? null,
    relayerId: op?.quoteData?.relayerId ?? null,
  };
}

// ----------------------------------------------------------------------
// Tornado Cash — live via @kohaku-eth/tornado-cash.
//
// All tornado logic lives in ./tornado.mjs (lazily imported by the
// dispatch arms below, only on shielded.tornado.* after the LEANCLI_PRIVACY
// gate). All privacy plugins now share the top-level async Host contract from
// plugins alpha.11, while Tornado remains isolated here for worker loading and
// protocol-specific state.
//
//   Deposit  (shielded.tornado.prepareDeposit): returns UNSIGNED N×0.1-ETH
//            fixed-denomination deposit legs → Lean decode → simulate →
//            ConfirmGate → eoa.send, one leg at a time.
//   Withdraw (quoteWithdraw / executeWithdraw): a groth16 proof + relayer
//            or ERC-4337 paymaster submission — NO EOA signature — so the
//            quote → ConfirmGate → execute flow mirrors Privacy Pools.
// ----------------------------------------------------------------------

// Static protocol catalogue (independent of which plugins are enabled).
const PROTOCOL_CATALOGUE = [
  { name: "privacy-pools", plugin: "privacy-pools", status: "live", chains: [11155111, 1] },
  { name: "railgun", plugin: "railgun", status: "live", chains: [11155111, 1] },
  { name: "tornado-cash", plugin: "tornado", status: "live", chains: [1, 11155111] },
];

async function dispatch(req) {
  const { method, params, id } = req;
  const env = process.env;

  // Gate plugin-specific shielded methods on LEANCLI_PRIVACY enablement.
  // This runs BEFORE the switch so a disabled plugin's lazy import() never
  // fires. Non-plugin methods (ping/version/listProtocols/listEnabled)
  // return null from pluginForMethod and pass through ungated.
  const requiredPlugin = pluginForMethod(method);
  if (requiredPlugin !== null) {
    const enabled = enabledPrivacyPlugins(env);
    if (!enabled.includes(requiredPlugin)) {
      return jsonrpcResult(id, {
        ok: false,
        error: `plugin not enabled: ${requiredPlugin}`,
      });
    }
  }

  switch (method) {
    case "ping":
      return jsonrpcResult(id, {
        ok: true,
        bridge: "leancli-bridge",
        protocol: PROTOCOL_VERSION,
        node: process.versions.node,
      });
    case "version":
      return jsonrpcResult(id, {
        bridge: PROTOCOL_VERSION,
        node: process.versions.node,
      });
    case "listProtocols":
      // Back-compat alias for listEnabled's `protocols` view: the full
      // static catalogue, regardless of enablement.
      return jsonrpcResult(id, {
        protocols: PROTOCOL_CATALOGUE.map(({ name, status, chains }) => ({
          name,
          status,
          chains,
        })),
      });
    case "listEnabled": {
      // Report the active provider (read backend, single-select) and the
      // enabled privacy plugins (multi-select). The provider is informational
      // here — the daemon owns ReadBackend selection — but surfacing it keeps
      // the host's view of the world legible to the TUI / agent.
      const enabled = enabledPrivacyPlugins(env);
      return jsonrpcResult(id, {
        provider: (env.LEANCLI_PROVIDER ?? "helios").trim().toLowerCase() || "helios",
        enabledPrivacy: enabled,
        protocols: PROTOCOL_CATALOGUE.map(({ name, plugin, status, chains }) => ({
          name,
          status,
          chains,
          enabled: enabled.includes(plugin),
        })),
      });
    }
    case "shielded.balance":
      return jsonifyResult(id, await shieldedBalance(env));
    case "shielded.prepareDeposit":
      return jsonifyResult(id, await shieldedPrepareDeposit(env, params));
    case "shielded.unshieldDrain":
      return jsonifyResult(id, await shieldedUnshieldDrain(env, params));
    case "shielded.maxUnshield": {
      const plugin = await buildPlugin(env);
      if (plugin.sync) await plugin.sync();
      const notes = await plugin.notes([ethAsset()]);
      const amountWei = largestSpendableNote(notes.filter((n) => (n.approved ?? true)));
      return jsonifyResult(id, {
        chainId: env.LEANCLI_CHAIN_ID,
        amountWei,
        scope: "largest-approved-note",
      });
    }
    case "shielded.quoteUnshield":
      return jsonifyResult(id, await shieldedQuoteUnshield(env, params));
    case "shielded.prepareWithdraw":
      return jsonifyResult(id, await shieldedPrepareWithdraw(env, params));
    case "shielded.railgun.balance":
      return jsonifyResult(id, await shieldedRailgunBalance(env));
    case "shielded.railgun.prepareShield":
      return jsonifyResult(id, await shieldedRailgunPrepareShield(env, params));
    case "shielded.railgun.unshield":
      return jsonifyResult(id, await shieldedRailgunUnshield(env, params));
    case "shielded.railgun.maxUnshield":
      return jsonifyResult(
        id,
        await railgunMaxUnshield(env, params, { strictGas: params?.strict === true }),
      );
    case "shielded.railgun.transfer":
      return jsonifyResult(id, await shieldedRailgunTransfer(env, params));
    case "shielded.tornado.balance":
    case "shielded.tornado.notes":
    case "shielded.tornado.maxUnshield":
    case "shielded.tornado.prepareDeposit":
    case "shielded.tornado.quoteWithdraw":
    case "shielded.tornado.executeWithdraw": {
      const { dispatchTornado } = await import("./tornado.mjs");
      return jsonifyResult(id, await dispatchTornado(method, env, params));
    }
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
