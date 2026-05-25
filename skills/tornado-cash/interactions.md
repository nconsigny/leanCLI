# tornado-cash — interactions

Drafting Tornado Cash transactions through the agent is **coming soon**
(waits on the `@kohaku-eth/tornado-cash` SDK). This file enumerates
the decode flows the agent uses today plus the "coming soon" surface
when the user asks for a draft.

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
   * Kohaku integration is coming soon; the `@kohaku-eth/tornado-cash`
     SDK is not yet shipped.
   * For active shielding today, the user is steered to
     `skills/privacy-pool/` (`@kohaku-eth/privacy-pools`) or
     `skills/railgun/` (`@kohaku-eth/railgun`).
2. Agent does not propose any transaction (yet).

## Recipe 3 — "Draft me a Tornado Cash deposit / withdrawal"

1. Agent responds: **coming soon**. The Kohaku Tornado Cash SDK is
   not yet shipped; once it is, the chat path mirrors the existing
   Privacy Pool / Railgun flow (witness in sidecar → decode →
   simulate → ConfirmGate → broadcast).
2. Agent points at the active alternatives for shielding ETH today:
   `Privacy → Privacy Pool` or `Privacy → Railgun` from the wallet
   menu, or the chat shortcut `shield X ETH with privacy pool`.

## Recipe 4 — "Compare Tornado Cash to Privacy Pools and Railgun"

1. Agent uses the comparison frame from `overview.md` plus the peer
   skills' overviews:
   * Tornado Cash: fixed denominations, no association-set
     affordances. Kohaku integration coming soon.
   * Privacy Pools (`skills/privacy-pool/`): variable amounts, opt-in
     ASP for compliance affordances, `@kohaku-eth/privacy-pools` SDK,
     live in `bridge.mjs`.
   * Railgun (`skills/railgun/`): UTXO-style smart-wallet shielded
     accounts, POI gating, `@kohaku-eth/railgun` SDK, listed as
     `stub` in `bridge.mjs` (installed, not yet fully wired).
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
