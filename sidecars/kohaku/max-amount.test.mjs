import test from "node:test";
import assert from "node:assert/strict";
import {
  estimateRailgunBundlerFeeWei,
  largestSpendableNote,
  railgunMaxReceivableFromBalance,
} from "./max-amount.mjs";

test("Railgun bundler reserve uses fixed 4337 units and a 20% margin", () => {
  assert.equal(estimateRailgunBundlerFeeWei(10n), 39_240_000n);
  assert.equal(estimateRailgunBundlerFeeWei(10n, { nativeUnwrap: true }), 40_200_000n);
});

test("Railgun max deducts gas reserve and treasury BPS without underflow", () => {
  assert.equal(railgunMaxReceivableFromBalance(1_000_000n, 25, 100_000n), 897_750n);
  assert.equal(railgunMaxReceivableFromBalance(100n, 25, 100n), 0n);
  assert.equal(railgunMaxReceivableFromBalance(100n, 10_000, 0n), 0n);
});

test("largest spendable note ignores zero and spent notes", () => {
  assert.equal(largestSpendableNote([{ balance: 0n }, { balance: 12n }, { balance: 7n }]), 12n);
});
