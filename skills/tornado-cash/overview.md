# tornado-cash — overview

## What it was

Tornado Cash was an Ethereum mixer using zk-SNARKs to break the
on-chain link between a deposit and the matching withdrawal. The
core pools are **fixed-denomination ETH** at 0.1, 1, 10, and 100
ETH (and a parallel set of ERC-20 pools that this skill does not
catalogue). A user deposits a fixed amount, receives a secret
"note", and later withdraws from any address by submitting a
zero-knowledge proof of knowledge of the note's preimage.

This is an older protocol generation than Privacy Pools (no
association set / opt-in compliance hooks) and RAILGUN (no shielded
smart-wallet UTXO model). It is described here in past tense
because:

1. Its primary deployments are on the OFAC SDN list (see
   `security.md`).
2. The maintained client (Tornado Cash Nova, the web UI) is
   defunct.
3. There is no `@kohaku-eth/tornado-cash` package — upstream
   Kohaku does not ship one, and this repo does not ship one
   either.

## Why this skill exists

The agent encounters Tornado Cash in three contexts:

* A user pastes raw calldata that turns out to be a Tornado Cash
  function call and asks "what is this?".
* A user asks an explanatory / historical question ("what is
  Tornado Cash?", "how does it differ from Privacy Pools?", "why
  is it sanctioned?").
* A user asks the agent to **draft** a Tornado Cash deposit or
  withdrawal.

The first two are research / decode use cases; the agent answers
them. The third is a draft use case; the agent declines.

This bifurcation is deliberate. The user is a researcher in a
jurisdiction where research-context discussion is legal; the agent
should not refuse to engage with the topic. But the agent is part
of a signing-capable wallet, and a "draft Tornado Cash tx" request
crosses from research to action against sanctioned contracts —
that is what the agent declines.

## What the agent CAN do

* **Decode** Tornado Cash calldata using `abi/ETHTornado.json` (a
  TODO stub today; the upstream source URL is in `contracts.json`).
  Tornado's contracts are public knowledge, simple, and old; a
  decoded view of "this is a `deposit(commitment)` against the
  0.1 ETH pool" is fine to surface.
* **Explain** the protocol mechanics (zk-SNARK proof of knowledge
  of a Merkle-tree leaf, fixed denominations, nullifier hash
  preventing double-withdraw).
* **Explain** why the protocol is sanctioned and the practical
  consequences (front-end takedowns, exchange screening, etc).
* **Compare** Tornado Cash with Privacy Pools and RAILGUN when
  asked — they solve the same problem at very different points in
  the design space.

## What the agent CANNOT do

* **Draft a `deposit(commitment)` transaction** against any of the
  four ETH pools listed in `contracts.json` — declined.
* **Draft a `withdraw(...)` transaction** against any of the four
  ETH pools — declined.
* **Generate a deposit commitment / note** — declined; the SDK does
  not exist, so this would require importing snarkjs and a copy of
  the Tornado circuit, which the wallet refuses to do.
* **Submit to a Tornado relayer** — declined.

A user who wants Tornado-style privacy in 2026 is steered toward
Privacy Pools (`skills/privacy-pool/`) or RAILGUN
(`skills/railgun/`) — both maintained, both with `@kohaku-eth/*`
SDKs, both designed with compliance affordances Tornado lacks.

## No SDK

There is **no** `@kohaku-eth/tornado-cash` npm package and no plans
for one. Trying to import one yields `MODULE_NOT_FOUND`. The
absence is intentional; documenting it here saves a future
contributor from being confused that "every privacy skill needs an
SDK section but tornado's is missing".

## Bridge wiring status

`bridge/bridge.mjs:listProtocols` does NOT list Tornado Cash. There
are no `tornado.*` JSON-RPC methods. There is no plan to add any.

## Citations

* OFAC SDN listing — <https://home.treasury.gov/news/press-releases/jy0916>
  (Treasury press release, 2022-08-08).
* Sanction authority — Executive Order 13694 (cyber-enabled
  malicious activity).
* On-chain source — <https://github.com/tornadocash/tornado-core>.
* No SDK — `bridge/package.json` lists `@kohaku-eth/{plugins,railgun,privacy-pools}`; no tornado entry.
