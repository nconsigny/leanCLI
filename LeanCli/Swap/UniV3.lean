import LeanCli.Crypto.Hex
import LeanCli.Swap.Tokens

/-!
# Uniswap V3 ABI encoders

Pure ABI encoders for the small surface this wallet needs:

* QuoterV2.quoteExactInputSingle (read-only, eth_call)
* SwapRouter02.exactInputSingle  (write, no deadline)
* SwapRouter02.multicall(bytes[]) — used to wrap ETH→token swaps with refundETH
* ERC20 allowance / approve

All function selectors are precomputed (keccak256(signature)[0..4]) and
hardcoded as 8-char hex strings. The signatures are documented next to
each constant; recompute by hand or via `cast sig <signature>` when
extending.
-/

namespace LeanCli.Swap.UniV3

open LeanCli.Crypto

/-! ## Deployment addresses (lowercase 0x-prefixed) -/

def quoterV2Mainnet : String := "0x61ffe014ba17989e743c5f6cb21bf9697530b21e"
def quoterV2Sepolia : String := "0xed1f6473345f45b75f8179591dd5ba1888cf2fb3"
def swapRouter02Mainnet : String := "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45"
def swapRouter02Sepolia : String := "0x3bfa4769fb09eefc5a80d6e87c3b9c650f7ae48e"

def quoterFor : LeanCli.Swap.Tokens.ChainId → String
  | .mainnet => quoterV2Mainnet
  | .sepolia => quoterV2Sepolia

def routerFor : LeanCli.Swap.Tokens.ChainId → String
  | .mainnet => swapRouter02Mainnet
  | .sepolia => swapRouter02Sepolia

def factoryMainnet : String := "0x1f98431c8ad98523631ae4a59f267346ea31f984"
def factorySepolia : String := "0x0227628f3f023bb0b980b67d528571c95c6dac1c"

/-- Canonical Uniswap V3 factory per chain (Uniswap deployment docs). -/
def factoryFor : LeanCli.Swap.Tokens.ChainId → String
  | .mainnet => factoryMainnet
  | .sepolia => factorySepolia

/-! ## Selectors

  - quoteExactInputSingle((address,address,uint256,uint24,uint160))
      = 0xc6a5026a   [QuoterV2]
  - exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))
      = 0x04e45aaf   [SwapRouter02 — no deadline]
  - multicall(bytes[])                = 0xac9650d8
  - refundETH()                       = 0x12210e8a
  - unwrapWETH9(uint256,address)      = 0x49404b7c   [PeripheryPayments]
  - allowance(address,address)        = 0xdd62ed3e
  - approve(address,uint256)          = 0x095ea7b3
-/

def selQuoteExactInputSingle : String := "c6a5026a"
def selExactInputSingle      : String := "04e45aaf"
def selMulticall             : String := "ac9650d8"
def selRefundETH             : String := "12210e8a"
def selUnwrapWETH9           : String := "49404b7c"
def selAllowance             : String := "dd62ed3e"
def selApprove               : String := "095ea7b3"

/-- Router-side sentinel for `recipient`. SwapRouter02 rewrites
    `recipient == address(2)` to `address(this)` inside `exactInputInternal`
    (see `Constants.ADDRESS_THIS`), keeping the output token in the router
    so a chained `unwrapWETH9` can convert it to native ETH. Plain
    `address(0)` is NOT a substitute — it would forward to the pool's
    callback recipient and revert. -/
def addressThis : String := "0x0000000000000000000000000000000000000002"

/-! ## Hex string helpers (work on the body, no `0x` prefix). -/

private def lower (s : String) : String := s.toLower

private def stripHex (s : String) : String :=
  let l := lower s
  if l.startsWith "0x" then (l.drop 2).toString else l

/-- Pad a hex *body* (no 0x prefix) on the left with zeros to 64 nibbles. -/
def padLeft32 (hexBody : String) : String :=
  let body := stripHex hexBody
  let n := body.length
  if n ≥ 64 then (body.drop (n - 64)).toString
  else String.ofList (List.replicate (64 - n) '0') ++ body

