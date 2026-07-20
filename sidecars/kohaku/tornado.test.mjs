import assert from "node:assert/strict";
import test from "node:test";

import {
  hasSpendableMatchingNote,
  largestTornadoSpendableDenomination,
  tornadoPaymasterUnshieldOptions,
} from "./tornado.mjs";

test("execute-time note check requires an exact spendable denomination", () => {
  const notes = [
    { amount: 100n, balance: 0n },
    { amount: 1_000n, balance: 1_000n },
  ];

  assert.equal(hasSpendableMatchingNote(notes, 100n), false);
  assert.equal(hasSpendableMatchingNote(notes, 1_000n), true);
  assert.equal(hasSpendableMatchingNote(notes, 10_000n), false);
});

test("tornado max is the largest spendable single note", () => {
  const notes = [
    { amount: 100n, balance: 100n },
    { amount: 10_000n, balance: 0n },
    { amount: 1_000n, balance: 1_000n },
  ];
  assert.equal(largestTornadoSpendableDenomination(notes), 1_000n);
});

test("paymaster options bind the 7702 delegator to the daemon-resolved path", async () => {
  const recipient = "0x1111111111111111111111111111111111111111";
  const path = "m/44'/60'/0'/0/7";
  const options = tornadoPaymasterUnshieldOptions(recipient, path, 95n);

  assert.deepEqual(options.delegation, { mode: "deterministic", path });
  assert.deepEqual(await options.tailCalls(), [
    { to: recipient, data: "0x", value: 95n },
  ]);
});

// ---- Tail calls (kohaku-cli 0df25ce parity) --------------------------------

import { parseTailCallsParam, totalTailCallValue } from "./tornado.mjs";
import {
  estimateTornadoCallGasLimit,
  estimateTornadoPaymasterFee,
  TORNADO_BASE_CALL_GAS_LIMIT,
} from "./tornado-paymaster-gas.mjs";

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

test("call gas heuristic clamps to the base and the cap", () => {
  // Payout-only batch: 80k overhead + 1.5 * 30k = 125k -> clamped up to base.
  assert.equal(
    estimateTornadoCallGasLimit([{ to: T1, data: "0x", value: 0n }]),
    TORNADO_BASE_CALL_GAS_LIMIT,
  );
  // One payout + one router-style call: 80k + 1.5 * (30k + 350k) = 650k.
  assert.equal(
    estimateTornadoCallGasLimit([
      { to: T1, data: "0x", value: 0n },
      { to: T2, data: "0x1234", value: 0n },
    ]),
    650_000n,
  );
  // Ten fallback-sized calls exceed the 5M cap.
  const many = Array.from({ length: 10 }, () => ({ to: T2, data: "0x1234", value: 0n }));
  assert.equal(estimateTornadoCallGasLimit(many), 5_000_000n);
});

test("paymaster fee scales with the dynamic callGasLimit", () => {
  const base = estimateTornadoPaymasterFee(10n);
  const bumped = estimateTornadoPaymasterFee(10n, { hasTailCalls: true, callGasLimit: 650_000n });
  // 350k extra call gas * 10 wei * 1.2 = 4.2M wei more.
  assert.equal(bumped - base, 4_200_000n);
});

test("valued tail calls reduce the payout and are appended after it", async () => {
  const path = "m/44'/60'/0'/0/7";
  const options = tornadoPaymasterUnshieldOptions(T1, path, 95n, [
    { to: T2, data: "0x1234", value: 5n },
  ]);
  assert.deepEqual(await options.tailCalls(), [
    { to: T1, data: "0x", value: 95n },
    { to: T2, data: "0x1234", value: 5n },
  ]);
});

test("payout call is omitted when fee plus tail values consume the amount", async () => {
  const path = "m/44'/60'/0'/0/7";
  const options = tornadoPaymasterUnshieldOptions(T1, path, 0n, [
    { to: T2, data: "0x1234", value: 5n },
  ]);
  assert.deepEqual(await options.tailCalls(), [
    { to: T2, data: "0x1234", value: 5n },
  ]);
});
