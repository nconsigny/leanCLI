import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import * as pp from "@kohaku-eth/privacy-pools";
import {
  Bundler,
  Signer,
  SimpleSmartAccount,
  createRailgunPlugin,
} from "@kohaku-eth/railgun";

function asyncHost() {
  const values = new Map();
  return {
    network: { fetch: globalThis.fetch },
    storage: {
      _brand: "Storage",
      async get(key) { return values.get(key) ?? null; },
      async set(key, value) { values.set(key, value); },
    },
    keystore: {
      async deriveAt() { return `0x${"01".repeat(32)}`; },
    },
    provider: {
      async getChainId() { return 11155111n; },
    },
  };
}

async function installedVersion(packageName) {
  const raw = await readFile(
    new URL(`./node_modules/${packageName}/package.json`, import.meta.url),
    "utf8",
  );
  return JSON.parse(raw).version;
}

test("privacy plugins use the July 4 lockstep release set", async () => {
  assert.equal(await installedVersion("@kohaku-eth/plugins"), "0.0.1-alpha.11");
  assert.equal(await installedVersion("@kohaku-eth/railgun"), "0.0.1-alpha.28");
  assert.equal(await installedVersion("@kohaku-eth/privacy-pools"), "0.0.2-alpha.14");
});

test("Railgun exposes notes and supports post-initialization 4337 setup", async () => {
  const plugin = await createRailgunPlugin(asyncHost(), { poi: false });
  assert.equal(typeof plugin.notes, "function");

  const signer = Signer.privateKey(`0x${"02".repeat(32)}`);
  const provider = {
    async getChainId() { return 11155111n; },
    async getBlockNumber() { return 0n; },
    async getLogs() { return []; },
    async ethCall() { return "0x"; },
    async estimateGas() { return 0n; },
    async getGasPrice() { return 0n; },
    async getTransactionCount() { return 0n; },
  };
  const smartAccount = new SimpleSmartAccount(signer.address, 11155111n, provider);
  plugin.setBundler(Bundler.pimlico("https://example.invalid"));
  plugin.setSmartAccount(smartAccount, signer);
});

test("Privacy Pools accepts async Host and initial-state provider", () => {
  const host = asyncHost();
  const preset = pp.PrivacyPoolsV1_0xBow[11155111];
  const plugin = pp.createPPv1Plugin(host, {
    accountIndex: 0,
    entrypoint: {
      address: BigInt(preset.entrypoint.entrypointAddress),
      deploymentBlock: preset.entrypoint.deploymentBlock,
    },
    broadcasterUrl: "https://example.invalid",
    aspServiceFactory: () => new pp.OxBowAspService({
      network: host.network,
      aspUrl: "https://example.invalid",
    }),
    initialState: async () => ({}),
  });

  assert.equal(typeof plugin.notes, "function");
  assert.equal(typeof plugin.prepareShield, "function");
  assert.equal(typeof plugin.prepareUnshield, "function");
});