/-- Encode a 0x-prefixed (or unprefixed) address as a 32-byte word body. -/
def encodeAddress (addr : String) : String :=
  padLeft32 (stripHex addr)

/-- Encode a `Nat` to a 32-byte unsigned big-endian word body. -/
def encodeUint256 (n : Nat) : String :=
  let rec toHex (k : Nat) (acc : String) (fuel : Nat) : String :=
    match fuel with
    | 0 => acc
    | fuel + 1 =>
        if k = 0 then acc
        else
          let d := k % 16
          let c := Hex.nibbleToChar (UInt8.ofNat d)
          toHex (k / 16) (String.ofList [c] ++ acc) fuel
  let body := if n = 0 then "0" else toHex n "" 256
  padLeft32 body

/-- Encode `uint24` (fee tier) — same width as uint256 in calldata. -/
def encodeUint24 (n : Nat) : String := encodeUint256 n
/-- Encode `uint160` — same width as uint256 in calldata. -/
def encodeUint160 (n : Nat) : String := encodeUint256 n

/-- Encode a single dynamic `bytes` value (length-prefixed, padded to a
    32-byte boundary). Returns the body (no 0x). -/
def encodeBytes (hexBody : String) : String :=
  let body := stripHex hexBody
  -- byte length = nibbles / 2
  let lenBytes := body.length / 2
  let lenWord := encodeUint256 lenBytes
  -- pad to multiple of 64 nibbles
  let pad := (64 - body.length % 64) % 64
  let padded := body ++ String.ofList (List.replicate pad '0')
  lenWord ++ padded

/-- Encode `bytes[]` (a head-pointer table followed by concatenated
    elements). Returns the body (no 0x). -/
def encodeBytesArray (elems : List String) : String :=
  let n := elems.length
  let lenWord := encodeUint256 n
  -- Each element body is `len(32) ++ data padded to 32`. Compute heads
  -- as offsets into the elements section relative to AFTER `lenWord`'s
  -- "array length" — i.e. heads region starts at position 0 in the
  -- inner array region.
  let bodies : List String := elems.map encodeBytes
  -- heads offsets: first element's head = 32*n (skip the head section).
  -- subsequent heads add the byte-size of preceding bodies.
  let headsRev : List String × Nat :=
    bodies.foldl (init := ([], n * 32))
      (fun (acc : List String × Nat) body =>
        let (heads, off) := acc
        (encodeUint256 off :: heads, off + body.length / 2))
  let heads := headsRev.fst.reverse
  lenWord ++ String.intercalate "" heads ++ String.intercalate "" bodies

/-! ## High-level encoders. Each returns a `0x`-prefixed hex string. -/

structure QuoteExactInputSingleParams where
  tokenIn : String
  tokenOut : String
  amountIn : Nat
  fee : Nat
  sqrtPriceLimitX96 : Nat := 0

def encodeQuoteExactInputSingle (p : QuoteExactInputSingleParams) : String :=
  "0x" ++ selQuoteExactInputSingle ++
    encodeAddress p.tokenIn ++
    encodeAddress p.tokenOut ++
    encodeUint256 p.amountIn ++
    encodeUint24 p.fee ++
    encodeUint160 p.sqrtPriceLimitX96

/-- `getPool(address,address,uint24)` calldata (selector `0x1698ee82`,
    verified with `cast sig`). A plain mapping read on the factory — never
    reverts; returns the pool address, or the zero address when no pool
    exists for pair+fee. Used as a cheap existence probe before quoting:
    `quoteExactInputSingle` against a nonexistent pool REVERTS, and a
    reverting read pays a full EVM execution on the verified backend. -/
def encodeGetPool (tokenA tokenB : String) (fee : Nat) : String :=
  "0x1698ee82" ++ encodeAddress tokenA ++ encodeAddress tokenB ++ encodeUint256 fee

structure ExactInputSingleParams where
  tokenIn : String
  tokenOut : String
  fee : Nat
  recipient : String
  amountIn : Nat
  amountOutMinimum : Nat
  sqrtPriceLimitX96 : Nat := 0

