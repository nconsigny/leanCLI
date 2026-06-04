import LeanCli.Registry.KnownProtocols
import LeanCli.Swap.Tokens
import LeanCli.Swap.UniV3

/-!
# Aave V3 Pool ABI encoders

Pure Lean encoders for the small Aave surface the wallet exposes via the
`aaveV3Supply` / `aaveV3Withdraw` Intent variants. The Pool's deployed
address per chain is owned by `Registry.KnownProtocols`; this module is
strictly calldata encoding.

## Function selectors (precomputed from `keccak256(signature)[:4]`)

* `supply(address,uint256,address,uint16)`                = `0x617ba037`
* `withdraw(address,uint256,address)`                     = `0x69328dec`
* `borrow(address,uint256,uint256,uint16,address)`        = `0xa415bcad`
* `repay(address,uint256,uint256,address)`                = `0x573ade81`
* `setUserUseReserveAsCollateral(address,bool)`           = `0x5a3b74b9`

Verify with `cast sig 'supply(address,uint256,address,uint16)'` if
porting to a new ABI.

## Why a separate module, not adding to `Swap.UniV3`

Aave's Pool is not a swap router. Co-locating its selectors there would
muddy the file's role. The `padLeft32` / `encodeAddress` / `encodeUint256`
primitives are reused via `Swap.UniV3` so we don't introduce parallel
encoders.

## Approval pre-step

`supply` requires `transferFrom`-style allowance to the Pool. The chat
path emits a separate `erc20Approve` Intent first (the user confirms it
in the same ConfirmGate flow). This encoder does NOT chain in an
approval — it returns the bare `supply` calldata. Multi-step composition
is the caller's responsibility.

## ETH (vs WETH) supply

Aave V3 mainnet routes ETH supply through the `WrappedTokenGatewayV3`
contract, not the Pool directly. That helper is a separate deployment
and is not yet in the registry. For ETH the user must explicitly wrap
to WETH first and then supply WETH; this encoder works against any
ERC-20 asset (including WETH).
-/

namespace LeanCli.Aave.V3Pool

open LeanCli.Swap.UniV3 (encodeAddress encodeUint256)

def selSupply        : String := "617ba037"
def selWithdraw      : String := "69328dec"
def selBorrow        : String := "a415bcad"
def selRepay         : String := "573ade81"
def selSetCollateral : String := "5a3b74b9"

/-- Aave V3 interest-rate modes. The Pool encodes these as `uint256` but
    only `Stable` (1) and `Variable` (2) are accepted; `None` (0) is
    documented but reverts at the Pool. We default to `Variable` for
    fresh borrows and accept either for repay. -/
inductive InterestRateMode where
  | stable
  | variable
  deriving DecidableEq, Repr

def InterestRateMode.toNat : InterestRateMode → Nat
  | .stable   => 1
  | .variable => 2

/-- Parse `"stable"` / `"variable"` (case-insensitive) into `InterestRateMode`,
    rejecting anything else so the daemon surfaces a stable error code rather
    than silently coercing. -/
def InterestRateMode.parse? (s : String) : Option InterestRateMode :=
  match s.toLower with
  | "stable"   => some .stable
  | "variable" => some .variable
  | "1"        => some .stable
  | "2"        => some .variable
  | _          => none

/-- `supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)`.
    Referral code defaults to 0 (no referral program). -/
def encodeSupply (asset : String) (amount : Nat) (onBehalfOf : String)
    (referralCode : Nat := 0) : String :=
  "0x" ++ selSupply
    ++ encodeAddress asset
    ++ encodeUint256 amount
    ++ encodeAddress onBehalfOf
    ++ encodeUint256 referralCode

/-- `withdraw(address asset, uint256 amount, address to) returns (uint256)`.
    Pass `amount = 2^256 - 1` to withdraw the user's full aToken balance —
    that's the Pool's documented convention. -/
def encodeWithdraw (asset : String) (amount : Nat) (recipient : String) : String :=
  "0x" ++ selWithdraw
    ++ encodeAddress asset
    ++ encodeUint256 amount
    ++ encodeAddress recipient

/-- `borrow(address asset, uint256 amount, uint256 interestRateMode,
    uint16 referralCode, address onBehalfOf)`. The Pool reverts unless the
    borrower (msg.sender, or the credit-delegate of `onBehalfOf`) has
    sufficient health-factor headroom — the daemon's `tx.simulate` step
    catches that before signing. `referralCode` defaults to 0. -/
def encodeBorrow (asset : String) (amount : Nat) (rateMode : InterestRateMode)
    (onBehalfOf : String) (referralCode : Nat := 0) : String :=
  "0x" ++ selBorrow
    ++ encodeAddress asset
    ++ encodeUint256 amount
    ++ encodeUint256 rateMode.toNat
    ++ encodeUint256 referralCode
    ++ encodeAddress onBehalfOf

/-- `repay(address asset, uint256 amount, uint256 interestRateMode,
    address onBehalfOf) returns (uint256)`. Pass `amount = 2^256 - 1` to
    repay the full debt of `onBehalfOf` for the given rate mode. -/
def encodeRepay (asset : String) (amount : Nat) (rateMode : InterestRateMode)
    (onBehalfOf : String) : String :=
  "0x" ++ selRepay
    ++ encodeAddress asset
    ++ encodeUint256 amount
    ++ encodeUint256 rateMode.toNat
    ++ encodeAddress onBehalfOf

/-- `setUserUseReserveAsCollateral(address asset, bool useAsCollateral)`.
    Pure flag operation — no token transfer, no approval required. -/
def encodeSetUserUseReserveAsCollateral
    (asset : String) (useAsCollateral : Bool) : String :=
  "0x" ++ selSetCollateral
    ++ encodeAddress asset
    ++ encodeUint256 (if useAsCollateral then 1 else 0)

/-- Resolve the Pool address for a given EIP-155 chain id, or `none` if
    we don't know a canonical Aave V3 Pool deployment on that chain. -/
def poolForChainId (chainId : Nat) : Option String :=
  match chainId with
  | 1        => some LeanCli.Registry.KnownProtocols.aaveV3PoolMainnet
  | 11155111 => some LeanCli.Registry.KnownProtocols.aaveV3PoolSepolia
  | _        => none

end LeanCli.Aave.V3Pool
