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