def encodeExactInputSingle (p : ExactInputSingleParams) : String :=
  "0x" ++ selExactInputSingle ++
    encodeAddress p.tokenIn ++
    encodeAddress p.tokenOut ++
    encodeUint24 p.fee ++
    encodeAddress p.recipient ++
    encodeUint256 p.amountIn ++
    encodeUint256 p.amountOutMinimum ++
    encodeUint160 p.sqrtPriceLimitX96

/-- `refundETH()` — selector with no args. -/
def encodeRefundETH : String := "0x" ++ selRefundETH

/-- `unwrapWETH9(uint256 amountMinimum, address recipient)`. Called as the
    second leg of an ERC20→ETH multicall: the first leg leaves WETH in
    the router (recipient = `addressThis`), and this call unwraps and
    forwards the resulting ETH to `recipient`. The router reverts if its
    WETH balance is below `amountMinimum`, which is how the slippage
    floor is enforced on the unwrap path. -/
def encodeUnwrapWETH9 (amountMinimum : Nat) (recipient : String) : String :=
  "0x" ++ selUnwrapWETH9 ++ encodeUint256 amountMinimum ++ encodeAddress recipient

/-- `multicall(bytes[])` wrapping the provided `0x`-prefixed call payloads.

    A function with a single dynamic parameter encodes as
    `selector ++ offset(0x20) ++ <param body>`. Forgetting the leading
    `0x20` makes the router read `array_length` as the offset and silently
    revert. -/
def encodeMulticall (calls : List String) : String :=
  let bodies := calls.map (fun c => stripHex c)
  let offsetWord := encodeUint256 32
  "0x" ++ selMulticall ++ offsetWord ++ encodeBytesArray bodies

/-- `allowance(address owner,address spender)`. -/
def encodeAllowance (owner spender : String) : String :=
  "0x" ++ selAllowance ++ encodeAddress owner ++ encodeAddress spender

/-- `approve(address spender,uint256 amount)`. -/
def encodeApprove (spender : String) (amount : Nat) : String :=
  "0x" ++ selApprove ++ encodeAddress spender ++ encodeUint256 amount

/-- `2^256 - 1` for max-uint approvals. -/
def maxUint256 : Nat :=
  115792089237316195423570985008687907853269984665640564039457584007913129639935

/-! ## Return-data decoders. -/

/-- Decode a 32-byte big-endian word at byte offset `off` from a
    `0x`-prefixed return-data hex string. -/
def decodeWordAt (hex : String) (off : Nat) : Option Nat :=
  let body := stripHex hex
  let start := off * 2
  if body.length < start + 64 then none
  else
    let chunk := ((body.drop start).take 64).toString
    -- parse hex chunk to Nat
    chunk.toList.foldl
      (init := some 0)
      (fun acc c =>
        match acc, Hex.hexDigit? c with
        | some n, some d => some (n * 16 + d.toNat)
        | _, _ => none)

/-- Pull `amountOut` (the first uint256) from a QuoterV2 return-data hex. -/
def decodeQuoteAmountOut (hex : String) : Option Nat :=
  decodeWordAt hex 0

/-! ## Pair classification + default fee-tier routing

Uniswap V3 has four published fee tiers: 100, 500, 3000, 10000 (units
are 0.01% basis points scaled to a uint24 expressing percent × 10000).
Picking the right tier matters — quoting against the wrong tier
returns a worse price OR no price at all if no pool exists at that
tier.

When the chat path or the trusted UI doesn't have the user explicitly
naming a tier, we pick a reasonable default from the pair's category:

* **stable↔stable** — 100 (0.01%). Stablecoin pairs trade tight; the
  cheapest tier is canonical (USDC/USDT, DAI/USDC).
* **stable↔ETH-like** — 500 (0.05%). The standard for USDC/ETH,
  USDC/WETH, the deepest pool on mainnet.
* **ETH-like↔blue-chip** — 500 (0.05%). e.g. WETH/WBTC, WETH/wstETH;
  these pairs also concentrate at the 500 tier on mainnet.
