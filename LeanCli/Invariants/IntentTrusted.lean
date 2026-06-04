import LeanCli.Ethereum.Erc20
import LeanCli.Ethereum.Intent
import LeanCli.Ethereum.IntentEncode

/-!
# Invariants for the trusted-path intent encoder

Proofs that `LeanCli.Ethereum.IntentEncode.encode` behaves correctly
on the **leaf** intent variants (`nativeTransfer`, `erc20Transfer`,
`erc20Approve`, `rawCall`) — the ones the trusted hard-wired Send/Swap
UX produces.

These theorems make precise the contract the TUI relies on:

* The encoder is **total** on the four leaf variants.
  (Swap is partial — `minAmountOut = 0` is rejected. Aave is partial
  on chain id: chains the registry doesn't know fall through to
  `.error`. Both are deliberate.)
* What goes in is what comes out: native value, recipient slot, and
  approve sentinel are preserved.
* `rawCall` doesn't accidentally lose the caller's `valueWei`.
* The slippage floor for swaps is enforced *structurally*, not by
  runtime convention.

No `sorry`. Mathlib is intentionally not a dependency of this project,
so these proofs use only Lean core. The cost: we don't prove anything
about the *byte content* of the encoded calldata (`encodeUint256`'s
output as a function of its input) — that requires arithmetic
machinery we don't have yet. The proofs here are about *structure*:
which constructor fires, which field flows through.
-/

namespace LeanCli.Invariants.IntentTrusted

open LeanCli.Ethereum.Intent
open LeanCli.Ethereum.IntentEncode
open LeanCli.Ethereum.Address (Address)

/-! ## Totality on leaf variants -/

/-- The encoder always succeeds on `nativeTransfer`. -/
theorem encode_native_total
    (cid : ChainId) (to : Address) (amt : Amount) :
    ∃ enc, encode (.nativeTransfer cid to amt) = .ok enc := by
  exact ⟨_, rfl⟩

/-- The encoder always succeeds on `erc20Transfer`. -/
theorem encode_erc20_transfer_total
    (cid : ChainId) (token : Address) (dec : Nat) (to : Address) (amt : Amount) :
    ∃ enc, encode (.erc20Transfer cid token dec to amt) = .ok enc := by
  exact ⟨_, rfl⟩

/-- The encoder always succeeds on `erc20Approve`. -/
theorem encode_erc20_approve_total
    (cid : ChainId) (token spender : Address) (a : ApproveAmount) :
    ∃ enc, encode (.erc20Approve cid token spender a) = .ok enc := by
  exact ⟨_, rfl⟩

/-- The encoder always succeeds on `rawCall`. -/
theorem encode_rawCall_total
    (cid : ChainId) (to : Address) (v : Amount) (data : ByteArray) (r : String) :
    ∃ enc, encode (.rawCall cid to v data r) = .ok enc := by
  exact ⟨_, rfl⟩

/-! ## Field preservation: what goes in is what comes out -/

/-- The encoded native-transfer carries exactly the requested wei
amount in `valueWei`. The TUI builds an Intent from a form field; this
theorem rules out a class of bug where the encoder silently rescales
or drops the amount. -/
theorem encode_native_value_preserved
    (cid : ChainId) (to : Address) (amt : Amount) :
    (encode (.nativeTransfer cid to amt)).map (·.valueWei) = .ok amt := by
  rfl

/-- A native transfer carries no calldata. (Structural property — rules
out the trusted path accidentally emitting a contract call.) -/
theorem encode_native_no_calldata
    (cid : ChainId) (to : Address) (amt : Amount) :
    (encode (.nativeTransfer cid to amt)).map (·.data) = .ok "0x" := by
  rfl

/-- An ERC-20 transfer never carries native value. (Structural — rules
out accidentally double-paying in ETH on top of an ERC-20 transfer.) -/
theorem encode_erc20_transfer_value_zero
    (cid : ChainId) (token : Address) (dec : Nat) (to : Address) (amt : Amount) :
    (encode (.erc20Transfer cid token dec to amt)).map (·.valueWei) = .ok 0 := by
  rfl

/-- An ERC-20 approve never carries native value. -/
theorem encode_erc20_approve_value_zero
    (cid : ChainId) (token spender : Address) (a : ApproveAmount) :
    (encode (.erc20Approve cid token spender a)).map (·.valueWei) = .ok 0 := by
  rfl

/-- The unlimited-approve sentinel resolves to the canonical
`2^256 - 1`. (Catches a silent rename / wrong constant.) -/
theorem approve_unlimited_is_max_uint :
    approveAmountToNat .unlimited = LeanCli.Ethereum.Erc20.maxUint256 := by
  rfl

/-- An exact-approve carries through the caller's amount unchanged. -/
theorem approve_exact_preserved (n : Nat) :
    approveAmountToNat (.exact n) = n := by
  rfl

/-- A raw call preserves its `valueWei`. -/
theorem encode_rawCall_value_preserved
    (cid : ChainId) (to : Address) (v : Amount) (data : ByteArray) (r : String) :
    (encode (.rawCall cid to v data r)).map (·.valueWei) = .ok v := by
  rfl

/-! ## The slippage floor is structural -/

/-- The swap encoder REFUSES a `minAmountOut = 0` swap. This rules out
an entire bug class: the trusted UX cannot accidentally produce a swap
that accepts any amountOut. -/
theorem encode_swap_refuses_zero_minOut
    (cid : ChainId) (tIn tOut : Address) (aIn fee : Nat) (rcp : Address) (dl : Nat) :
    ∃ msg, encode (.uniswapV3SwapSingle cid tIn tOut aIn fee 0 rcp dl) = .error msg := by
  exact ⟨_, rfl⟩

/-! ## Chain id flows through the type -/

/-- The `Intent.chainId` projector agrees with the constructor argument
on `nativeTransfer`. (Trivial by definition; included to make the
contract explicit in proof form, since the daemon RPC re-emits this.) -/
theorem chainId_native
    (cid : ChainId) (to : Address) (amt : Amount) :
    Intent.chainId (.nativeTransfer cid to amt) = cid := rfl

/-- Same for `erc20Approve` — verifies the projector handles the
multi-arg constructor correctly. -/
theorem chainId_approve
    (cid : ChainId) (token spender : Address) (a : ApproveAmount) :
    Intent.chainId (.erc20Approve cid token spender a) = cid := rfl

end LeanCli.Invariants.IntentTrusted
