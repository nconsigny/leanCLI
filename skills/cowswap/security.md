# cowswap — security

## Pre-sign checklist (every order)

1. The 7730 descriptor in
   `bridge/clearsign/registry/eip712-cowswap-order.json` is the
   canonical decoded view. The agent renders every named field
   (sellToken, sellAmount, buyToken, buyAmount, receiver, validTo,
   kind, feeAmount). Refuse to sign if any of the decoded fields is
   missing from the rendered prompt.
2. `validTo` must be ≤ `now + 1 hour`. Multi-hour validity windows
   are a free option for solvers and a refusal trigger for the agent
   absent explicit user override.
3. `receiver` must be `msg.sender` unless the user explicitly named
   a third party. Surface a banner if not.
4. `sellAmount > 0` and `buyAmount > 0`. A `buyAmount = 0` accepts
   any receive amount and is a refusal trigger.
5. `feeAmount` is included in `sellAmount` per CoW Protocol's
   accounting — show both the total `sellAmount` and the protocol fee
   separately to the user.
6. The ERC-20 `approve` step (which precedes any swap) targets
   `vaultRelayer()` on the settlement contract — **not** the
   settlement contract itself. The wallet reads `vaultRelayer()` via
   `chain.ethCall` rather than hard-coding.

## Refusal triggers

* Order is `partiallyFillable: true` with a `validTo` more than 1
  hour out — too easy for solvers to cherry-pick the trader.
* `appData` (the order's free-form 32-byte commitment) is non-zero
  and the wallet cannot decode it. CoW solvers honor `appData` for
  hook execution and other side-channels; an opaque `appData` is an
  opaque commitment.
* The on-chain `setPreSignature(orderUid)` is being called without
  the wallet first resolving and re-decoding the underlying `Order`
  from its UID. The 56-byte UID alone is not human-readable.

## EIP-1271 smart-contract signatures

When the signing account is a smart contract (e.g. a Safe or an
ERC-4337 account), CoW Protocol validates the signature via EIP-1271
`isValidSignature(hash, sig)`. The wallet must still decode the
underlying `Order` per the 7730 descriptor and present it — the
smart-contract signature is a transport, not a substitute for user
confirmation.

## Solver model — advisory

* Solvers are publicly listed and stake collateral. Their job is to
  surface the best price; a solver that consistently fails to do so
  loses stake.
* The trader is not exposed to MEV in the conventional sense — the
  batch-auction model collapses sandwiching into the same block. But
  the trader IS exposed to the solver's choice of route; an opaque
  `appData` can encode that choice.

## Citations

* <https://docs.cow.fi/cow-protocol/reference/core/auctions/orders>
* <https://docs.cow.fi/cow-protocol/reference/core/signing-schemes>