* **anything else** — 3000 (0.30%). Conservative fallback for exotic
  token pairs (LDO/USDC, MKR/ETH, longtail/longtail).

These are display-only defaults — the encoder still takes an explicit
`fee` argument. A user / agent that wants a non-default tier can
override; the daemon's quoter prepass quotes against the picked tier
and surfaces the price to ConfirmGate before any signature. -/

/-- Classification of a pair for default-fee-tier purposes. -/
inductive PairClass where
  | stableStable
  | stableEthLike
  | ethBlueChip
  | exotic
  deriving Repr, DecidableEq

/-- Stablecoin symbols recognised by the pair-class router. The list
is conservative — only assets that actually trade as 1:1 USD pegs (no
volatile LSTs, no commodity-pegged tokens). Lowercase for the
case-insensitive matcher. -/
def stablecoinSymbols : List String :=
  ["usdc", "usdt", "dai", "lusd", "frax",
   "gho", "usds", "crvusd", "fxusd", "bold", "usdm", "tusd",
   "rusd", "sdai"]

/-- ETH-like symbols — native ETH plus liquid staking tokens that
trade near a 1:1 ETH peg over short windows. -/
def ethLikeSymbols : List String :=
  ["eth", "weth", "steth", "wsteth", "reth", "cbeth"]

/-- Blue-chip non-ETH-non-stable assets. Today: BTC only. -/
def blueChipSymbols : List String :=
  ["wbtc"]

private def memberCI (xs : List String) (s : String) : Bool :=
  xs.any (· == s.toLower)

/-- Classify a Uniswap V3 pair. Order-independent. -/
def classifyPair (a b : String) : PairClass :=
  let isStable := fun s => memberCI stablecoinSymbols s
  let isEthLike := fun s => memberCI ethLikeSymbols s
  let isBlue := fun s => memberCI blueChipSymbols s
  if isStable a ∧ isStable b then .stableStable
  else if (isStable a ∧ isEthLike b) ∨ (isEthLike a ∧ isStable b) then .stableEthLike
  else if (isEthLike a ∧ isBlue b) ∨ (isBlue a ∧ isEthLike b) then .ethBlueChip
  else if (isEthLike a ∧ isEthLike b) then .stableEthLike  -- WETH/wstETH etc. → 500
  else .exotic

/-- Default fee tier for a pair, in Uniswap V3's uint24 representation
(percentage × 10_000). -/
def defaultFeeTier (a b : String) : Nat :=
  match classifyPair a b with
  | .stableStable   => 100
  | .stableEthLike  => 500
  | .ethBlueChip    => 500
  | .exotic         => 3000

/-! ### Build-time anchors for the default-tier matrix

`native_decide` checks pin the canonical pair→tier mapping. Renaming
a stablecoin symbol or accidentally moving a token between buckets
(e.g. WETH out of the ethLike list) breaks the build before the
chat path can quote against the wrong pool. -/

example : defaultFeeTier "USDC" "USDT"   = 100  := by native_decide
example : defaultFeeTier "DAI"  "USDC"   = 100  := by native_decide
example : defaultFeeTier "GHO"  "USDC"   = 100  := by native_decide
example : defaultFeeTier "WETH" "USDC"   = 500  := by native_decide
example : defaultFeeTier "ETH"  "USDC"   = 500  := by native_decide
example : defaultFeeTier "USDC" "WETH"   = 500  := by native_decide  -- order-independent
example : defaultFeeTier "WETH" "WBTC"   = 500  := by native_decide
example : defaultFeeTier "WETH" "wstETH" = 500  := by native_decide
example : defaultFeeTier "wstETH" "WETH" = 500  := by native_decide
example : defaultFeeTier "CRV"  "USDC"   = 3000 := by native_decide
example : defaultFeeTier "UNI"  "AAVE"   = 3000 := by native_decide
example : defaultFeeTier "MORPHO" "WETH" = 3000 := by native_decide

end LeanCli.Swap.UniV3
