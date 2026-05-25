import LeanKohaku.Swap.Tokens

/-!
# Trusted token registry + base-unit conversions

The agent's view of ERC-20 token metadata: symbol, name, chainId,
address, decimals. The actual token list is owned by
`LeanKohaku.Swap.Tokens.registry` — the same list the wallet's SWAP
tab uses — and this module is the agent-facing facade.

## Why this exists

The agent loop's LLM was previously deciding that "USDC has 6
decimals" and "USDC on mainnet is 0xA0b8…eB48" from its training
data. That is unsafe: a hallucinated address goes straight into
calldata, and an off-by-one in decimals can mis-size a transfer by
10x. After this module, the agent must call `token_lookup` (see
`LeanKohaku.Agent.ToolDefs.Tokens`) to obtain those fields, and the
answer is a pure Lean fact reviewed in `LeanKohaku.Swap.Tokens`.
The Lake build is the audit trail.

## Trust contract

* Every entry derives from `Swap.Tokens.registry`, which the wallet
  daemon's swap path also uses. The agent's `token_lookup` and the
  TUI's swap tab cannot disagree about an address.
* Addresses are stored lowercase 0x-prefixed in the source (EVM is
  case-insensitive at protocol level; EIP-55 mixed case is purely a
  display checksum). `addressEq` lowercases on both sides so callers
  matching against EIP-55 input still succeed.
* Sepolia entries with `addressSepolia := none` in the upstream
  registry produce no agent entry on chainId 11155111 — `token_lookup`
  correctly returns `unknown_token` and the agent asks the user.
  Adding a token here means adding it in `Swap/Tokens.lean`.
* This module is pure (no IO). A future ERC-7730 augmentation path
  may supply additional metadata at runtime, but if a hardcoded entry
  and an ERC-7730 entry disagree on `address` or `decimals`, the
  hardcoded entry wins. The sidecar can decorate (e.g. richer
  `name`) but never override the swap registry's address or decimals.

## Conversions

* `toBaseUnits` parses a decimal string with at most `decimals`
  fractional digits into an integer base-units decimal string.
* `humanUnits` is the inverse: integer base units → decimal string
  padded to exactly `decimals` fractional digits.

Integer-only, no floats, no Mathlib. Errors are short and
actionable.
-/

namespace LeanKohaku.Ethereum.TokenRegistry

/-- A single token entry. `address` is EIP-55-checksummed; callers
    that compare must lowercase or otherwise normalize on both sides
    (see `addressEq`). `source` is `"hardcoded"` for entries in this
    module and `"erc7730"` for entries supplied by an ERC-7730
    descriptor (augmentation path is currently deferred). -/
structure TokenInfo where
  symbol   : String
  name     : String
  chainId  : Nat
  address  : String
  decimals : Nat
  source   : String
  deriving Repr

/-- Convert one upstream `Swap.Tokens.Token` into per-chain
    `TokenInfo` entries — one for mainnet (always present) plus one
    for Sepolia when the upstream record has `addressSepolia := some
    _`. Anything else stays a miss so the agent asks the user
    instead of guessing. -/
private def fromSwapToken (t : Swap.Tokens.Token) : List TokenInfo :=
  let mainnet : TokenInfo := {
    symbol   := t.symbol,
    name     := t.name,
    chainId  := 1,
    address  := t.addressMainnet,
    decimals := t.decimals,
    source   := "hardcoded"
  }
  match t.addressSepolia with
  | some addr =>
      [ mainnet,
        { symbol   := t.symbol,
          name     := t.name,
          chainId  := 11155111,
          address  := addr,
          decimals := t.decimals,
          source   := "hardcoded" } ]
  | none => [mainnet]

/-- The hand-audited token list, derived from
    `LeanKohaku.Swap.Tokens.registry`. The wallet daemon's swap
    surface and the agent's `token_lookup` share one source of truth,
    so neither can drift relative to the other. To add a token here,
    edit `Swap/Tokens.lean`.

    Current Sepolia coverage (from upstream): WETH, BOLD, UNI, wstETH,
    USDC. Other symbols (USDT, DAI, MORPHO, AAVE, …) are mainnet-only
    in the upstream registry and `token_lookup` correctly answers
    `unknown_token` on Sepolia. -/
def knownTokens : List TokenInfo :=
  Swap.Tokens.registry.flatMap fromSwapToken

/-- ASCII lowercase fold. We deliberately only fold ASCII because every
    symbol and every hex address is ASCII; using `Char.toLower` here
    would risk Unicode normalization differences. -/
private def asciiLower (s : String) : String :=
  String.ofList <| s.toList.map fun c =>
    if 'A' ≤ c ∧ c ≤ 'Z' then Char.ofNat (c.toNat + 32) else c

/-- Case-insensitive symbol equality. -/
private def symbolEq (a b : String) : Bool :=
  asciiLower a == asciiLower b

