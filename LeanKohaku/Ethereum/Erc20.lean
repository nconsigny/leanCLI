import LeanKohaku.Swap.UniV3

/-!
# ERC-20 calldata encoders

Function selectors + ABI encoders for the ERC-20 surface the wallet
needs. `approve` already lives in `LeanKohaku.Swap.UniV3` (alongside the
swap-specific selectors); this module adds `transfer` and re-exports the
allowance/approve helpers so callers don't need both imports.

All encoded calldata is returned as a `0x`-prefixed lowercase hex
string. Reuses the `padLeft32` / `encodeAddress` / `encodeUint256`
primitives that already live in `LeanKohaku.Swap.UniV3` rather than
introducing a parallel set.
-/

namespace LeanKohaku.Ethereum.Erc20

/-! ## Selectors (computed via `keccak256(signature)[:4]`).

  - transfer(address,uint256)    = 0xa9059cbb
  - approve(address,uint256)     = 0x095ea7b3   [also in Swap.UniV3]
  - allowance(address,address)   = 0xdd62ed3e   [also in Swap.UniV3]
-/

def selTransfer : String := "a9059cbb"

/-- `transfer(address recipient, uint256 amount)`. -/
def encodeTransfer (recipient : String) (amount : Nat) : String :=
  "0x" ++ selTransfer
    ++ LeanKohaku.Swap.UniV3.encodeAddress recipient
    ++ LeanKohaku.Swap.UniV3.encodeUint256 amount

/-- Re-export of `Swap.UniV3.encodeApprove` so callers can write
`Erc20.encodeApprove` consistently with `Erc20.encodeTransfer`. -/
def encodeApprove (spender : String) (amount : Nat) : String :=
  LeanKohaku.Swap.UniV3.encodeApprove spender amount

/-- The `2^256 - 1` allowance sentinel used by the `approve unlimited`
UX. Re-exported here so the trusted-path Intent → encoder dispatch
doesn't need to import `Swap.UniV3` directly. -/
def maxUint256 : Nat := LeanKohaku.Swap.UniV3.maxUint256

end LeanKohaku.Ethereum.Erc20
