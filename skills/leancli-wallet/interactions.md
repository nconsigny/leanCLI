# leancli-wallet — how the agent should drive a turn

## Common shapes

### Send native ETH

1. `nonce({chainId, address: from})` — pending nonce.
2. `gas_price({chainId})` — base for max-fee suggestions.
3. `tx.simulate({chainId, from, to, value, data: "0x"})` — verify
   intent and gas.
4. `propose_send({chainId, to, value, data: "0x"})`.

### Send ERC-20

1. `protocol_lookup({name: <token-protocol-if-known>})` — but for
   plain transfers the ERC-20 ABI lives in the clearsign registry
   (`bridge/clearsign/registry/erc20.json`); a generic
   `decode_calldata` round-trip is enough.
2. Build calldata `transfer(address,uint256)`.
3. `tx.simulate(...)` and `propose_send(...)` as above.

### Swap on Uniswap V3

See `skills/uniswap/`. Trigger keywords: `uniswap`, `uni`, `swap`,
`exactInputSingle`. Sequence:

1. `protocol_lookup({name: "uniswap"})`.
2. `protocol_function_lookup({name: "uniswap", function: "exactInputSingle"})`.
3. Read pool fee / decimals via `chain_read`.
4. Compute `amountOutMinimum` with the user-stated slippage.
5. `tx.simulate(...)` and `propose_send(...)`.

### Shielded operation (Railgun / Privacy Pools / Tornado Cash)

The same pipeline applies. Decode calldata so the user sees the
underlying intent (deposit / withdraw / shield / unshield). The
privacy plugins live under `LeanCli/Privacy/` and are policy-gated
by `Privacy.NetworkPolicy` — calling them does NOT permit skipping
the ConfirmGate.

## Refusals you should expect to issue

* "Send 1 ETH to <ENS>" without explicit resolution — refuse and ask
  for an address resolution step.
* "Bridge to Polygon" — refuse; only chains 1 and 11155111 supported.
* "Sign this raw hex" — refuse; there is no raw-signing oracle. The
  closest workflow is `decode_calldata` then a normal `propose_send`.
* "Drain this wallet to <address>" — surface as a high-risk action
  and require explicit user confirmation language.
