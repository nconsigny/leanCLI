---
name: tornado-cash
version: 0.2
description: Tornado Cash fixed-denomination ETH mixer — shield (deposit) and unshield (withdraw) via @kohaku-eth/tornado-cash. Mainnet + Sepolia.
category: protocol
alwaysOn: false
triggers:
  - tornado cash
  - tornado
  - mixer
  - 0x12d66f87a04a9e220743712ce6d9bb1b5616b8fc
  - 0x47ce0c6ed5b0ce3d3a51fdb1c52dc66a7c3c2936
  - 0x910cbd523d972eb0a6f4cae4618ad62622b39dbf
  - 0xa160cdab225685da1d56aa342ad8841c3b53f291
requires:
  daemonRpcs:
    - shielded.tornado.balance
    - shielded.tornado.notes
    - shielded.tornado.prepareDeposit
    - shielded.tornado.quoteWithdraw
    - shielded.tornado.executeWithdraw
---

# tornado-cash — fixed-denomination ETH mixer

Tornado Cash breaks the on-chain link between a deposit and a withdrawal using
zk-SNARKs over fixed-denomination pools. leanCLI drives it through
`@kohaku-eth/tornado-cash` in the untrusted bridge sidecar. ETH-only today.

## Denominations (mandatory)

Pools are **fixed-denomination**: `0.1`, `1`, `10`, `100` ETH (Sepolia has
`0.1` / `1`). A shield of a larger amount that is a multiple of `0.1` becomes
several separate fixed-denomination deposits (each its own leg). Any amount
that is not a positive multiple of `0.1` ETH is rejected daemon-side. A
withdrawal spends **exactly one** denomination per call.

## No note to save

Unlike classic Tornado, there is **no note string**. The bridge derives each
note's secrets deterministically from the wallet seed (BIP-32 under
`m/29795'/1'`, bound to chain+pool). The wallet seed alone recovers every
deposit — never ask the user to save or paste a note, and never fabricate one.

## Shield (deposit)

* `shield 0.1 ETH with tornado cash`
* `deposit 1 ETH into tornado`

Routes to `shielded.tornado.prepareDeposit`, which returns **unsigned**
`deposit(commitment)` legs. Each leg flows through the normal
decode → simulate → ConfirmGate → `eoa.send` gate — shielded calldata is still
calldata, and the daemon refuses a deposit value it did not derive. Gas is paid
from the source EOA, which links the source to the deposit *timing*.

## Unshield (withdraw)

* `unshield 0.1 ETH from tornado to 0x…`
* `withdraw 1 ETH from tornado cash to <fresh address>`

Two steps, no EOA signature (a groth16 proof authorizes the spend):

1. `shielded.tornado.quoteWithdraw` — builds the fee terms without
   broadcasting. **Paymaster mode** (default): gas is paid out of the note via
   an ERC-4337 paymaster + Pimlico bundler, and the net (`denomination − fee`)
   is forwarded to the recipient — so the recipient receives slightly less than
   the denomination. **Relayer mode** (`mode: "relayer"`): a classic ENS relayer
   submits the proof. Confirming the quoted terms IS the pre-broadcast gate.
2. `shielded.tornado.executeWithdraw` — builds the proof and broadcasts it.

The recipient MUST be a **FRESH address** with no on-chain link to the deposit
source; reusing a linked address defeats the mixer. This is the only chance to
break anonymity if mis-picked.

## Privacy caveats (tell the user)

* The anonymity set is other users of the *same pool*. Depositing and
  withdrawing in quick succession, or with distinctive amounts, shrinks it.
* Gas payment on deposit links the source EOA to the deposit's timing.
* On **mainnet**, shielded broadcasts (the withdraw quote/execute) are denied by
  the default strict daemon policy and require a `tor`/`permissive` policy — the
  same posture as Privacy Pools and Railgun. Deposits (unsigned calldata) are
  not gated as broadcasts.
