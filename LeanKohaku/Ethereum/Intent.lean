import LeanKohaku.Ethereum.Address
import LeanKohaku.Swap.Tokens

/-!
# Semantic transaction intent

A user-level "what should this transaction *do*" — sits above
`LeanKohaku.Ethereum.Tx` (byte-level EIP-1559 fields) and below the TUI's
form fields and the LLM's parsed JSON. Both UX surfaces produce an
`Intent`; both flow through the same encoder + decode + simulate +
confirm pipeline. One ADT, one validator, one trust boundary.

## Why a sum type, not a flat record with optional fields

Each action has different required fields. Modelling them as nullable
columns invites a class of bug where the wrong combination passes
validation (e.g. a swap with no `tokenOut`). Pattern-matching on the
constructor makes those combinations structurally impossible.

## Construction

* **Trusted path**: TUI/CLI form fields → `Intent` via a total
  constructor (see `LeanKohaku/Ethereum/Intent.lean` and the future
  `Tx/Trusted.lean` glue). No parsing, no LLM. Construction is total —
  if the form validates, an `Intent` exists.
* **Chat path**: untrusted LLM JSON → `Intent` via the future
  `LeanKohaku/LlmAgent/IntentParser.lean`, which is fallible
  (`Except String Intent`) and hard-rejects on the known model-failure
  modes documented in `memory/project_local_llm_daemon.md`.

## Invariants this type encodes structurally

* `chainId` is always present (every constructor takes it).
* Addresses are typed (`LeanKohaku.Ethereum.Address.Address`), not
  strings; impossible to pass an unparsed hex blob.
* Slippage floor on swaps is non-optional (`minAmountOut : Nat`). The
  encoder is expected to refuse `minAmountOut = 0`.
* `approve` amount is structured (`ApproveAmount`), not a magic
  `2^256 - 1` sentinel. The trusted path can refuse `.unlimited` at the
  UX layer; the chat-path parser can flag it separately.

Theorems about the type live in `LeanKohaku/Invariants/IntentTrusted.lean`
(to be added in a later slice).
-/

namespace LeanKohaku.Ethereum.Intent

open LeanKohaku.Ethereum.Address

/-- EIP-155 chain ID. `Nat` rather than `LeanKohaku.Swap.Tokens.ChainId`
because the intent type must accept any chain the daemon is configured
for (testnets, alt-L1s) without requiring an exhaustive enum. The
encoder + validator narrow this back to the supported set. -/
abbrev ChainId := Nat

/-- Amount in the smallest unit of the asset (wei for ETH, token base
units for ERC-20s). -/
abbrev Amount := Nat

/-- How much an `approve` permits. The `unlimited` variant exists so the
trusted path can refuse it explicitly without us comparing against a
magic `2^256 - 1` constant — and so the chat-path parser can surface it
as a distinct warning. -/
inductive ApproveAmount where
  | exact (amount : Amount)
  | unlimited
  deriving Repr, DecidableEq

/-- How confident the producer of an `Intent` is. The trusted hard-wired
path always produces `.high`. The chat path's parser sets this based on
the regex/LLM agreement and the absence of hard-reject triggers. -/
inductive Confidence where
  | high
  | medium
  | low
  | rejected
  deriving Repr, DecidableEq

