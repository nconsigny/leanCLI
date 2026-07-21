# tornado-cash — interactions

Drafting Tornado Cash transactions through the agent is **live** via the
`@kohaku-eth/tornado-cash` SDK (mainnet + Sepolia). This file enumerates
the decode flows plus the shield/unshield drafting recipes.

## Activation triggers

The skill activates when the user mentions "tornado cash", "tornado",
"mixer", or any of the four ETH-pool addresses listed in `SKILL.md` /
`contracts.json` (0.1, 1, 10, 100 ETH).

## Recipe 1 — "What is this calldata?"

1. User pastes raw calldata, or `SendRawFlow` is decoding an
   incoming tx whose `to` is one of the four pool addresses.
2. Agent uses `abi/ETHTornado.json` to decode the function:
   * `deposit(bytes32 _commitment)` — public input is a Poseidon /
     Pedersen commitment to the user's note.
   * `withdraw(bytes calldata _proof, bytes32 _root, bytes32 _nullifierHash, address payable _recipient, address payable _relayer, uint256 _fee, uint256 _refund)`
     — submits a proof to withdraw a fixed denomination.
3. If `abi/ETHTornado.json` is still the stubbed empty ABI, the
   decoder falls back to the 4byte directory. The agent surfaces
   the selector and the canonical signature.
4. The decoded view goes through ConfirmGate like any other tx.

## Recipe 2 — "What is Tornado Cash?"

1. Agent answers from `overview.md`:
   * Older-generation fixed-denomination zk-SNARK mixer.
   * leanCLI integration is live via `@kohaku-eth/tornado-cash`
     (mainnet + Sepolia).
   * Sibling shielded options: `skills/privacy-pool/`
     (`@kohaku-eth/privacy-pools`) or `skills/railgun/`
     (`@kohaku-eth/railgun`).
2. Agent does not propose any transaction unless the user asks to.

## Recipe 3 — "Draft me a Tornado Cash deposit / withdrawal"

1. The chat shortcut resolves deterministically in the RuleParser
   (`matchShielded`), so the LLM never has to guess:
   * `shield X ETH with tornado cash` → `.tornadoDeposit` (X a
     positive multiple of 0.1 ETH → N fixed-denomination legs).
   * `withdraw 0.1 ETH from tornado to <addr>` → `.tornadoWithdraw`
     (one note per call; recipient must be a wallet-derived address).
2. chat.draft emits a prepare envelope routing to
   `shielded.tornado.prepareDeposit` / `quoteWithdraw` /
   `executeWithdraw`. The witness/proof is built in the sidecar; the
   prepared legs flow through decode → simulate → ConfirmGate before
   any signature.
3. Withdrawals can append tail calls for an atomic withdraw-and-swap
   (paymaster mode only) — the swap executes inside the same 4337
   UserOp as the payout; if it reverts, the withdrawal reverts.

## Recipe 4 — "Compare Tornado Cash to Privacy Pools and Railgun"

1. Agent uses the comparison frame from `overview.md` plus the peer
   skills' overviews:
   * Tornado Cash: fixed denominations, no association-set
     affordances. Live via `@kohaku-eth/tornado-cash`.
   * Privacy Pools (`skills/privacy-pool/`): variable amounts, opt-in
     ASP for compliance affordances, `@kohaku-eth/privacy-pools` SDK,
     live in `bridge.mjs`.
   * Railgun (`skills/railgun/`): UTXO-style smart-wallet shielded
     accounts, POI gating, `@kohaku-eth/railgun` SDK, live in
     `bridge.mjs`.
2. Agent recommends the live alternatives for use today, while
   continuing to answer research questions on Tornado Cash itself.

## Bridge integration

When the SDK lands, `bridge/bridge.mjs:listProtocols` will gain a
`tornado-cash` entry alongside `privacy-pool` and `railgun`. The
calldata still flows through `decodeIntent → simulate → ConfirmGate`
before any signature — same trust model as every other surface in
the wallet.

Today the bridge does not list Tornado Cash; decoding happens
entirely in the Lean daemon via the on-chain ABI fallback path.