/-- Strip an optional `0x` / `0X` prefix. -/
private def stripHex (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then (s.drop 2).toString else s

/-- Case-insensitive 0x-prefix-tolerant address equality. EIP-55
    checksumming uses mixed case to encode a checksum but the
    underlying address is case-insensitive at the protocol level, so
    this is the correct equality for lookup. Callers that need to
    *render* an address should always use the stored checksummed
    form. -/
private def addressEq (a b : String) : Bool :=
  asciiLower (stripHex a) == asciiLower (stripHex b)

/-- Lookup by symbol on a given chain. Case-insensitive on `symbol`.
    Returns the first match in `knownTokens` order. -/
def lookupBySymbol (chainId : Nat) (symbol : String) : Option TokenInfo :=
  knownTokens.find? fun t => t.chainId = chainId ∧ symbolEq t.symbol symbol

/-- Lookup by address on a given chain. Tolerates a missing `0x`
    prefix and any case. Returns the first match in `knownTokens`
    order. -/
def lookupByAddress (chainId : Nat) (address : String) : Option TokenInfo :=
  knownTokens.find? fun t => t.chainId = chainId ∧ addressEq t.address address

/-! ## Base-unit conversion (integer math only) -/

/-- Repeat a character `n` times, list-style. Used for zero-padding
    `humanUnits` output. -/
private def repeatChar (c : Char) : Nat → String
  | 0     => ""
  | n + 1 => String.ofList [c] ++ repeatChar c n

/-- Parse a sequence of ASCII decimal digits into a `Nat`. Rejects an
    empty input and any non-`0-9` character. Used by both `toBaseUnits`
    (integer + optional fractional part) and `humanUnits` (single
    integer string). -/
private def parseDigits (s : String) : Except String Nat := do
  if s.isEmpty then .error "empty number"
  let mut acc : Nat := 0
  for c in s.toList do
    if '0' ≤ c ∧ c ≤ '9' then
      acc := acc * 10 + (c.toNat - '0'.toNat)
    else
      .error s!"unexpected character '{c}' (only ASCII digits allowed)"
  .ok acc

/-- `10 ^ n`. Total, integer-only. -/
private def pow10 : Nat → Nat
  | 0     => 1
  | n + 1 => 10 * pow10 n

/-- Convert a decimal-string amount (`"13"`, `"13.5"`, `"0.000001"`)
    to its base-units integer representation as a decimal string.

    Rules enforced:
    * No leading sign. Use `"0"` for zero.
    * At most one decimal point.
    * The fractional part must not exceed `decimals` digits — caller
      gets a clear error rather than silent rounding.
    * No scientific notation (`"13e6"` is rejected).
    * Only ASCII digits and at most one `.`.

    Returns the result as a string (not `Nat`) so callers can pipe it
    straight into a uint256 ABI encoder without losing precision past
    `2^64`. -/
def toBaseUnits (amount : String) (decimals : Nat) : Except String String := do
  if amount.isEmpty then .error "amount is empty"
  if amount.startsWith "-" then .error "amount must not be negative"
  if amount.startsWith "+" then .error "amount must not have a leading sign"
  -- Reject scientific notation up front for a clearer error than
  -- `parseDigits` would produce.
  if amount.contains 'e' ∨ amount.contains 'E' then
    .error "amount must not use scientific notation (e/E)"
  -- Split on the first '.' (caller may pass no decimal at all).
  let parts := amount.splitOn "."
  match parts with
  | [whole] =>
      let w ← parseDigits whole
      .ok (toString (w * pow10 decimals))
  | [whole, frac] =>
      let wholePart := if whole.isEmpty then "0" else whole
      let w ← parseDigits wholePart
      if frac.isEmpty then
        .error "amount has a trailing decimal point but no fractional digits"
      else if frac.length > decimals then
        .error s!"amount has {frac.length} fractional digits but token only has {decimals} decimals"
      else
        let f ← parseDigits frac
        -- Scale the fractional digits up to `decimals` width.
        let scale := pow10 (decimals - frac.length)
        .ok (toString (w * pow10 decimals + f * scale))
  | _ => .error "amount has more than one decimal point"

/-- Convert a base-units decimal string back to a human-readable
    decimal string with exactly `decimals` fractional digits.

    `humanUnits "13000000" 6 = .ok "13.000000"`
    `humanUnits "500000"   6 = .ok "0.500000"`
    `humanUnits "0"        6 = .ok "0.000000"`

    The fractional part is always padded to `decimals` digits so the
    output is unambiguous for display. Rejects non-digit input and
    leading signs. -/
def humanUnits (baseUnits : String) (decimals : Nat) : Except String String := do
  if baseUnits.isEmpty then .error "baseUnits is empty"
  if baseUnits.startsWith "-" then .error "baseUnits must not be negative"
  if baseUnits.startsWith "+" then .error "baseUnits must not have a leading sign"
  let n ← parseDigits baseUnits
  if decimals = 0 then
    .ok (toString n)
  else
    let divisor := pow10 decimals
    let whole := n / divisor
    let frac  := n % divisor
    -- Render frac as a fixed-width `decimals`-digit string, zero-padded
    -- on the left.
    let fracStr := toString frac
    let padN := decimals - fracStr.length
    let padded := repeatChar '0' padN ++ fracStr
    .ok (toString whole ++ "." ++ padded)

end LeanKohaku.Ethereum.TokenRegistry
