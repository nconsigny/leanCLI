---
name: kohaku-wallet
version: 0.1
description: Wallet operating model — pre-sign pipeline, signer/path separation, ConfirmGate, nonce monotonicity.
category: meta
alwaysOn: true
ofacFlagged: false
---

# kohaku-wallet (meta-skill, always on)

leanKohaku is a formally-verified Ethereum wallet daemon written in
Lean 4. This meta-skill documents the wallet's operating model so the
agent never proposes an action that the verified core would reject.
The full proof inventory lives in `INVARIANTS.md`.