/-- Semantic intent — what the user wants to do, before encoding to
calldata. Each constructor carries exactly the fields it needs; no
optional gunk. -/
inductive Intent where
  /-- Native (ETH) transfer. No calldata. -/
  | nativeTransfer
      (chainId : ChainId)
      (to : Address)
      (amountWei : Amount)
  /-- ERC-20 transfer. `decimals` is captured at construction time so the
  intent is self-describing — the encoder doesn't have to round-trip
  through a registry, and a corrupted registry later can't change what
  bytes get signed. -/
  | erc20Transfer
      (chainId : ChainId)
      (token : Address)
      (decimals : Nat)
      (to : Address)
      (amount : Amount)
  /-- ERC-20 `approve`. The trusted UX can refuse `.unlimited` here. -/
  | erc20Approve
      (chainId : ChainId)
      (token : Address)
      (spender : Address)
      (amount : ApproveAmount)
  /-- Uniswap V3 single-pool exact-input swap.

  * `fee` — pool fee tier (uint24 in Solidity; 100 / 500 / 3000 / 10000).
  * `minAmountOut` — slippage floor in `tokenOut` base units. The
    encoder MUST refuse `minAmountOut = 0`.
  * `deadline` — Unix seconds; encoder should refuse if in the past. -/
  | uniswapV3SwapSingle
      (chainId : ChainId)
      (tokenIn : Address)
      (tokenOut : Address)
      (amountIn : Amount)
      (fee : Nat)
      (minAmountOut : Amount)
      (recipient : Address)
      (deadline : Nat)
  /-- Aave V3 `supply`. The required pre-step `approve` is emitted as a
  separate `erc20Approve` intent — multi-step flows are composed at the
  call site, not bundled here. -/
  | aaveV3Supply
      (chainId : ChainId)
      (asset : Address)
      (amount : Amount)
      (onBehalfOf : Address)
  /-- Aave V3 `withdraw`. -/
  | aaveV3Withdraw
      (chainId : ChainId)
      (asset : Address)
      (amount : Amount)
      (recipient : Address)
  /-- Last-resort: caller-supplied calldata. Used by the manual decode
  screen and by the chat path when the model picks `emit_raw_calldata`.
  Always treated as low-confidence by the UX layer; the simulate gate
  remains the user's primary safety net here. -/
  | rawCall
      (chainId : ChainId)
      (to : Address)
      (valueWei : Amount)
      (data : ByteArray)
      (rationale : String)

/-- The chain an intent applies to. -/
def Intent.chainId : Intent → ChainId
  | .nativeTransfer cid _ _              => cid
  | .erc20Transfer  cid _ _ _ _          => cid
  | .erc20Approve   cid _ _ _            => cid
  | .uniswapV3SwapSingle cid _ _ _ _ _ _ _ => cid
  | .aaveV3Supply   cid _ _ _            => cid
  | .aaveV3Withdraw cid _ _ _            => cid
  | .rawCall        cid _ _ _ _          => cid

/-- Coarse action category. Used by the regex parser (which hasn't
resolved tokens / addresses yet) and by the UI for routing to the right
confirm-screen layout. -/
inductive Action where
  | nativeTransfer
  | erc20Transfer
  | erc20Approve
  | swap
  | aaveSupply
  | aaveWithdraw
  | aaveBorrow
  | aaveRepay
  | wrap
  | unwrap
  | bridge
  | rawCall
  | unknown
  deriving Repr, DecidableEq

/-- The regex parser's structured output before it has been completed by
the LLM (chat path) or before it has been validated for the trusted
path. The LLM receives this as a *seed* — not as ground truth.

* `fields` carries the extracted attribute strings indexed by attribute
  name. Canonical keys: `"verb"`, `"amount"`, `"asset"`, `"to"`,
  `"protocol"`, `"slippage"`, `"chain"`, `"feeTier"`, `"deadline"`.
* `unresolved` is human-readable reasons the parser couldn't fully
  complete the intent — e.g., `"asset 'XYZ' not in known-tokens
  registry"`, `"recipient 'vitalik.eth' needs ENS resolution"`.
* `confidence` records what the parser thinks of its own output;
  `.rejected` means "this prompt doesn't look like a transaction at
  all", which still passes through to the LLM in case the user wrote
  something the regex missed.
-/
structure RegexDraft where
  action     : Action
  fields     : List (String × String)
  unresolved : List String
  confidence : Confidence
  deriving Repr

/-- An empty draft — every field unset, `Action.unknown`, rejected.
The starting point the parser builds up from. -/
def RegexDraft.empty : RegexDraft :=
  { action := .unknown
    fields := []
    unresolved := []
    confidence := .rejected }

/-- Look up an extracted field by canonical name. -/
def RegexDraft.field? (d : RegexDraft) (key : String) : Option String :=
  (d.fields.find? (fun (k, _) => k = key)).map Prod.snd

/-- Set / overwrite a field. Used by the parser as it builds the draft. -/
def RegexDraft.setField (d : RegexDraft) (key value : String) : RegexDraft :=
  { d with fields := (key, value) :: d.fields.filter (fun (k, _) => k ≠ key) }

/-- Add an unresolved-reason note. -/
def RegexDraft.note (d : RegexDraft) (reason : String) : RegexDraft :=
  { d with unresolved := reason :: d.unresolved }

end LeanKohaku.Ethereum.Intent
