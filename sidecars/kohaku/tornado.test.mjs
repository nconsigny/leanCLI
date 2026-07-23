import assert from "node:assert/strict";
import test from "node:test";
import { HDKey } from "@scure/bip32";

import {
  assertTornadoBroadcastResults,
  keystoreFromScopedRoot,
  largestTornadoSpendableDenomination,
  selectTornadoWithdrawals,
  totalTornadoSpendableBalance,
  tornadoPaymasterUnshieldOptions,
  paymasterFeeWeiFromOperation,
  relayerFeeWeiFromOperation,
} from "./tornado.mjs";

test("scoped Tornado keystore preserves notes and denies unrelated EOA paths", async () => {
  const master = HDKey.fromMasterSeed(Buffer.alloc(32, 7));
  const scopedRoot = master.derive("m/29795'/1'");
  const delegatorPath = "m/44'/60'/0'/0/7";
  const delegatorKey = master.derive(delegatorPath).privateKey;
  const keystore = keystoreFromScopedRoot({
    rootKeyHex: `0x${Buffer.from(scopedRoot.privateKey).toString("hex")}`,
    rootChainCodeHex: `0x${Buffer.from(scopedRoot.chainCode).toString("hex")}`,
    delegatorPath,
    delegatorKeyHex: `0x${Buffer.from(delegatorKey).toString("hex")}`,
  });
  const notePath = "m/29795'/1'/0'/1'/12'";
  assert.equal(
    await keystore.deriveAt(notePath),
    `0x${Buffer.from(master.derive(notePath).privateKey).toString("hex")}`,
  );
  assert.equal(
    await keystore.deriveAt(delegatorPath),
    `0x${Buffer.from(delegatorKey).toString("hex")}`,
  );
  await assert.rejects(
    () => keystore.deriveAt("m/44'/60'/0'/0/0"),
    /outside Tornado subtree denied/,
  );
});

test("multi-withdraw selects the fewest notes that exactly cover the amount", () => {
  const notes = [
    { amount: 100n, balance: 100n },
    { amount: 100n, balance: 100n },
    { amount: 1_000n, balance: 1_000n },
  ];

  assert.deepEqual(selectTornadoWithdrawals(notes, 1_200n), {
    amountWei: 1_200n,
    coveredWei: 1_200n,
    withdrawalCount: 3,
  });
  assert.deepEqual(selectTornadoWithdrawals(notes, 1_000n), {
    amountWei: 1_000n,
    coveredWei: 1_000n,
    withdrawalCount: 1,
  });
  assert.throws(
    () => selectTornadoWithdrawals(notes, 1_100n + 50n),
    /cannot exactly cover/,
  );
});

test("tornado max is the total spendable note balance", () => {
  const notes = [
    { amount: 100n, balance: 100n },
    { amount: 10_000n, balance: 0n },
    { amount: 1_000n, balance: 1_000n },
  ];
  assert.equal(totalTornadoSpendableBalance(notes), 1_100n);
  assert.equal(largestTornadoSpendableDenomination(notes), 1_000n);
});

test("paymaster options bind the 7702 delegator to the daemon-resolved path", async () => {
  const recipient = "0x1111111111111111111111111111111111111111";
  const path = "m/44'/60'/0'/0/7";
  const options = tornadoPaymasterUnshieldOptions(path);

  assert.deepEqual(options.delegation, { mode: "deterministic", path });
  assert.equal(options.tailCalls, undefined);
});

// ---- Tail calls (kohaku-cli 0df25ce parity) --------------------------------

import { parseTailCallsParam, totalTailCallValue } from "./tornado.mjs";
import {
  estimateTornadoPaymasterFee,
  TORNADO_BASE_CALL_GAS_LIMIT,
  tornadoWithdrawalCallGasLimit,
} from "./tornado-paymaster-gas.mjs";
import { withTailCallsGasOverhead } from "./tornado-tail-gas.mjs";

const T1 = "0x1111111111111111111111111111111111111111";
const T2 = "0x2222222222222222222222222222222222222222";

