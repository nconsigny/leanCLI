# tornado-cash — overview

## What it is

Tornado Cash is an Ethereum mixer using zk-SNARKs to break the
on-chain link between a deposit and the matching withdrawal. The
core pools are **fixed-denomination ETH** at 0.1, 1, 10, and 100 ETH
(and a parallel set of ERC-20 pools that this skill does not
catalogue). A user deposits a fixed amount, receives a secret
"note", and later withdraws from any address by submitting a
zero-knowledge proof of knowledge of the note's preimage.

This is an older protocol generation than Privacy Pools (no
association-set affordances) and Railgun (no shielded smart-wallet
UTXO model). It is documented here for **decode context**.

## Status in leanCLI

**Coming soon.** There is no `@kohaku-eth/tornado-cash` package
alongside `@kohaku-eth/privacy-pools` and `@kohaku-eth/railgun`. When
the SDK lands, the agent will draft Tornado Cash transactions through
the same `decode → simulate → ConfirmGate` pipeline used by the
other shielded protocols. Until then this skill is **decode-only**:
the agent recognizes Tornado Cash calldata when it appears in
incoming flows and explains what it does.

For shielded ETH today, the agent uses:

* **Privacy Pool** (`@kohaku-eth/privacy-pools`) — variable-
  denomination, association-set-proof gated. Trigger:
  `shield X ETH with privacy pool`.
* **Railgun** (`@kohaku-eth/railgun`) — variable-denomination,
  shielded smart-wallet model, POI-gated. Trigger: Privacy → Railgun
  menu (chat shortcut coming soon).

## What the agent does today

* **Decode** Tornado Cash calldata using `abi/ETHTornado.json` (a
  TODO stub today; the upstream source URL is in `contracts.json`).
  A decoded view of `deposit(commitment)` against the 0.1 ETH pool is
  surfaced through the standard ConfirmGate path.
* **Explain** the protocol mechanics (zk-SNARK proof of knowledge of
  a Merkle-tree leaf, fixed denominations, nullifier hash preventing
  double-withdraw).
* **Compare** Tornado Cash with Privacy Pools and Railgun — they
  solve the same problem at different points in the design space.

## What's coming with the SDK

* Drafting `deposit(commitment)` against any of the four ETH pools
  via the agent.
* Drafting `withdraw(proof, root, nullifierHash, recipient, ...)`
  via the agent.
* Note generation / persistence in the encrypted shielded-secret
  store, modeled on the existing PP and Railgun secret stores.
* Relayer plumbing (Tornado's withdraw path conventionally goes
  through a relayer so the recipient does not need pre-funded gas).

## No SDK yet

There is **no** `@kohaku-eth/tornado-cash` npm package yet.
`bridge/package.json` lists `@kohaku-eth/{plugins,railgun,privacy-pools}`;
no tornado entry. `bridge/bridge.mjs:listProtocols` does not list
Tornado Cash today.

## Citations

* On-chain source — <https://github.com/tornadocash/tornado-core>.
* Pool addresses — see `contracts.json`. Bytecode is verified on
  Etherscan; the contracts are immutable.
