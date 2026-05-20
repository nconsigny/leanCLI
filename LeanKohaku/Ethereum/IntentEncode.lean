import LeanKohaku.Aave.V3Pool
import LeanKohaku.Crypto.Hex
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Erc20
import LeanKohaku.Ethereum.Intent
import LeanKohaku.Swap.Tokens
import LeanKohaku.Swap.UniV3

/-!
# Intent → encoded transaction

Single Lean entry point from the semantic `Intent` ADT to the
`{to, value, data}` shape that the simulate / sign pipeline consumes.

Both the trusted hard-wired UX and the opt-in LLM chat path produce an
`Intent`, then call into this module. Having one encoder for both paths
means one trust boundary, one place to audit, and one place for the
canonical-representation property (`encode` is deterministic and total
on the supported intents).

## What this module covers (pure leaf actions)

* `nativeTransfer`       — no calldata
* `erc20Transfer`        — `transfer(address,uint256)`
* `erc20Approve`         — `approve(address,uint256)`; `.unlimited`
  resolves to `2^256 - 1`
* `uniswapV3SwapSingle`  — `SwapRouter02.exactInputSingle` (token→token
  only; the Router address is resolved from the chain registry)
* `aaveV3Supply`         — Pool.`supply(asset, amount, onBehalfOf, 0)`
* `aaveV3Withdraw`       — Pool.`withdraw(asset, amount, recipient)`
* `rawCall`              — pass-through, hex-encoded data

## What it deliberately does NOT cover

* ETH-leg Uniswap V3 swaps (`tokenIn = WETH(eth-mode)` or
  `tokenOut = WETH(eth-mode)`): those need the `multicall` wrapper
  (refundETH / unwrapWETH9). Those still go through `swap.uniV3.build`,
  which co-locates the multicall logic. Token→token swaps are encoded
  here; the encoder is paramterized on the chain to pick the right
  Router.
* The approval pre-step for `aaveV3Supply`: the chat path emits an
  `erc20Approve` Intent separately, and the user confirms each leg via
  the same ConfirmGate. This encoder produces the bare `supply`
  calldata; chaining is the caller's job.
-/

namespace LeanKohaku.Ethereum.IntentEncode

open LeanKohaku.Ethereum.Address (Address)
open LeanKohaku.Ethereum.Intent

/-- The encoded form: target, native value (wei), and calldata. All hex
strings are lowercase, `0x`-prefixed. `data` is `"0x"` for native
transfers (no calldata). -/
structure EncodedTx where
  to       : String
  valueWei : Nat
  data     : String
  deriving Repr

/-- Render a typed `Address` as a `0x`-prefixed lowercase hex string. -/
def addrHex (a : Address) : String :=
  LeanKohaku.Crypto.Hex.encode a.bytes

/-- Resolve an `ApproveAmount` to its on-chain `uint256` value.
`unlimited` maps to `2^256 - 1`. -/
def approveAmountToNat : ApproveAmount → Nat
  | .exact n    => n
  | .unlimited  => LeanKohaku.Ethereum.Erc20.maxUint256

/-- Map a numeric chain id to the registry's `ChainId` enum. Used by
    the swap encoder to look up the SwapRouter02 address. -/
private def chainEnum (cid : Nat) : Option LeanKohaku.Swap.Tokens.ChainId :=
  match cid with
  | 1        => some .mainnet
  | 11155111 => some .sepolia
  | _        => none

/-- Pure encoder. `.ok` for every Intent variant the wallet has decided
    is a leaf-encodable shape; `.error` when an Intent needs work that
    this pure module cannot do (e.g. ETH-leg swaps, which need the
    multicall wrapper from `swap.uniV3.build`). -/
def encode : Intent → Except String EncodedTx
  | .nativeTransfer _ to amountWei =>
      .ok { to := addrHex to, valueWei := amountWei, data := "0x" }
  | .erc20Transfer _ token _decimals to amount =>
      .ok { to       := addrHex token
            valueWei := 0
            data     := LeanKohaku.Ethereum.Erc20.encodeTransfer (addrHex to) amount }
  | .erc20Approve _ token spender amount =>
      .ok { to       := addrHex token
            valueWei := 0
            data     := LeanKohaku.Ethereum.Erc20.encodeApprove
                          (addrHex spender) (approveAmountToNat amount) }
  | .uniswapV3SwapSingle cid tokenIn tokenOut amountIn fee minAmountOut recipient _deadline =>
      -- Slippage floor is structural: refuse minAmountOut = 0 BEFORE the
      -- chain check. The IntentTrusted invariant
      -- `encode_swap_refuses_zero_minOut` proves this branch is taken
      -- by-rfl when minAmountOut = 0; reordering would break that proof.
      if minAmountOut = 0 then
        .error "uniswapV3SwapSingle: minAmountOut = 0 refused (would accept any slippage)"
      else
        match chainEnum cid with
        | none =>
            .error s!"uniswapV3SwapSingle: chain {cid} not in Lean registry — no Router address"
        | some ce =>
            let router := LeanKohaku.Swap.UniV3.routerFor ce
            .ok { to       := router
                  valueWei := 0
                  data     := LeanKohaku.Swap.UniV3.encodeExactInputSingle
                    { tokenIn := addrHex tokenIn
                      tokenOut := addrHex tokenOut
                      fee := fee
                      recipient := addrHex recipient
                      amountIn := amountIn
                      amountOutMinimum := minAmountOut } }
  | .aaveV3Supply cid asset amount onBehalfOf =>
      match LeanKohaku.Aave.V3Pool.poolForChainId cid with
      | none =>
          .error s!"aaveV3Supply: Aave V3 Pool address unknown on chain {cid}"
      | some pool =>
          .ok { to       := pool
                valueWei := 0
                data     := LeanKohaku.Aave.V3Pool.encodeSupply
                              (addrHex asset) amount (addrHex onBehalfOf) 0 }
  | .aaveV3Withdraw cid asset amount recipient =>
      match LeanKohaku.Aave.V3Pool.poolForChainId cid with
      | none =>
          .error s!"aaveV3Withdraw: Aave V3 Pool address unknown on chain {cid}"
      | some pool =>
          .ok { to       := pool
                valueWei := 0
                data     := LeanKohaku.Aave.V3Pool.encodeWithdraw
                              (addrHex asset) amount (addrHex recipient) }
  | .rawCall _ to valueWei data _rationale =>
      .ok { to := addrHex to
            valueWei := valueWei
            data := LeanKohaku.Crypto.Hex.encode data }
  -- The four privacy/hygiene/wallet variants are NOT leaf-encodable:
  -- `shielded.*` requires the bridge sidecar's witness generation
  -- (chat.draft routes them to `shielded.prepareDeposit` / `…
  -- prepareWithdraw` which return one or more prepared txs); the
  -- read-only `approvals.audit` and the local `address.fresh`
  -- never produce signing-path calldata. Returning `.error` here
  -- guarantees that any code path which mistakenly tries to encode
  -- them through this module surfaces the bug immediately, rather
  -- than silently producing a wrong tx.
  | .shieldedDeposit _ _ =>
      .error "shielded.deposit: not leaf-encodable; route via daemon RPC shielded.prepareDeposit"
  | .shieldedWithdraw _ _ _ _ =>
      .error "shielded.withdraw: not leaf-encodable; route via daemon RPC shielded.prepareWithdraw"
  | .approvalsAudit _ _ =>
      .error "approvals.audit: read-only action; no encoded tx"
  | .freshAddress _ _ _ _ =>
      .error "address.fresh: local wallet creation; no encoded tx"

end LeanKohaku.Ethereum.IntentEncode
