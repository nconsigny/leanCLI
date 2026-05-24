# cowswap — interaction recipes

## Recipe: sell order, ERC-20 → ERC-20

Goal: sell `sellAmount` of `sellToken` for at least `buyAmount` of
`buyToken`. Mainnet chainId 1, Sepolia chainId 11155111.

1. Resolve the vault relayer:
   `chain_read({to: GPv2Settlement, data: encode("vaultRelayer()")})`
   → `vaultRelayer` address. Cache it per chain.
2. Read current allowance:
   `chain_read({to: sellToken, data: encode("allowance(address,address)", owner, vaultRelayer)})`.
3. If allowance < `sellAmount`, emit an `approve(vaultRelayer,
   sellAmount)` `propose_send` first. Use the
   `bridge/clearsign/registry/erc20.json` descriptor for decoding.
   Prefer the exact amount over unlimited.
4. Build the `Order` struct:
   ```
   sellToken, buyToken, receiver=msg.sender,
   sellAmount, buyAmount,                       # buyAmount is the floor
   validTo = now + 1800,                        # 30 min
   appData = 0x0000…00,                         # zero unless user supplied
   feeAmount,                                   # from the CoW API quote
   kind = "sell",
   partiallyFillable = false,
   sellTokenBalance = "erc20",
   buyTokenBalance = "erc20"
   ```
5. Render via `bridge/clearsign/registry/eip712-cowswap-order.json`.
6. Sign EIP-712 (the daemon's typed-data signer) → 65-byte signature.
7. Submit to the CoW API (off-chain). The wallet's job ends here in
   the happy path.

## Recipe: cancel an outstanding order

* Off-chain cancellation (cheapest): call CoW's `DELETE /orders/{uid}`
  with an authenticated request — out of scope for the daemon.
* On-chain cancellation: `propose_send` against `GPv2Settlement.invalidateOrder(orderUid)`.
  The wallet must re-decode `orderUid` to surface what is being
  cancelled.

## Recipe: smart-contract account signing (EIP-1271)

* The wallet still decodes the `Order` via the EIP-712 descriptor and
  surfaces it in the ConfirmGate.
* The signature transport is the smart account's `isValidSignature`,
  not an ECDSA `eth_sign`. For ERC-4337 accounts this is a userOp;
  for Safe accounts it is a Safe transaction. Both paths still need
  the user to see the decoded `Order`.

## Refusal triggers

* `validTo > now + 1 hour` — solver gets a free option.
* `buyAmount = 0` — accepts any receive amount.
* `appData ≠ 0x00..00` and the agent cannot decode it.
* On-chain `setPreSignature(orderUid)` without first resolving the
  underlying `Order`.

## Cross-reference

* `bridge/clearsign/registry/eip712-cowswap-order.json` — the
  canonical 7730 EIP-712 descriptor; the wallet uses this for the
  user-facing rendering of the order.
* `bridge/clearsign/registry/erc20.json` — the `approve` leg.
