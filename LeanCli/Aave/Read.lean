import LeanCli.Aave.V3Pool
import LeanCli.Swap.UniV3

/-!
# Aave V3 read-only position query

Pure encoders + decoders for the Aave V3 read surface used by the wallet:

* `Pool.getUserAccountData(address)` for health factor and Aave's oracle-priced
  base-currency aggregate.
* `Pool.getReserveData(asset)` + `balanceOf(user)` on the aToken /
  variableDebtToken for token-denominated supplied / borrowed rows.

This is a *read* surface: no calldata is produced, nothing is signed, so it
does not touch the `decodeIntent → simulate → ConfirmGate` pipeline. It only
informs display.

`getUserAccountData` returns aggregate collateral / debt / borrowing power /
health factor in the market's base currency. The per-reserve token rows avoid
the heavier `UiPoolDataProvider.getUserReservesData` dynamic ABI by probing the
small curated reserve list and reading aToken / variable debt balances.

## Selector

`getUserAccountData(address)` = `keccak256(sig)[:4]` = `0xbf92857c`
(verify with `cast sig 'getUserAccountData(address)'`).

## Return layout (6 × 32-byte words, all `uint256`)

| word | byte off | field                       | scale            |
|------|----------|-----------------------------|------------------|
| 0    | 0        | totalCollateralBase         | base ccy (1e8)   |
| 1    | 32       | totalDebtBase               | base ccy (1e8)   |
| 2    | 64       | availableBorrowsBase        | base ccy (1e8)   |
| 3    | 96       | currentLiquidationThreshold | bps (1e4)        |
| 4    | 128      | ltv                         | bps (1e4)        |
| 5    | 160      | healthFactor                | 1e18; uint max if no debt |

Aave V3's base currency is USD with 8 decimals (`MARKET_REFERENCE_CURRENCY`),
so collateral/debt USD = value / 1e8. When `totalDebtBase = 0` the Pool
returns `type(uint256).max` for `healthFactor` ("∞ / no liquidation risk").
-/

namespace LeanCli.Aave.Read

open LeanCli.Swap.UniV3 (encodeAddress decodeWordAt)

/-- Aave V3 Pool `getUserAccountData(address)` selector. -/
def selGetUserAccountData : String := "bf92857c"

/-- Number of decimals in Aave V3's base reference currency (USD ⇒ 1e8). -/
def baseCurrencyDecimals : Nat := 8

/-- ABI-encode `getUserAccountData(address user)` calldata. -/
def encodeGetUserAccountData (user : String) : String :=
  "0x" ++ selGetUserAccountData ++ encodeAddress user

/-- Aave V3 Pool `getReserveData(address)` selector. -/
def selGetReserveData : String := "35ea6a75"

/-- ERC-20 `balanceOf(address)` selector. -/
def selBalanceOf : String := "70a08231"

/-- ABI-encode `getReserveData(address asset)` calldata. -/
def encodeGetReserveData (asset : String) : String :=
  "0x" ++ selGetReserveData ++ encodeAddress asset

/-- ABI-encode `balanceOf(address user)` calldata. -/
def encodeBalanceOf (user : String) : String :=
  "0x" ++ selBalanceOf ++ encodeAddress user

/-- Aave V3 Pool `getReservesList()` selector. -/
def selGetReservesList : String := "d1946dbc"

/-- ABI-encode the no-arg `getReservesList()` calldata. -/
def encodeGetReservesList : String := "0x" ++ selGetReservesList

private def stripHex (s : String) : String :=
  let l := s.toLower
  if l.startsWith "0x" then (l.drop 2).toString else l

private def decodeAddressWordAt (hex : String) (wordIndex : Nat) :
    Option String :=
  let body := stripHex hex
  let start := wordIndex * 64
  if body.length < start + 64 then none
  else
    let word := ((body.drop start).take 64).toString
    some ("0x" ++ (word.drop 24).toString)

private def zeroAddress : String :=
  "0x0000000000000000000000000000000000000000"

private def isZeroAddress (addr : String) : Bool :=
  addr.toLower == zeroAddress

/-- Decoded aggregate position from `getUserAccountData`. All amounts are the
    raw on-chain `uint256` values; scaling (base-ccy 1e8, bps 1e4, HF 1e18) is
    left to the display layer so no precision is lost crossing the JSON wire. -/
structure UserAccountData where
  totalCollateralBase : Nat
  totalDebtBase : Nat
  availableBorrowsBase : Nat
  currentLiquidationThreshold : Nat
  ltv : Nat
  healthFactor : Nat
  deriving Repr

/-- Decode the 6-word return data of `getUserAccountData`. Returns `none` if the
    buffer is short a word (malformed / wrong contract). -/
def decodeUserAccountData (hex : String) : Option UserAccountData := do
  let c ← decodeWordAt hex 0
  let d ← decodeWordAt hex 32
  let a ← decodeWordAt hex 64
  let lt ← decodeWordAt hex 96
  let ltv ← decodeWordAt hex 128
  let hf ← decodeWordAt hex 160
  pure {
    totalCollateralBase := c
    totalDebtBase := d
    availableBorrowsBase := a
    currentLiquidationThreshold := lt
    ltv := ltv
    healthFactor := hf }

/-- A user "has a position" iff they hold collateral or owe debt. A fresh
    address returns all-zero base values (and `healthFactor = uint max`), which
    the display layer renders as "no Aave position" rather than HF ∞. -/
def UserAccountData.hasPosition (u : UserAccountData) : Bool :=
  u.totalCollateralBase > 0 || u.totalDebtBase > 0

/-- Token contracts associated with an Aave reserve. `aTokenAddress` holds
    supplied principal+interest; `variableDebtTokenAddress` holds current
    variable debt. Stable debt is intentionally omitted because V3 stable-rate
    borrowing is disabled in this wallet surface. -/
structure ReserveTokenAddresses where
  aTokenAddress : String
  variableDebtTokenAddress : String
  deriving Repr

/-- Decode the token-address portion of `getReserveData(asset)`.
    Aave V3 returns these as words 8 (aToken), 9 (stable debt), 10
    (variable debt). Returns `none` when the reserve is unsupported or the
    buffer is malformed. -/
def decodeReserveTokenAddresses (hex : String) : Option ReserveTokenAddresses := do
  let aToken ← decodeAddressWordAt hex 8
  let variableDebt ← decodeAddressWordAt hex 10
  if isZeroAddress aToken then none
  else
    pure { aTokenAddress := aToken, variableDebtTokenAddress := variableDebt }

/-- Decode an ABI `address[]` return value (one dynamic array). Reads the head
    offset word, the element count at that offset, then each element's low-20
    bytes. The count is capped at 1024 to bound work on a garbled buffer.
    Returns `none` on a short/malformed buffer. -/
def decodeAddressArray (hex : String) : Option (List String) := do
  let offBytes ← decodeWordAt hex 0
  let lenWordIdx := offBytes / 32
  let len ← decodeWordAt hex offBytes
  if len > 1024 then none
  else (List.range len).mapM (fun j => decodeAddressWordAt hex (lenWordIdx + 1 + j))

end LeanCli.Aave.Read
