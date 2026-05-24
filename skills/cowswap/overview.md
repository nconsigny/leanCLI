# cowswap — overview

## What it is

CoW Protocol (CoWSwap) is a **batch-auction DEX**: users sign an
EIP-712 `Order` off-chain, third-party **solvers** compete to find an
optimal settlement, and a single on-chain `settle` call by the winning
solver clears the batch. Coincidence-of-Wants ("CoWs") between
orders in the same batch produce surplus that flows back to the
traders.

The single mainnet/Sepolia/Gnosis-Chain contract is `GPv2Settlement`
at `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`. The user **never
calls it directly** in the happy path — the wallet's job is to
construct, decode, and confirm an off-chain EIP-712 signature.

## What the wallet sees

| Step | Where | What is signed |
|---|---|---|
| 1. Allow the settler to pull `sellToken` | On-chain ERC-20 `approve` to the `GPv2VaultRelayer` (= `vaultRelayer()` on the settlement contract) | `approve(spender, amount)` — covered by `bridge/clearsign/registry/erc20.json` |
| 2. Sign the `Order` | Off-chain EIP-712 | `Order(sellToken,buyToken,receiver,sellAmount,buyAmount,validTo,appData,feeAmount,kind,partiallyFillable,...)` — covered by `bridge/clearsign/registry/eip712-cowswap-order.json` |
| 3. (Optional) on-chain pre-sign | `GPv2Settlement.setPreSignature(orderUid, signed)` | The 56-byte `orderUid` only; the wallet MUST resolve it back to the underlying `Order` before signing |
| 4. Solver settles | `GPv2Settlement.settle(...)` | Submitted by the solver, not the user |

The `vaultRelayer` is the only address that needs ERC-20 allowance
from the user. Reading `vaultRelayer()` is a `chain.ethCall`.

## Order kinds

* `sell` — fixed `sellAmount`, `buyAmount` is the minimum acceptable
  receive (slippage floor).
* `buy` — fixed `buyAmount`, `sellAmount` is the maximum acceptable
  spend (slippage ceiling).

`partiallyFillable: false` is the default for retail-style flows;
partial fills are useful for large orders that solvers can fragment.

## Order lifetime

* `validTo` is a Unix timestamp; an order signed with `validTo` in the
  far future (e.g. `2**32 - 1`) is a free option for solvers and a
  refusal trigger. The agent default is `now + 30 minutes`.
* `invalidateOrder` is the on-chain rescind (costs gas). Refer the
  user to the off-chain "cancel" via the CoW API when possible.

## What this skill is NOT for

* Solver-side flows (`settle`, `swap`, simulation views) — those are
  not a wallet user's surface.
* MEV-blocker / private-mempool plumbing.

## Citations

* CoW Protocol docs — <https://docs.cow.fi/>
* GPv2 contracts repo — <https://github.com/cowprotocol/contracts>
* 7730 descriptor — `bridge/clearsign/registry/eip712-cowswap-order.json`
