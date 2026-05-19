import LeanKohaku.Ethereum.Intent
import LeanKohaku.Swap.Tokens

/-!
# Rule-based English → `RegexDraft` parser

Pure-Lean tokenizer + template matcher for natural-language transaction
intents. Replaces the regex matcher in `bridge/llm/src/draft.mjs`. Lean
is a strict win here: no regex ambiguity, total functions, the parser
output IS an ADT, every match arm typechecks.

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

/-- Split on whitespace and strip surrounding punctuation. Lowercases
each token so downstream matching is case-insensitive. -/
def tokenize (s : String) : List String :=
  let cleaned : String :=
    s.toList.foldr
      (fun c acc =>
        if c == ',' || c == '.' || c == ';' || c == '!' || c == '?' then
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
the user's input shape. -/
def isAmount (s : String) : Bool :=
  s.length > 0
  && s.toList.all (fun c => c.isDigit || c == '.')
  && s.toList.any Char.isDigit

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

/-- Recognize a known token symbol via `Swap.Tokens.findBySymbol`. -/
def isKnownSymbol (s : String) : Bool :=
  (LeanKohaku.Swap.Tokens.findBySymbol s).isSome

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

/-! ## Template matchers — each returns either a populated draft or
`none` (no match). The top-level `parse` tries them in order and picks
the first hit. -/

/-- `send/transfer <amount> <asset> to <recipient>`. -/
def matchSendOrTransfer (toks : List String) : Option RegexDraft := do
  -- Token 0 is the verb.
  let verb ← toks.head?
  if verb ≠ "send" ∧ verb ≠ "transfer" then none
  -- Find "to" — the recipient indicator.
  let toIdx ← indexOfKeyword toks "to"
  -- Pieces: tokens 1..toIdx-1 are amount + asset; toIdx+1 is recipient.
  let amount ← at? toks 1
  if ¬ (isAmount amount) then none
  let asset ← at? toks 2
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
  let amount := if isUnlimited then "unlimited" else amountTok
  if ¬ (isUnlimited ∨ isAmount amountTok) then none
  let asset ← at? toks 2
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
    ]
    unresolved := unresolved
    confidence := confidence
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
  let amount ← at? toks 1
  if ¬ (isAmount amount) then none
  let assetIn ← at? toks 2
  let assetOut ← at? toks (bridgeIdx + 1)
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

/-- Generic protocol-action template: verb + amount + asset + from/to + protocol. -/
def matchProtocolAction (toks : List String) (verb : String) (action : Action)
    (preposition : String) : Option RegexDraft := do
  let v ← toks.head?
  if v ≠ verb then none
  let prepIdx ← indexOfKeyword toks preposition
  let amount ← at? toks 1
  if ¬ (isAmount amount) then none
  let asset ← at? toks 2
  let protocol ← at? toks (prepIdx + 1)
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

/-- `wrap / unwrap <amount> <asset>` — no recipient or protocol. -/
def matchWrap (toks : List String) : Option RegexDraft := do
  let verb ← toks.head?
  let action ←
    match verb with
    | "wrap"   => some Action.wrap
    | "unwrap" => some Action.unwrap
    | _        => none
  let amount ← at? toks 1
  if ¬ (isAmount amount) then none
  let asset ← at? toks 2
  let assetOk := isEthLike asset ∨ isKnownSymbol asset
  some {
    action     := action
    fields     := [("verb", verb), ("amount", amount), ("asset", asset)]
    unresolved := if assetOk then [] else [s!"asset '{asset}' not recognized for wrap/unwrap"]
    confidence := if assetOk then .high else .medium
  }

/-! ## Top-level entry -/

/-- Try every template; return the first hit. Falls back to a
`.rejected` draft when nothing matches (the LLM still runs in the chat
flow). -/
def parse (input : String) : RegexDraft :=
  let toks := tokenize input
  match toks with
  | [] => RegexDraft.empty
  | _ =>
      let candidates : List (Option RegexDraft) := [
        matchSendOrTransfer toks
        , matchApprove toks
        , matchSwap toks
        , matchSupply toks
        , matchWithdrawBorrowRepay toks
        , matchWrap toks
      ]
      match candidates.filterMap id with
      | d :: _ => d
      | []     => RegexDraft.empty

end LeanKohaku.LlmAgent.RuleParser
