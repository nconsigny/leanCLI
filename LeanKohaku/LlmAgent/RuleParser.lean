import LeanKohaku.Ethereum.Intent
import LeanKohaku.Swap.Tokens

/-!
# Rule-based English → `RegexDraft` parser

Pure-Lean tokenizer + template matcher for natural-language transaction
intents. Replaces the regex matcher in `bridge/llm-legacy/src/draft.mjs`.
Lean is a strict win here: no regex ambiguity, total functions, the
parser output IS an ADT, every match arm typechecks.

## Role in the chat path

`RuleParser.parse` runs **first**, before any LLM call. Its output (a
`RegexDraft`) is passed to the LLM as a **seed** — never as ground
truth. The LLM "redoes the job" with the regex hint as starting
context, can confirm, refine, or override.

When the regex hits a clean match (action verb + amount + asset +
recipient resolved), the `RegexDraft` is `confidence := .high`. When
it partially matches (e.g. couldn't resolve a symbol), the seed is
`.medium` with `unresolved` notes. When nothing matched, the seed is
`.rejected` — the LLM still runs.

## What templates are recognized (canonical English forms)

* `send <amount> <asset> to <recipient>`
* `transfer <amount> <asset> to <recipient>`
* `approve <unlimited|<amount>> <asset> for <spender>`
* `swap <amount> <asset> (for|to|into) <asset> [with <N>% slippage]`
* `supply <amount> <asset> (to|on) <protocol>`
* `deposit <amount> <asset> (to|on) <protocol>` (alias for supply)
* `withdraw <amount> <asset> from <protocol>`
* `borrow <amount> <asset> from <protocol>`
* `repay <amount> <asset> to <protocol>`
* `wrap <amount> ETH` → `wrap` action
* `unwrap <amount> WETH` → `unwrap` action

Tokens that aren't in `Swap.Tokens.registry` are passed through as raw
strings in the `asset` field; the LLM/encoder can either reject or use
a user-supplied 0x address.

## Why hand-rolled, not regex

`autoImplicit := false` and total Lean functions push us to a small
recursive-descent style. The "regex" name in the slice plan was a
shorthand; the actual implementation is a tokenizer + template matcher,
~150 LOC. The benefit over a regex pile: every match-arm result is
typed, no string-typing of action names, totality is automatic, and
extending the verb list is one line.
-/

namespace LeanKohaku.LlmAgent.RuleParser

open LeanKohaku.Ethereum.Intent

/-! ## Tokenization -/

/-- Drop commas that sit between two digits (thousand-grouping
inside a numeric run), leaving every other comma intact for the next
pass to replace with a space.

Walks the chars once with a 1-char lookback (`prev`) and a 1-char
lookahead. Pure `Nat` indexing into `chars.length` keeps the fuel
explicit and avoids `partial`. Used by `tokenize` so
`"send 1,500.5 USDC ..."` does not shatter into
`["send", "1", "500.5", ...]`. -/
private def stripNumericCommas (s : String) : String := Id.run do
  let chars := s.toList
  let n := chars.length
  let mut out : String := ""
  let mut prev : Char := ' '
  let mut i : Nat := 0
  while h : i < n do
    let c := chars[i]
    let next : Char :=
      if h2 : i + 1 < n then chars[i + 1] else ' '
    if c == ',' ∧ prev.isDigit ∧ next.isDigit then
      pure ()  -- drop this comma
    else
      out := out.push c
    prev := c
    i := i + 1
  return out

/-- Split on whitespace and strip sentence-ending punctuation.
**Does not** strip `.` — that would shatter decimal amounts (`0.01`
becomes `0 01`). Numeric grouping commas (`1,500.5`) are fused first
so they survive; other commas are replaced with spaces so they act as
clause separators. Lowercases each token so downstream matching is
case-insensitive. -/
def tokenize (s : String) : List String :=
  let collapsed : String := stripNumericCommas s
  let cleaned : String :=
    collapsed.toList.foldr
      (fun c acc =>
        if c == ',' || c == ';' || c == '!' || c == '?' then
          " " ++ acc
        else
          c.toString ++ acc)
      ""
  cleaned.splitOn " "
    |>.filter (fun t => !t.isEmpty)
    |>.map (·.toLower)

/-! ## Atom recognizers -/

/-- Action verbs the parser knows. Order matters when verbs overlap
("deposit" is an alias for "supply"). Returns the canonical action tag
or `none`. -/
def verbToAction : String → Option Action
  | "send"      => some .nativeTransfer  -- refined if asset ≠ ETH
  | "transfer"  => some .nativeTransfer
  | "approve"   => some .erc20Approve
  -- revoke / cancel / remove are routed to erc20Approve so the
  -- revoke-approval skill gets attached. The skill enforces amount = 0.
  | "revoke"    => some .erc20Approve
  | "cancel"    => some .erc20Approve
  | "remove"    => some .erc20Approve
  | "swap"      => some .swap
  | "supply"    => some .aaveSupply
  | "deposit"   => some .aaveSupply
  | "withdraw"  => some .aaveWithdraw
  | "borrow"    => some .aaveBorrow
  | "repay"     => some .aaveRepay
  | "wrap"      => some .wrap
  | "unwrap"    => some .unwrap
  | "bridge"    => some .bridge
  | _           => none

/-- Is this token a decimal number (e.g. "0.5", "100")? Returns the
original (lowercased) string when so, since the regex draft preserves
the user's input shape.

Enforces at most one `.` so `"1.2.3"` is rejected — downstream
consumers (`shiftDecimalRight`, the matchers, `Numeric.toBaseUnits`)
all assume a single decimal point. -/
def isAmount (s : String) : Bool :=
  s.length > 0
  && s.toList.all (fun c => c.isDigit || c == '.')
  && s.toList.any Char.isDigit
  && (s.toList.filter (· == '.')).length ≤ 1

/-- Read a unit suffix multiplier in zero-count form. The tokenizer
already lowercases the input, so we only check the lowercase forms.

* `k` → 3 (×1000)
* `m` → 6 (×1,000,000)
* `b` → 9 (×1,000,000,000)

Returns `none` for any other char. Deliberately conservative — we
don't recognise `g`/`t` because no one writes "swap 1g ETH" and the
risk of misreading a token symbol whose first char happens to be a
multiplier ("MORPHO") is real if we got greedy. -/
private def unitMultiplierZeros : Char → Option Nat
  | 'k' => some 3
  | 'm' => some 6
  | 'b' => some 9
  | _   => none

/-- Shift the decimal point of `s` right by `zeros` positions, dropping
the dot once the fractional part is consumed. Pure string surgery — no
`Nat` math on the value, so a 256-bit amount stays exact.

* `shiftDecimalRight "1.5" 3 = "1500"`
* `shiftDecimalRight "1.5" 6 = "1500000"`
* `shiftDecimalRight "100" 3 = "100000"`
* `shiftDecimalRight "0.0005" 3 = "0.5"`
* `shiftDecimalRight "0.5" 0 = "0.5"` -/
private def shiftDecimalRight (s : String) (zeros : Nat) : String :=
  match s.splitOn "." with
  | [intPart] => intPart ++ String.ofList (List.replicate zeros '0')
  | [intPart, fracPart] =>
      let fracLen := fracPart.length
      if zeros ≥ fracLen then
        let extra := zeros - fracLen
        -- Strip leading zeros from intPart unless intPart is "0".
        let combined := intPart ++ fracPart ++ String.ofList (List.replicate extra '0')
        -- Drop leading zeros except keep at least one char.
        let trimmed := combined.toList.dropWhile (· = '0')
        if trimmed.isEmpty then "0" else String.ofList trimmed
      else
        -- Move the dot right by `zeros` digits within `fracPart`.
        let moved := fracPart.toList.take zeros
        let remaining := fracPart.toList.drop zeros
        let newInt := intPart ++ String.ofList moved
        -- Strip leading zeros from newInt (but keep at least one).
        let newIntL := newInt.toList.dropWhile (· = '0')
        let newIntS := if newIntL.isEmpty then "0" else String.ofList newIntL
        newIntS ++ "." ++ String.ofList remaining
  | _ =>
      -- More than one '.' — not a number, hand back unchanged so the
      -- caller's isAmount check rejects it.
      s

/-- Normalise an amount-like token. Handles the `$` prefix
(`"$100" → "100"`) and the `k`/`m`/`b` suffixes (`"1.5k" → "1500"`,
`"2m" → "2000000"`). Returns the canonical decimal string. Returns
`none` if the token doesn't look like a number even after stripping.

Percent suffix is **not** normalised here — `matchSwap` looks for a
trailing `%` to extract slippage, so we leave that for the matcher.

The unit-suffix character must be at position `s.length - 1`; we don't
recognise `1k5` or other infix forms. -/
def normalizeAmount (s : String) : Option String :=
  if s.isEmpty then none else
    -- Strip leading $.
    let s1 := if s.front = '$' then (s.drop 1).toString else s
    if s1.isEmpty then none else
      -- Inspect the trailing char via the char-list view so we avoid
      -- v4.29.1's deprecated `String.get` and `String.dropRight`
      -- byte-index APIs.
      let chars := s1.toList
      match chars.getLast? with
      | none => none
      | some lastChar =>
          match unitMultiplierZeros lastChar with
          | some zeros =>
              let body := String.ofList chars.dropLast
              if isAmount body then some (shiftDecimalRight body zeros) else none
          | none =>
              if isAmount s1 then some s1 else none

/-- True when the token, after `normalizeAmount`, parses as a decimal
number. Used by matchers to accept the richer amount forms without
each matcher having to re-implement the stripping logic. -/
def isAmountLike (s : String) : Bool :=
  (normalizeAmount s).isSome

/-! ### Build-time anchors for amount normalisation

`native_decide` checks fixing the canonical decimal form so any
regression in `stripNumericCommas` / `normalizeAmount` /
`shiftDecimalRight` breaks `lake build` instead of producing the
wrong wei in production. -/

-- Cashtag stripping.
example : normalizeAmount "$100"    = some "100"     := by native_decide
example : normalizeAmount "$1.5"    = some "1.5"     := by native_decide

-- Unit suffixes — k / m / b.
example : normalizeAmount "1.5k"    = some "1500"    := by native_decide
example : normalizeAmount "2m"      = some "2000000" := by native_decide
example : normalizeAmount "0.5b"    = some "500000000" := by native_decide
example : normalizeAmount "100k"    = some "100000"  := by native_decide
example : normalizeAmount "0.0005k" = some "0.5"     := by native_decide

-- Bare decimals pass through untouched.
example : normalizeAmount "0.5"     = some "0.5"     := by native_decide
example : normalizeAmount "100"     = some "100"     := by native_decide

-- Cashtag + suffix.
example : normalizeAmount "$1.5k"   = some "1500"    := by native_decide

-- Garbage rejected.
example : normalizeAmount ""        = none           := by native_decide
example : normalizeAmount "abc"     = none           := by native_decide
example : normalizeAmount "1.2.3"   = none           := by native_decide

-- Comma-grouped numerals survive tokenisation.
example : tokenize "send 1,500.5 usdc" = ["send", "1500.5", "usdc"] := by native_decide
example : tokenize "have 1,000,000 cake" = ["have", "1000000", "cake"] := by native_decide
-- Non-numeric commas still act as clause separators.
example : tokenize "ok, send 1 usdc" = ["ok", "send", "1", "usdc"] := by native_decide

/-- Is this token an `0x40-hex` address? -/
def isAddress (s : String) : Bool :=
  s.startsWith "0x"
  && s.length == 42
  && (s.drop 2).toString.toList.all (fun c =>
       c.isDigit || ('a' ≤ c && c ≤ 'f'))

/-- Is this token a `.eth` ENS name? (Stored raw — actual resolution
happens daemon-side later.) -/
def isEnsName (s : String) : Bool :=
  s.endsWith ".eth" && s.length > 4

/-- Strip a single leading `$` (cashtag) so `"$USDC"` and `"USDC"` are
treated identically by `isKnownSymbol` and the matchers' asset slots.
Returns the input unchanged when no `$` is present. -/
private def stripCashtag (s : String) : String :=
  if s.startsWith "$" then (s.drop 1).toString else s

/-- Recognize a known token symbol via `Swap.Tokens.findBySymbol`.
Accepts optional `$` cashtag prefix so `"$USDC"` resolves the same as
`"USDC"`. -/
def isKnownSymbol (s : String) : Bool :=
  (LeanKohaku.Swap.Tokens.findBySymbol (stripCashtag s)).isSome

/-- The pseudo-symbol "ETH" treated specially (native value, no token
contract). -/
def isEthLike (s : String) : Bool :=
  s.toLower == "eth"

/-! ## Template matching helpers -/

/-- Find the index of a literal-keyword token in the list. Returns
`-1`-equivalent (`none`) when absent. -/
def indexOfKeyword (toks : List String) (kw : String) : Option Nat :=
  let rec go (xs : List String) (i : Nat) : Option Nat :=
    match xs with
    | []       => none
    | x :: rest => if x == kw then some i else go rest (i + 1)
  go toks 0

/-- Get the token at index `i`, or `none`. -/
def at? (toks : List String) (i : Nat) : Option String :=
  toks[i]?

/-- Single-token version qualifier that disambiguates a protocol name
(e.g. "aave v3", "morpho blue", "liquity v2"). Tokenizer has already
lowercased, so the literal forms are matched exactly. -/
private def isProtocolQualifier : String → Bool
  | "v1" | "v2" | "v3" | "v4" => true  -- "borrow X from aave v3"
  | "blue"                    => true  -- "supply X to morpho blue"
  | "pool" | "pools"          => true  -- "deposit X to privacy pool"
  | "cash"                    => true  -- "withdraw X from tornado cash"
  | "protocol"                => true  -- "supply X to liquity protocol"
  | _                         => false

/-- Read up to two adjacent tokens at `start` as a protocol designator.
The second token is included only when it qualifies the first (see
`isProtocolQualifier`) — so `"to aave"`, `"to aave v3"`, and
`"to morpho blue"` all resolve, but a stray `"to morpho cowswap"` does
not pull in `cowswap`. Returns the joined lowercase string; empty list
when nothing is there. -/
def extractProtocolName (toks : List String) (start : Nat) : Option String :=
  match at? toks start with
  | none => none
  | some head =>
      match at? toks (start + 1) with
      | some next =>
          if isProtocolQualifier next then some s!"{head} {next}"
          else some head
      | none => some head

/-! ## Template matchers — each returns either a populated draft or
`none` (no match). The top-level `parse` tries them in order and picks
the first hit. -/

/-- Extract an optional `from <name>` sender hint. Returns the token
that follows the literal `from` keyword, when present. Used by the
transfer + approve matchers so the user can override the default
wallet inline (`approve 42 USDC for vitalik.eth from leanWallet`).
chat.draft's resolveLocal then maps `<name>` → 0x address via the
EOA store; the TUI uses that address to pre-select the signing
wallet, skipping the picker.

Tolerates "from <name>" appearing anywhere in the token stream; the
next token wins. `from` itself is also used in Aave borrow/withdraw
patterns (see matchProtocolAction), but those parsers run after this
one in the dispatch order so there's no ambiguity for the supported
templates. -/
def extractFromHint (toks : List String) : List (String × String) :=
  match indexOfKeyword toks "from" with
  | none => []
  | some idx =>
      match at? toks (idx + 1) with
      | none => []
      | some name => [("from", name)]

/-- `send/transfer <amount> <asset> to <recipient>`. -/
def matchSendOrTransfer (toks : List String) : Option RegexDraft := do
  -- Token 0 is the verb.
  let verb ← toks.head?
  if verb ≠ "send" ∧ verb ≠ "transfer" then none
  -- Find "to" — the recipient indicator.
  let toIdx ← indexOfKeyword toks "to"
  -- Pieces: tokens 1..toIdx-1 are amount + asset; toIdx+1 is recipient.
  let amountRaw ← at? toks 1
  if ¬ (isAmountLike amountRaw) then none
  let amount := (normalizeAmount amountRaw).getD amountRaw
  let assetRaw ← at? toks 2
  let asset := stripCashtag assetRaw
  let recipient ← at? toks (toIdx + 1)
  let action : Action :=
    if isEthLike asset then .nativeTransfer else .erc20Transfer
  let unresolved : List String :=
    let recOk := isAddress recipient ∨ isEnsName recipient
    let assetOk := isEthLike asset ∨ isKnownSymbol asset ∨ isAddress asset
    (if recOk then [] else [s!"recipient '{recipient}' not parseable as address or ENS"])
    ++ (if assetOk then [] else [s!"asset '{asset}' not in known-tokens registry"])
  let confidence : Confidence :=
    if unresolved.isEmpty then .high else .medium
  some {
    action     := action
    fields     := [("verb", verb), ("amount", amount), ("asset", asset), ("to", recipient)]
                  ++ extractFromHint toks
    unresolved := unresolved
    confidence := confidence
  }

/-- `approve <unlimited|<amount>> <asset> for <spender>`. -/
def matchApprove (toks : List String) : Option RegexDraft := do
  let verb ← toks.head?
  if verb ≠ "approve" then none
  let forIdx ← indexOfKeyword toks "for"
  -- Token 1 is the amount-or-"unlimited".
  let amountTok ← at? toks 1
  let isUnlimited := amountTok == "unlimited" || amountTok == "infinite" || amountTok == "max"
  let amount :=
    if isUnlimited then "unlimited"
    else (normalizeAmount amountTok).getD amountTok
  if ¬ (isUnlimited ∨ isAmountLike amountTok) then none
  let assetRaw ← at? toks 2
  let asset := stripCashtag assetRaw
  let spender ← at? toks (forIdx + 1)
  let assetOk := isKnownSymbol asset ∨ isAddress asset
  let spOk := isAddress spender ∨ isEnsName spender
  let unresolved : List String :=
    (if assetOk then [] else [s!"asset '{asset}' not in known-tokens registry"])
    ++ (if spOk then [] else [s!"spender '{spender}' not parseable as address or ENS"])
  let confidence : Confidence :=
    if unresolved.isEmpty then
      (if isUnlimited then .low else .high)  -- unlimited approve = inherent risk
    else .medium
  some {
    action     := .erc20Approve
    fields     := [
      ("verb", verb), ("amount", amount), ("asset", asset), ("spender", spender),
      ("unlimited", toString isUnlimited)
    ] ++ extractFromHint toks
    unresolved := unresolved
    confidence := confidence
  }

/-- `revoke|cancel|remove [<AMOUNT>] <ASSET> approval[s] for <spender>` —
revoke means "set allowance to 0" by definition; any number the user
includes is meaningless and we discard it. The skill enforces
`amount = 0`. **Loudly warns** when a number was discarded so the
user can spot the discrepancy in the regex block before confirming. -/
def matchRevoke (toks : List String) : Option RegexDraft := do
  let verb ← toks.head?
  if verb ≠ "revoke" ∧ verb ≠ "cancel" ∧ verb ≠ "remove" then none
  let forIdx ← indexOfKeyword toks "for"
  -- Asset is the first token after the verb that isn't a filler word
  -- ("the", "my", "all"), a noise keyword ("approval", "allowance"),
  -- or a pure number (revoke amount is ignored — always zero).
  let isFiller := fun (s : String) =>
    s = "the" || s = "my" || s = "all" || s = "an" || s = "a"
  let assetIdx :=
    (List.range toks.length).find? (fun i =>
      i > 0 && i < forIdx
        && match at? toks i with
           | none => false
           | some t => !(isFiller t)
                       && t ≠ "approval"
                       && t ≠ "approvals"
                       && t ≠ "allowance"
                       -- Skip pure numbers: "revoke 10 USDC" means
                       -- "revoke USDC" — the 10 is a leftover word.
                       -- Use isAmountLike so suffixed forms like
                       -- "1.5k" also get treated as numbers, not
                       -- assets.
                       && !(isAmountLike t))
  -- Detect a discarded numeric amount (e.g. "revoke 10 USDC ..."). We
  -- don't try to parse a value out of it because revoke zeros the
  -- allowance unconditionally — but we MUST surface to the user that
  -- the number they typed was ignored, otherwise the regex display
  -- shows "amount=0" silently and looks like a parse bug.
  let discardedAmount : Option String :=
    (List.range toks.length).findSome? (fun i =>
      if i > 0 && i < forIdx then
        match at? toks i with
        | some t => if isAmountLike t then some t else none
        | none => none
      else none)
  match assetIdx with
  | none => none
  | some i =>
      let asset ← at? toks i
      let spender ← at? toks (forIdx + 1)
      let assetOk := isKnownSymbol asset ∨ isAddress asset
      let spOk := isAddress spender ∨ isEnsName spender
      let amountNote : List String :=
        match discardedAmount with
        | some n => [s!"⚠ ignored '{n}' — revoke ALWAYS sets allowance to 0 regardless of the number you typed. If you meant 'set allowance to {n} {asset}', use 'approve {n} {asset} for {spender}' instead."]
        | none => []
      let unresolved : List String :=
        amountNote
        ++ (if assetOk then [] else [s!"asset '{asset}' not in known-tokens registry"])
        ++ (if spOk then [] else [s!"spender '{spender}' not parseable as address or ENS"])
      some {
        action     := .erc20Approve
        fields     := [
          ("verb", verb), ("amount", "0"), ("asset", asset), ("spender", spender),
          ("revoke", "true")
        ] ++ extractFromHint toks
        unresolved := unresolved
        -- A revoke prompt with a number is ambiguous (did they want
        -- to revoke or to approve a non-zero amount?). Lower confidence
        -- to .medium so the LLM is more likely to ask clarification
        -- instead of rubber-stamping.
        confidence :=
          if discardedAmount.isSome then .medium
          else if unresolved.isEmpty then .high else .medium
      }

/-- `swap <amount> <asset> (for|to|into) <asset> [with <N>% slippage]`. -/
def matchSwap (toks : List String) : Option RegexDraft := do
  let verb ← toks.head?
  if verb ≠ "swap" then none
  -- Find the bridge word: "for" / "to" / "into".
  let bridgeIdx ←
    (indexOfKeyword toks "for")
      <|> (indexOfKeyword toks "to")
      <|> (indexOfKeyword toks "into")
  let amountRaw ← at? toks 1
  if ¬ (isAmountLike amountRaw) then none
  let amount := (normalizeAmount amountRaw).getD amountRaw
  let assetInRaw ← at? toks 2
  let assetIn := stripCashtag assetInRaw
  let assetOutRaw ← at? toks (bridgeIdx + 1)
  let assetOut := stripCashtag assetOutRaw
  -- Optional "with N% slippage"
  let slippage : Option String :=
    (indexOfKeyword toks "with").bind (fun i =>
      (at? toks (i + 1)).filter (fun s => s.endsWith "%"))
  let inOk := isEthLike assetIn ∨ isKnownSymbol assetIn ∨ isAddress assetIn
  let outOk := isEthLike assetOut ∨ isKnownSymbol assetOut ∨ isAddress assetOut
  let unresolved : List String :=
    (if inOk then [] else [s!"tokenIn '{assetIn}' not in known-tokens registry"])
    ++ (if outOk then [] else [s!"tokenOut '{assetOut}' not in known-tokens registry"])
    ++ (if slippage.isSome then [] else ["slippage not specified — encoder will require explicit minOut"])
  let fields : List (String × String) :=
    [("verb", verb), ("amountIn", amount), ("tokenIn", assetIn), ("tokenOut", assetOut)]
    ++ (match slippage with | some s => [("slippage", s)] | none => [])
  let confidence : Confidence :=
    if inOk ∧ outOk ∧ slippage.isSome then .high
    else if inOk ∧ outOk then .medium
    else .low
  some { action := .swap, fields := fields, unresolved := unresolved, confidence := confidence }

/-- Generic protocol-action template: verb + amount + asset + from/to + protocol.

`protocol` is read as up to two adjacent tokens so `"... to aave v3"`
and `"... to morpho blue"` resolve to the joined form, not the bare
first word. `extractProtocolName` only joins a second token when it's a
known version/family qualifier — random suffixes do not get pulled in. -/
def matchProtocolAction (toks : List String) (verb : String) (action : Action)
    (preposition : String) : Option RegexDraft := do
  let v ← toks.head?
  if v ≠ verb then none
  let prepIdx ← indexOfKeyword toks preposition
  let amountRaw ← at? toks 1
  if ¬ (isAmountLike amountRaw) then none
  let amount := (normalizeAmount amountRaw).getD amountRaw
  let assetRaw ← at? toks 2
  let asset := stripCashtag assetRaw
  let protocol ← extractProtocolName toks (prepIdx + 1)
  let assetOk := isEthLike asset ∨ isKnownSymbol asset ∨ isAddress asset
  let unresolved : List String :=
    if assetOk then [] else [s!"asset '{asset}' not in known-tokens registry"]
  let confidence : Confidence :=
    if assetOk then .high else .medium
  some {
    action     := action
    fields     := [("verb", verb), ("amount", amount), ("asset", asset), ("protocol", protocol)]
    unresolved := unresolved
    confidence := confidence
  }

/-- `supply / deposit <amount> <asset> (to|on) <protocol>`. -/
def matchSupply (toks : List String) : Option RegexDraft :=
  (matchProtocolAction toks "supply" .aaveSupply "to")
    <|> (matchProtocolAction toks "supply" .aaveSupply "on")
    <|> (matchProtocolAction toks "deposit" .aaveSupply "to")
    <|> (matchProtocolAction toks "deposit" .aaveSupply "on")

/-- `withdraw / borrow / repay <amount> <asset> from <protocol>`. -/
def matchWithdrawBorrowRepay (toks : List String) : Option RegexDraft :=
  (matchProtocolAction toks "withdraw" .aaveWithdraw "from")
    <|> (matchProtocolAction toks "borrow" .aaveBorrow "from")
    <|> (matchProtocolAction toks "repay" .aaveRepay "to")

/-- Privacy Pools deposit / withdraw atom extractor.

Recognized verb forms:
* Canonical: `shield <amount> <asset>` / `unshield <amount> <asset> [to <recipient>]`
* Aliased shield: `deposit <amount> <asset> ...` when the prompt also
  mentions `privacy` / `pool` / `shielded` / `privately` / `anonymously`
  somewhere. Without the hint, `deposit` belongs to Aave (matchSupply).
* Aliased unshield: `withdraw <amount> <asset> ... [to <recipient>]`
  under the same hint gate (without it, `withdraw` belongs to Aave).

Action is set to `.shieldedDeposit` / `.shieldedWithdraw` (per the
ADT variants added in step 1A) so `DirectSynth.synth` can build an
Intent without going through the LLM when all fields are resolved.
The point of matching the template here is to populate `amount` /
`asset` / `to` so the daemon's `parseUnits` pre-pass injects
`amountBase`. Without this, the model would have to convert
`0.05 ETH → wei` itself — exactly the off-by-zero failure mode the
prompt explicitly forbids.

Limitation: the colloquial "make this anonymous" / "make this private"
forms have no amount/asset adjacent to a fixed verb position, so they
fall through to the chat.draft phrase scan WITHOUT pre-computed
amountBase. That phrasing is uncommon in practice; add a dedicated
matcher if it becomes a real source of conversion bugs.

Because the aliased verbs ("deposit", "withdraw") collide with Aave
templates, this matcher MUST run before `matchSupply` /
`matchWithdrawBorrowRepay` in the `parse` dispatch list. -/
def matchShielded (toks : List String) : Option RegexDraft := do
  let verb ← toks.head?
  -- Protocol disambiguators. The bare `shield` verb is ambiguous
  -- between Privacy Pool and Railgun; we require an explicit
  -- protocol token before firing the Privacy Pool shortcut.
  let hasPrivacyPool : Bool :=
    toks.any (fun t =>
      t = "privacy" ∨ t = "pool" ∨ t = "pools" ∨ t = "0xbow")
  let hasRailgun : Bool := toks.any (fun t => t = "railgun")
  let hasTornado : Bool :=
    toks.any (fun t => t = "tornado" ∨ t = "tornado-cash" ∨ t = "tornadocash")
  -- "private" / "anonymous" as bare adjectives are TOO GENERIC ("my
  -- private wallet", "an anonymous donor") — they would hijack
  -- unrelated prompts. Require the adverb forms or specific Privacy-
  -- Pool nouns.
  let hasPrivacyHint : Bool :=
    hasPrivacyPool ∨ toks.any (fun t =>
      t = "shielded" ∨ t = "privately" ∨ t = "anonymously")
  let isCanonical := verb = "shield" ∨ verb = "unshield"
  let isAliasedShield := verb = "deposit" ∧ hasPrivacyHint
  let isAliasedUnshield := verb = "withdraw" ∧ hasPrivacyHint
  if ¬ (isCanonical ∨ isAliasedShield ∨ isAliasedUnshield) then none
  let canonicalVerb : String :=
    if verb = "unshield" ∨ isAliasedUnshield then "unshield" else "shield"
  let amountRaw ← at? toks 1
  if ¬ (isAmountLike amountRaw) then none
  let amount := (normalizeAmount amountRaw).getD amountRaw
  let assetRaw ← at? toks 2
  let asset := stripCashtag assetRaw
  let assetOk := isEthLike asset ∨ isKnownSymbol asset ∨ isAddress asset
  -- Protocol-disambiguation gates. The canonical `shield`/`unshield`
  -- verb defaulted to Privacy Pool, which silently overrode the user
  -- whenever they named a different protocol (e.g. "shield 0.05 ETH
  -- with railgun"). The chat must ask instead of guessing.
  --
  -- Aliased verbs ("deposit X privately", "withdraw Y from the
  -- privacy pool") inherently imply Privacy Pool and skip these
  -- gates — they only match when hasPrivacyHint is set.
  if isCanonical ∧ hasTornado then
    return {
      action     := .unknown
      fields     := [("verb", canonicalVerb), ("amount", amount), ("asset", asset),
                     ("protocol", "tornado-cash")]
      unresolved := ["Tornado Cash is coming soon. For now use 'Privacy → Privacy Pool' or 'Privacy → Railgun' from the wallet menu."]
      confidence := .rejected
    }
  if isCanonical ∧ hasRailgun then
    return {
      action     := .unknown
      fields     := [("verb", canonicalVerb), ("amount", amount), ("asset", asset),
                     ("protocol", "railgun")]
      unresolved := [s!"Railgun {canonicalVerb} via chat shortcut is coming soon. Use 'Privacy → Railgun' from the wallet menu to {canonicalVerb} via the @kohaku-eth/railgun SDK, or rephrase as '{canonicalVerb} {amount} {asset} with privacy pool' to use the Privacy Pool shortcut."]
      confidence := .rejected
    }
  if isCanonical ∧ ¬ hasPrivacyPool then
    return {
      action     := .unknown
      fields     := [("verb", canonicalVerb), ("amount", amount), ("asset", asset)]
      unresolved := [s!"'{canonicalVerb} {amount} {asset}': which privacy protocol? Add 'with privacy pool' for the 0xbow Privacy Pool shortcut, or 'with railgun' for Railgun (manual flow via Privacy → Railgun menu)."]
      confidence := .rejected
    }
  -- Recipient is only meaningful for unshield; for shield, the
  -- destination IS the Privacy Pool contract (no user-supplied
  -- recipient). For aliased "withdraw X from the privacy pool to
  -- <recipient>", `indexOfKeyword "to"` returns the index of the
  -- recipient "to" (the only "to" in that phrasing). We filter out
  -- noise tokens that might sit after a stray "to" so a misplaced
  -- preposition doesn't fabricate a recipient.
  let isNoiseToken : String → Bool := fun s =>
    s = "the" ∨ s = "pool" ∨ s = "pools" ∨ s = "privacy"
      ∨ s = "shielded" ∨ s = "a" ∨ s = "an"
  let recipient? : Option String :=
    if canonicalVerb = "unshield" then
      (indexOfKeyword toks "to").bind (fun i =>
        (at? toks (i + 1)).filter (fun c => !(isNoiseToken c)))
    else none
  let fields : List (String × String) :=
    [("verb", canonicalVerb), ("amount", amount), ("asset", asset)]
    ++ (match recipient? with
        | some r => [("to", r)]
        | none   => [])
  let unresolved : List String :=
    if assetOk then [] else [s!"asset '{asset}' not recognized for shield/unshield"]
  let action : Action :=
    if canonicalVerb = "unshield" then .shieldedWithdraw else .shieldedDeposit
  some {
    action     := action
    fields     := fields
    unresolved := unresolved
    -- For shield (no recipient field), high confidence when the asset
    -- resolves; for unshield, require both asset AND recipient before
    -- promoting to high (so the synth path has something to chew on).
    confidence :=
      if !assetOk then .medium
      else if canonicalVerb = "shield" then .high
      else
        match recipient? with
        | some _ => .high
        | none   => .medium
  }

/-- `audit [my] approvals [on <chain>]` — read-only listing of outgoing
ERC-20 allowances. No amount, no asset; the daemon scans `Approval`
events from the user's wallet. Optional inline wallet via `for <name>`
or `for <0x...>` — chat.draft's wallet-name resolution substitutes a
0x address before the LLM sees the seed. -/
def matchAuditApprovals (toks : List String) : Option RegexDraft := do
  let verb ← toks.head?
  let isAudit := verb = "audit"
  -- "show approvals" / "list approvals" / "what approvals do i have"
  -- are common enough alternative entry points to recognize them by
  -- the second token instead of forcing the user to start with "audit".
  let isShowList :=
    (verb = "show" ∨ verb = "list" ∨ verb = "what")
      ∧ toks.any (fun t => t = "approvals" ∨ t = "allowances")
  if ¬ (isAudit ∨ isShowList) then none
  -- Optional explicit wallet via `for <name>` (`indexOfKeyword "for"`).
  let walletHint? : Option String :=
    (indexOfKeyword toks "for").bind (fun i => at? toks (i + 1))
  let fields : List (String × String) :=
    [("verb", "audit")] ++
    (match walletHint? with
     | some w => [("wallet", w)]
     | none   => [])
  some {
    action     := .approvalsAudit
    fields     := fields
    unresolved := []
    -- Read-only — high confidence even without explicit wallet (daemon
    -- defaults to the user's default wallet).
    confidence := .high
  }

/-- `give me a fresh address [called <label>]`, `new EOA`, `new R1
smart account [named <label>]`, `hardware wallet`, etc. The skill picks
the wallet kind: `eoa` (BIP-39 default) vs `r1` (TPM hardware opt-in)
based on keyword presence. Label is captured when the user named one. -/
def matchFreshAddress (toks : List String) : Option RegexDraft := do
  let verb ← toks.head?
  let hasFreshHint :=
    (toks.any (fun t => t = "fresh"))
      ∨ (verb = "new" ∧ toks.any (fun t =>
          t = "address" ∨ t = "wallet" ∨ t = "eoa" ∨ t = "r1"
            ∨ t = "account"))
      ∨ (verb = "create" ∧ toks.any (fun t =>
          t = "wallet" ∨ t = "address" ∨ t = "account" ∨ t = "eoa" ∨ t = "r1"))
      ∨ (verb = "give" ∧ toks.any (fun t => t = "fresh"))
      ∨ (verb = "make" ∧ toks.any (fun t => t = "fresh"))
  if ¬ hasFreshHint then none
  -- R1 trigger words. EOA is the default; we flip to R1 only on
  -- explicit hardware-key / smart-account / TPM phrasing.
  let r1Triggers : List String :=
    ["r1", "tpm", "hardware", "hardware-backed", "secure", "enclave", "smart"]
  let isR1 := toks.any (fun t => r1Triggers.any (fun trig => t = trig))
  -- Label after `called <label>` or `named <label>`.
  let labelHint? : Option String :=
    ((indexOfKeyword toks "called").bind (fun i => at? toks (i + 1)))
      <|> ((indexOfKeyword toks "named").bind (fun i => at? toks (i + 1)))
  let fields : List (String × String) :=
    [("verb", "fresh"), ("kind", if isR1 then "r1" else "eoa")] ++
    (match labelHint? with
     | some l => [("label", l)]
     | none   => [])
  some {
    action     := .freshAddress
    fields     := fields
    unresolved := []
    confidence := .high
  }

/-- `wrap / unwrap <amount> <asset>` — no recipient or protocol. -/
def matchWrap (toks : List String) : Option RegexDraft := do
  let verb ← toks.head?
  let action ←
    match verb with
    | "wrap"   => some Action.wrap
    | "unwrap" => some Action.unwrap
    | _        => none
  let amountRaw ← at? toks 1
  if ¬ (isAmountLike amountRaw) then none
  let amount := (normalizeAmount amountRaw).getD amountRaw
  let assetRaw ← at? toks 2
  let asset := stripCashtag assetRaw
  let assetOk := isEthLike asset ∨ isKnownSymbol asset
  some {
    action     := action
    fields     := [("verb", verb), ("amount", amount), ("asset", asset)]
    unresolved := if assetOk then [] else [s!"asset '{asset}' not recognized for wrap/unwrap"]
    confidence := if assetOk then .high else .medium
  }

/-! ## Top-level entry -/

/-- Politeness/filler tokens that may prefix a real intent. We strip
them from the head of the token list before template matching so that
"can you supply 0.1 ETH on Aave" parses the same as "supply 0.1 ETH on
Aave". Order doesn't matter here; we just keep dropping while the head
is a filler. Lowercase is already applied by `tokenize`. -/
private def isLeadingFiller (s : String) : Bool :=
  s = "can" || s = "could" || s = "would" || s = "will" || s = "please"
    || s = "you" || s = "i" || s = "i'd" || s = "id"
    || s = "like" || s = "want" || s = "wanna" || s = "let's" || s = "lets"
    || s = "to"     -- only at head; bridge-words inside the template are positional
    || s = "hey"   || s = "ok" || s = "okay"

private partial def stripLeadingFillers : List String → List String
  | []        => []
  | t :: rest => if isLeadingFiller t then stripLeadingFillers rest else t :: rest

/-- Try every template; return the first hit. Falls back to a
`.rejected` draft when nothing matches (the LLM still runs in the chat
flow). Leading politeness words ("can you", "please", "I'd like to") are
stripped before matching so the user can ask conversationally. -/
def parse (input : String) : RegexDraft :=
  let toks := stripLeadingFillers (tokenize input)
  match toks with
  | [] => RegexDraft.empty
  | _ =>
      let candidates : List (Option RegexDraft) := [
        -- matchShielded MUST come before matchSupply /
        -- matchWithdrawBorrowRepay because the aliased forms reuse
        -- "deposit" / "withdraw" — those Aave matchers would steal
        -- the prompt otherwise. matchShielded gates aliased verbs
        -- on a privacy-hint check, so non-privacy Aave deposits/
        -- withdraws fall through to the Aave matchers unchanged.
        matchShielded toks
        -- audit / fresh have unique enough trigger sets ("approvals",
        -- "fresh", "new EOA", etc.) that they don't collide with any
        -- other template; order among themselves is irrelevant.
        , matchAuditApprovals toks
        , matchFreshAddress toks
        , matchSendOrTransfer toks
        , matchApprove toks
        , matchRevoke toks
        , matchSwap toks
        , matchSupply toks
        , matchWithdrawBorrowRepay toks
        , matchWrap toks
      ]
      match candidates.filterMap id with
      | d :: _ => d
      | []     => RegexDraft.empty

end LeanKohaku.LlmAgent.RuleParser