test("tail call params validate shape and normalize values", () => {
  const calls = parseTailCallsParam({
    tailCalls: [
      { to: T1, data: "0x1234", valueWei: "7" },
      { to: T2, data: "0x" },
    ],
  });
  assert.deepEqual(calls, [
    { to: T1, data: "0x1234", value: 7n },
    { to: T2, data: "0x", value: 0n },
  ]);
  assert.equal(totalTailCallValue(calls), 7n);
  assert.deepEqual(parseTailCallsParam({}), []);

  assert.throws(() => parseTailCallsParam({ tailCalls: [{ to: "0x1111", data: "0x" }] }), /target/);
  assert.throws(() => parseTailCallsParam({ tailCalls: [{ to: T1, data: "0x123" }] }), /calldata/);
  assert.throws(() => parseTailCallsParam({ tailCalls: [{ to: T1, data: "0x", valueWei: "-1" }] }), />= 0/);
  assert.throws(() => parseTailCallsParam({ tailCalls: [{ to: T1, data: "0x", valueWei: "wei" }] }), /value/);
});

test("call gas includes every extra withdrawal plus the execution tail", () => {
  assert.equal(tornadoWithdrawalCallGasLimit(0), TORNADO_BASE_CALL_GAS_LIMIT);
  assert.equal(tornadoWithdrawalCallGasLimit(2), 860_000n);
  assert.equal(tornadoWithdrawalCallGasLimit(2, 450_000n), 1_250_000n);
  assert.throws(() => tornadoWithdrawalCallGasLimit(-1), /non-negative/);
  assert.equal(withTailCallsGasOverhead(650_000n), 715_000n);
});

test("multi-withdraw pays one UserOp fee with a larger callGasLimit", () => {
  const base = estimateTornadoPaymasterFee(10n);
  const bumped = estimateTornadoPaymasterFee(10n, {
    callGasLimit: tornadoWithdrawalCallGasLimit(2),
  });
  // Multi consolidation is 860k versus the single-note 300k baseline.
  assert.equal(bumped - base, 6_720_000n);
});

test("valued tail calls are passed to the recipient delegator in order", async () => {
  const path = "m/44'/60'/0'/0/7";
  const options = tornadoPaymasterUnshieldOptions(path, [
    { to: T2, data: "0x1234", value: 5n },
  ]);
  assert.deepEqual(await options.tailCalls(), [
    { to: T2, data: "0x1234", value: 5n },
  ]);
});

test("no user tails lets SDK use automatic forwarding", () => {
  const path = "m/44'/60'/0'/0/7";
  const options = tornadoPaymasterUnshieldOptions(path);
  assert.equal(options.tailCalls, undefined);
});

test("paymaster options forward measured tail gas to SDK alpha.18", async () => {
  const path = "m/44'/60'/0'/0/7";
  const options = tornadoPaymasterUnshieldOptions(
    path,
    [],
    715_000n,
  );
  assert.equal(options.tailCallsGasEstimate, 715_000n);
});

test("prepared paymaster proof fee is extracted for post-prepare cap enforcement", () => {
  const operation = {
    withdrawals: [{
      mode: "paymaster",
      proof: { args: ["0x", "0x", T1, T2, "12345", "0"] },
    }],
  };
  assert.equal(paymasterFeeWeiFromOperation(operation), 12_345n);
  assert.throws(
    () => paymasterFeeWeiFromOperation({ withdrawals: [] }),
    /invalid withdrawal batch/,
  );
  assert.throws(
    () => paymasterFeeWeiFromOperation({
      withdrawals: [{ mode: "paymaster", proof: { args: [] } }],
    }),
    /invalid proof fee/,
  );
});

test("prepared relayer proof fees are summed for cap enforcement", () => {
  const operation = {
    withdrawals: [
      {
        mode: "relayer",
        proof: { args: ["0x", "0x", T1, T2, "100", "0"] },
      },
      {
        mode: "relayer",
        proof: { args: ["0x", "0x", T1, T2, 25n, "0"] },
      },
    ],
  };
  assert.equal(relayerFeeWeiFromOperation(operation), 125n);
  assert.throws(
    () => relayerFeeWeiFromOperation({ withdrawals: [] }),
    /no withdrawals/,
  );
});

test("swallowed SDK broadcast failures are not reported as success", () => {
  const operation = { withdrawals: [{ mode: "paymaster" }] };
  const relay = [{ id: `0x${"12".repeat(32)}` }];
  assert.equal(assertTornadoBroadcastResults(operation, relay), relay);
  assert.throws(
    () => assertTornadoBroadcastResults(operation, []),
    /0 successful submission.*1 prepared withdrawal/,
  );
});
