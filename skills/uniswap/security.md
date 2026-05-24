# uniswap — security checks

## Pre-sign checklist (every swap)

1. `tokenIn` and `tokenOut` resolve to addresses present in
   `contracts.json` or in the user's input — never invent them.
2. The pool fee tier comes from a quoter or pool read, not from
   memory.
3. `amountOutMinimum > 0`. Refuse `amountOutMinimum = 0` — that
   accepts any output amount and is sandwich-vulnerable.
4. `deadline` is finite and ≤ `now + 1 hour`. Refuse `0` or
   `uint256.max`.
5. `recipient = msg.sender` unless the user explicitly named a
   different recipient.
6. Slippage tolerance ≤ 5%. Higher requires explicit user phrasing
   ("I know it's high, I want to push through").

## Router-specific risks

* **UniversalRouter** uses a `bytes commands` + `bytes[] inputs`
  packed layout that is hard to decode. The clearsign sidecar has
  partial coverage; surface every individual command if you can,
  refuse if you can't.
* **Permit2** signatures attached to a Universal Router call grant
  the router permission to pull tokens directly. Decode the Permit2
  typed data (via `decode_eip712` / clearsign descriptor) before
  signing — the user must see `spender = UniversalRouter`,
  `value`, and `deadline`.
* **Approvals**: the V3 SwapRouter02 holds no funds between calls;
  `tokenIn` allowance to the router is required (or a Permit2
  signature). Prefer exact-amount allowance over unlimited.

## Address verification

For every contract call the agent surfaces in `propose_send`, the
`to` field must match a `verified: true` entry in this skill's
`contracts.json` for the active chain. If it does not, refuse and
ask the user to confirm the address explicitly.

## MEV awareness (advisory, not enforcement)

* Sandwich attacks: a non-trivial swap with a tight
  `amountOutMinimum` is the attacker's lunch. Surface the predicted
  slippage to the user.
* Front-running: a public mempool tx with an unbroadcast
  signature can be replayed. The wallet does not currently route
  through private mempools; surface the fact.
