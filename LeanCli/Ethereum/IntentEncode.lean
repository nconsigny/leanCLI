import LeanCli.Aave.V3Pool
import LeanCli.Crypto.Hex
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Erc20
import LeanCli.Ethereum.Intent
import LeanCli.Swap.Tokens
import LeanCli.Swap.UniV3

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

namespace LeanCli.Ethereum.IntentEncode

open LeanCli.Ethereum.Address (Address)
open LeanCli.Ethereum.Intent

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
  LeanCli.Crypto.Hex.encode a.bytes

/-- Resolve an `ApproveAmount` to its on-chain `uint256` value.
`unlimited` maps to `2^256 - 1`. -/
def approveAmountToNat : ApproveAmount → Nat
  | .exact n    => n
  | .unlimited  => LeanCli.Ethereum.Erc20.maxUint256

/-- Map a numeric chain id to the registry's `ChainId` enum. Used by
    the swap encoder to look up the SwapRouter02 address. -/
private def chainEnum (cid : Nat) : Option LeanCli.Swap.Tokens.ChainId :=
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
            data     := LeanCli.Ethereum.Erc20.encodeTransfer (addrHex to) amount }
  | .erc20Approve _ token spender amount =>
      .ok { to       := addrHex token
            valueWei := 0
            data     := LeanCli.Ethereum.Erc20.encodeApprove
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
            let router := LeanCli.Swap.UniV3.routerFor ce
            .ok { to       := router
                  valueWei := 0
                  data     := LeanCli.Swap.UniV3.encodeExactInputSingle
                    { tokenIn := addrHex tokenIn
                      tokenOut := addrHex tokenOut
                      fee := fee
                      recipient := addrHex recipient
                      amountIn := amountIn
                      amountOutMinimum := minAmountOut } }
  | .aaveV3Supply cid asset amount onBehalfOf =>
      match LeanCli.Aave.V3Pool.poolForChainId cid with
      | none =>
          .error s!"aaveV3Supply: Aave V3 Pool address unknown on chain {cid}"
      | some pool =>
          .ok { to       := pool
                valueWei := 0
                data     := LeanCli.Aave.V3Pool.encodeSupply
                              (addrHex asset) amount (addrHex onBehalfOf) 0 }
  | .aaveV3Withdraw cid asset amount recipient =>
      match LeanCli.Aave.V3Pool.poolForChainId cid with
      | none =>
          .error s!"aaveV3Withdraw: Aave V3 Pool address unknown on chain {cid}"
      | some pool =>
          .ok { to       := pool
                valueWei := 0
                data     := LeanCli.Aave.V3Pool.encodeWithdraw
                              (addrHex asset) amount (addrHex recipient) }
  | .rawCall _ to valueWei data _rationale =>
      .ok { to := addrHex to
            valueWei := valueWei
            data := LeanCli.Crypto.Hex.encode data }
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
  | .railgunShield _ _ =>
      .error "shielded.railgun.shield: not leaf-encodable; route via daemon RPC shielded.railgun.prepareShield"
  | .railgunUnshield _ _ _ =>
      .error "shielded.railgun.unshield: not leaf-encodable; route via daemon RPC shielded.railgun.unshield"
  | .tornadoDeposit _ _ =>
      .error "shielded.tornado.deposit: not leaf-encodable; route via daemon RPC shielded.tornado.prepareDeposit (sidecar generates the Pedersen-hashed commitment)"
  | .tornadoWithdraw _ _ _ _ =>
      .error "shielded.tornado.withdraw: not leaf-encodable; route via daemon RPC shielded.tornado.prepareWithdraw (sidecar generates the ZK proof from the user's saved note + current merkle state)"
  | .approvalsAudit _ _ =>
      .error "approvals.audit: read-only action; no encoded tx"
  | .ensRegister _ _ _ _ =>
      .error "ens.register: not leaf-encodable here; route via daemon RPC ens.prepareRegister so the persisted commit-secret is loaded and the calldata reconstructs the same commitment the user already committed to"
  | .ensRenew _ _ _ =>
      .error "ens.renew: not leaf-encodable here; route via daemon RPC ens.prepareRenew so the controller's renew fee can be quoted via eth_call before signing"
  | .ensSetAddr _ _ _ =>
      .error "ens.setAddr: not leaf-encodable here; route via daemon RPC ens.prepareSetAddr so the bytes32 namehash is computed in the daemon's Keccak path and the resolver address is looked up per-name"
  | .ensSetName _ _ _ =>
      .error "ens.setName: not leaf-encodable here; route via daemon RPC ens.prepareSetName"
  | .lidoStake _ _ =>
      .error "stake (Lido): not leaf-encodable here; route via daemon RPC stake.lido.prepare so the Lido contract address can be looked up per chain"
  | .liquityOpenTrove _ _ _ _ _ _ =>
      .error "liquity.openTrove: not leaf-encodable here; route via daemon RPC liquity.prepareOpenTrove so upper/lower hints can be quoted from HintHelpers and the branch-specific BorrowerOperations is selected"
  | .liquityCloseTrove _ _ _ _ =>
      .error "liquity.closeTrove: not leaf-encodable here; route via daemon RPC liquity.prepareCloseTrove"
  | .protocolClaim _ _ =>
      .error "protocol.claim: not leaf-encodable here; route via daemon RPC <protocol>.prepareClaim"
  | .freshAddress _ _ _ _ =>
      .error "address.fresh: local wallet creation; no encoded tx"

end LeanCli.Ethereum.IntentEncode
