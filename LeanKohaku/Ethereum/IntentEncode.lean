import LeanKohaku.Crypto.Hex
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Erc20
import LeanKohaku.Ethereum.Intent

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

* `nativeTransfer`  — no calldata
* `erc20Transfer`   — `transfer(address,uint256)`
* `erc20Approve`    — `approve(address,uint256)`; `.unlimited` resolves
  to `2^256 - 1`
* `rawCall`         — pass-through, hex-encoded data

## What it deliberately does NOT cover

`uniswapV3SwapSingle`, `aaveV3Supply`, `aaveV3Withdraw` are deferred to
their per-action daemon RPCs (`swap.uniV3.build`, future
`aave.*.build`). Those RPCs do chain-aware work (router address per
chain, pre-flight allowance probe, market parameter lookup) that this
pure encoder cannot. `encode` rejects them with a clear error pointing
to the right RPC; the chat path produces them as separate Intents
anyway (approve → wait-for-confirm → swap), so the leaf-only encoder is
the right shape.
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

/-- Pure encoder. `.ok` for the leaf actions; `.error` with a pointer to
the right per-action RPC for the multi-step actions. -/
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
  | .uniswapV3SwapSingle _ _ _ _ _ _ _ _ =>
      .error "uniswapV3SwapSingle: use the swap.uniV3.build RPC (chain-aware router resolution + approval probe)"
  | .aaveV3Supply _ _ _ _ =>
      .error "aaveV3Supply: emit erc20Approve first, then aaveV3Supply via the dedicated per-action RPC"
  | .aaveV3Withdraw _ _ _ _ =>
      .error "aaveV3Withdraw: use the dedicated per-action RPC"
  | .rawCall _ to valueWei data _rationale =>
      .ok { to := addrHex to
            valueWei := valueWei
            data := LeanKohaku.Crypto.Hex.encode data }

end LeanKohaku.Ethereum.IntentEncode
