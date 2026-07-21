# tornado-cash — security

## Status

Tornado Cash drafting is **live** via `@kohaku-eth/tornado-cash`
(mainnet + Sepolia). The agent produces both deposits and withdrawals,
each flowing through the standard `decodeIntent → simulate → ConfirmGate`
gate before any signature. This skill also still provides decode context
for incoming Tornado Cash calldata.

Sibling shielded backends: Privacy Pool (`@kohaku-eth/privacy-pools`)
and Railgun (`@kohaku-eth/railgun`).

## What the agent does today

| Request | Agent action |
|---|---|
| "What is Tornado Cash?" | Explain (see `overview.md`). |
| "Decode this calldata, it might be Tornado." | Decode via `abi/ETHTornado.json` + 4byte fallback; render through ConfirmGate. |
| "How does Tornado differ from Privacy Pools?" | Compare (see `interactions.md` Recipe 4). |
| "Draft a 1 ETH deposit." | Route `shield 1 ETH with tornado cash` → `.tornadoDeposit` → `shielded.tornado.prepareDeposit`; the prepared legs go through decode → simulate → ConfirmGate. |
| "Withdraw 0.1 ETH from tornado to 0x…" | Route → `.tornadoWithdraw` → `shielded.tornado.quoteWithdraw`/`executeWithdraw` (recipient must be a wallet-derived address). |
| "Withdraw and swap to DAI atomically." | Withdraw with appended tail calls (paymaster mode) — the swap runs inside the same 4337 UserOp as the payout. |

## Engineering posture

The integration follows the same shape as Privacy Pool and Railgun:

* Witness / proof generation in the untrusted Node sidecar.
* The Lean daemon never trusts the sidecar's output — every Tornado
  calldata blob flows through `decodeIntent → simulate → ConfirmGate`
  before any signature is produced.
* Notes are derived deterministically from the wallet seed (no note
  string to persist), disjoint from the BIP-44 and Railgun paths.
* Relayer / bundler endpoints are user-configurable; the daemon's network
  policy gates which endpoints the sidecar may reach (`shieldedBroadcast`).

## Decode-time behaviour

When the agent decodes a Tornado Cash calldata blob today (because
the user pasted one, or `SendRawFlow` is decoding an incoming tx
that references one of the pool addresses):

1. Identify the function from `abi/ETHTornado.json` (or the 4byte
   directory if the ABI stub is empty).
2. Pretty-print the call.
3. Render the decoded view through ConfirmGate. The user approves at
   the gate as with any other tx.

## Drafting surface

The chat regex parser (`RuleParser.matchShielded`) resolves both
`shield … with tornado cash` and `withdraw … from tornado …`
deterministically — the LLM is not consulted — and the wallet Privacy
menu offers Tornado alongside Privacy Pool and Railgun. Every drafted
deposit/withdrawal terminates at ConfirmGate before signing.
