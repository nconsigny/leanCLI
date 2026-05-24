# tornado-cash — interactions

There is no "typical user flow" for Tornado Cash through Kohaku.
There is no `@kohaku-eth/tornado-cash` SDK, no `tornado.*` JSON-RPC
method in `bridge/bridge.mjs`, and the agent does not draft outgoing
Tornado Cash transactions (see `security.md`). This file enumerates
the **decode-only** flows the agent uses when the skill activates.

## Activation triggers

The skill activates when the user mentions "tornado cash", "tornado",
"mixer", or any of the four ETH-pool addresses listed in
`SKILL.md` / `contracts.json` (0.1, 1, 10, 100 ETH).

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
4. Agent surfaces the OFAC banner from `contracts.json`'s
   sanctioned-address flag.
5. Agent stops. If the user follows up with "now sign this", the
   agent declines per the discuss/draft boundary in `security.md`.

## Recipe 2 — "What is Tornado Cash?"

1. Agent answers from `overview.md`:
   * Older-generation fixed-denomination zk-SNARK mixer.
   * On the OFAC SDN list since 2022-08-08.
   * Kohaku ships no SDK.
   * For active privacy, the user is steered to
     `skills/privacy-pool/` or `skills/railgun/`.
2. Agent does not propose any transaction.

## Recipe 3 — "Draft me a Tornado Cash deposit / withdrawal"

1. Agent declines. The refusal cites two facts:
   * OFAC SDN listing (E.O. 13694; Treasury press release of
     2022-08-08).
   * Absence of a maintained `@kohaku-eth/tornado-cash` SDK; no
     code path inside the wallet computes a Tornado note or
     produces a proof.
2. Agent does **not** moralize or refuse to discuss; the user can
   ask follow-up research questions and the agent answers them.
3. Agent points at Privacy Pools / RAILGUN as maintained,
   SDK-backed alternatives if the user's goal is active privacy.

## Recipe 4 — "Compare Tornado Cash to Privacy Pools and RAILGUN"

1. Agent uses the comparison frame from `overview.md` plus the
   peer skills' overviews:
   * Tornado Cash: fixed denominations, no association set,
     sanctioned, no maintained SDK.
   * Privacy Pools (`skills/privacy-pool/`): variable amounts,
     opt-in ASP for compliance, `@kohaku-eth/privacy-pools` SDK,
     live in `bridge.mjs`.
   * RAILGUN (`skills/railgun/`): UTXO-style smart-wallet shielded
     accounts, POI gating, `@kohaku-eth/railgun` SDK, listed as
     `stub` in `bridge.mjs` (installed, not yet wired).
2. Agent recommends the maintained options for active use, while
   answering the research question on Tornado Cash itself.

## Anti-patterns

* Drafting any transaction whose `to` is in the `mainnet` table of
  `contracts.json` — refused.
* Generating a deposit commitment or note — refused.
* Picking a Tornado relayer — refused.
* Refusing to **discuss** Tornado Cash on sanctions grounds —
  also wrong; the agent surfaces facts and engages with research
  questions.

## No bridge integration

Because Kohaku has no Tornado SDK, the bridge has nothing to wire.
`bridge/bridge.mjs:listProtocols` does not list Tornado Cash, and
there is no `tornado.*` JSON-RPC handler. Decoding happens entirely
in the Lean daemon via the on-chain ABI fallback path.
