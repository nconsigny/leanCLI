import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Intent
import LeanCli.Swap.Tokens

/-!
# Pure-Lean `RegexDraft` → `Intent` synthesis (no LLM)

Short-circuits the chat path: when the daemon's regex pipeline has
already extracted every field needed to build an `Intent`, this module
does so directly. The LLM sidecar is never called.

Covers the leaf actions `IntentEncode.encode` handles:

* `nativeTransfer` — needs `to` (0x-resolved) + `amountBase`.
* `erc20Transfer`  — needs `to` + `asset` (symbol in token registry) +
  `amountBase`.
* `erc20Approve`   — needs `spender` + `asset` + an `amount` of one of:
  exact `amountBase`, `unlimited`, or revoke (set to zero).

The recursion-aware pattern in
`Daemon.Server.chat.draft` resolves `to` / `spender` against ENS, local
wallets, and the address book BEFORE calling us, and injects
`amountBase` via `Util.Units.parseUnits` using the registry's `decimals`.
By the time the daemon hands us a draft, the required fields are either
populated 0x-addresses + base-unit integers, or genuinely missing — in
which case the caller falls through to the LLM.

## Why not gate solely on `Confidence.high`

The regex assigns confidence eagerly (e.g., `medium` when the recipient
is a wallet-name like `"alice"`), but the daemon then resolves that name
to an address. Re-classifying after resolution would require threading
the regex pipeline through more state; cheaper and more honest is to let
the synthesizer succeed if and only if every needed field parses. That
matches what the encoder + the simulate + ConfirmGate gate actually
care about.

## What this module deliberately skips

`uniswapV3SwapSingle`, `aaveV3*`, `wrap`/`unwrap`, `bridge` — these
either need per-action chain-aware RPCs (pool selection, market
parameter lookup) or the LLM's judgment on which protocol to use. They
remain on the LLM path. The wrap/unwrap case in particular could be
absorbed later (it's a fixed-selector single call), but not in this
slice.

`approve … unlimited` IS handled. The trusted UX layer (ConfirmGate)
is the right place to refuse unlimited approval, not this synthesizer.
-/

namespace LeanCli.LlmAgent.DirectSynth

open LeanCli.Ethereum.Intent
open LeanCli.Ethereum.Address (Address)

/-- Parse a `0x`-prefixed hex address; structured error names what we
    were looking for so the caller's "couldn't synth" reason is readable
    in the TUI. -/
private def parseAddr (label : String) (s : String) : Except String Address :=
  match LeanCli.Ethereum.Address.fromHex s with
  | some a => .ok a
  | none   => .error s!"DirectSynth: {label} '{s}' is not a 0x40-hex address"

/-- Map a numeric chainId to the registry's `ChainId` enum, or refuse
    when we don't have a token registry for that chain. The caller falls
    through to the LLM for chains the wallet doesn't know. -/
private def chainIdFor (cid : Nat) : Except String LeanCli.Swap.Tokens.ChainId :=
  match cid with
  | 1        => .ok .mainnet
  | 11155111 => .ok .sepolia
  | _        => .error s!"DirectSynth: chainId {cid} not in Lean token registry"

/-- Resolve a token reference (symbol or 0x address) to a typed
    `Address` plus its `decimals`. Pure: no network, no daemon RPC.
    A `0x`-prefixed input is refused here because we don't have the
    decimals to construct a self-describing `erc20Transfer` — that's a
    legitimate LLM fall-through case (the LLM can ask the user or use a
    token-meta probe). -/
private def resolveToken (sym : String) (chain : LeanCli.Swap.Tokens.ChainId) :
    Except String (Address × Nat) :=
  if sym.startsWith "0x" || sym.startsWith "0X" then
    .error s!"DirectSynth: token '{sym}' is a raw 0x address — decimals unknown, deferring to LLM/probe"
  else
    match LeanCli.Swap.Tokens.findBySymbol sym with
    | none => .error s!"DirectSynth: token symbol '{sym}' not in Lean registry"
    | some t =>
        match LeanCli.Swap.Tokens.addressOn t chain with
        | none => .error s!"DirectSynth: '{sym}' has no canonical address on the selected chain"
        | some addrStr =>
            match parseAddr s!"token({sym})" addrStr with
            | .ok a    => .ok (a, t.decimals)
            | .error m => .error m

/-- Required-field accessor with a structured error pointing at the
    missing key. -/
private def fieldOrErr (d : RegexDraft) (k : String) : Except String String :=
  match d.field? k with
  | some v => .ok v
  | none   => .error s!"DirectSynth: regex draft is missing required field '{k}'"

/-- Parse a decimal string as `Nat`, with context for the error. -/
private def natOrErr (ctx s : String) : Except String Nat :=
  match s.toNat? with
  | some n => .ok n
  | none   => .error s!"DirectSynth: {ctx}: '{s}' is not a non-negative integer"

/-- Top-level: try to build an `Intent` from a `RegexDraft` + chainId
    using only wallet-side state. `.ok i` ⇒ the caller can encode and
    return without calling the LLM. `.error m` ⇒ the caller falls
    through to the LLM with `m` as a diagnostic.

    `senderAddr?` is the default wallet's 0x address, used for Intent
    fields the user didn't (and shouldn't have to) name in chat — Aave's
    `onBehalfOf`, Aave's withdraw `recipient`. When `none`, those
    actions fall through to the LLM (which has the wallet context). -/
def synth (draft : RegexDraft) (chainId : Nat) (senderAddr? : Option String := none) :
    Except String Intent := do
  let chain ← chainIdFor chainId
  match draft.action with
  | .nativeTransfer =>
      let toStr   ← fieldOrErr draft "to"
      let to      ← parseAddr "recipient" toStr
      let amtStr  ← fieldOrErr draft "amountBase"
      let amount  ← natOrErr "amountBase" amtStr
      pure (.nativeTransfer chainId to amount)
  | .erc20Transfer =>
      let toStr     ← fieldOrErr draft "to"
      let to        ← parseAddr "recipient" toStr
      let sym       ← fieldOrErr draft "asset"
      let resolved  ← resolveToken sym chain
      let tok       := resolved.fst
      let decs      := resolved.snd
      let amtStr    ← fieldOrErr draft "amountBase"
      let amount    ← natOrErr "amountBase" amtStr
      pure (.erc20Transfer chainId tok decs to amount)
  | .erc20Approve =>
      let spStr        ← fieldOrErr draft "spender"
      let spender      ← parseAddr "spender" spStr
      let sym          ← fieldOrErr draft "asset"
      let resolved     ← resolveToken sym chain
      let tok          := resolved.fst
      let isRevoke    := (draft.field? "revoke"    = some "true")
      let isUnlimited := (draft.field? "unlimited" = some "true")
      let amount : ApproveAmount ←
        if isRevoke then
          pure (.exact 0)
        else if isUnlimited then
          pure .unlimited
        else
          (do
            let amtStr ← fieldOrErr draft "amountBase"
            let n      ← natOrErr "amountBase" amtStr
            pure (.exact n))
      pure (.erc20Approve chainId tok spender amount)
  | .aaveSupply =>
      -- Aave supply: asset is the token to deposit, onBehalfOf is the
      -- sender's address. We refuse ETH as asset — Aave V3 mainnet uses
      -- the WrappedTokenGatewayV3 helper for native ETH, which is a
      -- different contract (not in the Lean registry yet). The user
      -- should `wrap` first, then supply WETH.
      let sym ← fieldOrErr draft "asset"
      if sym.toLower = "eth" then
        .error "DirectSynth: Aave V3 supply of native ETH needs the WrappedTokenGatewayV3 — wrap to WETH first, then supply WETH"
      else
        let senderStr ←
          match senderAddr? with
          | some s => pure s
          | none   => .error "DirectSynth: Aave supply needs a default wallet for onBehalfOf"
        let onBehalfOf ← parseAddr "onBehalfOf" senderStr
        let resolved   ← resolveToken sym chain
        let asset      := resolved.fst
        let amtStr     ← fieldOrErr draft "amountBase"
        let amount     ← natOrErr "amountBase" amtStr
        pure (.aaveV3Supply chainId asset amount onBehalfOf)
  | .aaveWithdraw =>
      -- Aave withdraw: recipient is the sender by default. Native ETH
      -- withdrawal same caveat as supply.
      let sym ← fieldOrErr draft "asset"
      if sym.toLower = "eth" then
        .error "DirectSynth: Aave V3 withdraw to native ETH needs the WrappedTokenGatewayV3 — withdraw WETH and unwrap"
      else
        let senderStr ←
          match senderAddr? with
          | some s => pure s
          | none   => .error "DirectSynth: Aave withdraw needs a default wallet for recipient"
        let recipient ← parseAddr "recipient" senderStr
        let resolved  ← resolveToken sym chain
        let asset     := resolved.fst
        let amtStr    ← fieldOrErr draft "amountBase"
        let amount    ← natOrErr "amountBase" amtStr
        pure (.aaveV3Withdraw chainId asset amount recipient)
  | .shieldedDeposit =>
      -- Privacy Pools deposit. Native ETH only; asset must resolve to
      -- "eth". Amount comes from `amountBase` (Lean-side parseUnits).
      let sym ← fieldOrErr draft "asset"
      if sym.toLower ≠ "eth" then
        .error s!"DirectSynth: shield only supports native ETH; got '{sym}'"
      else
        let amtStr ← fieldOrErr draft "amountBase"
        let amount ← natOrErr "amountBase" amtStr
        let _ := chain  -- chain not needed downstream; keep elaborated for symmetry
        pure (.shieldedDeposit chainId amount)
  | .shieldedWithdraw =>
      -- Privacy Pools withdraw. Native ETH, amountBase, recipient (the
      -- canonical fresh address). `viaRelayer` defaults to true here
      -- because the regex draft never carries it — the user opts out of
      -- relayer privacy only by emitting via the LLM with an explicit
      -- field, which falls outside this synth path.
      let sym ← fieldOrErr draft "asset"
      if sym.toLower ≠ "eth" then
        .error s!"DirectSynth: unshield only supports native ETH; got '{sym}'"
      else
        let amtStr    ← fieldOrErr draft "amountBase"
        let amount    ← natOrErr "amountBase" amtStr
        let recipStr  ← fieldOrErr draft "to"
        let recipient ← parseAddr "recipient" recipStr
        let _ := chain
        pure (.shieldedWithdraw chainId amount recipient true)
  | .railgunShield =>
      -- Railgun shield. ETH-only like the Privacy Pool path. The
      -- prepare RPC (`shielded.railgun.prepareShield`) does paymaster
      -- sponsorship + 7702 stamping at the bridge sidecar — never
      -- here. We MUST NOT fabricate a custom 7702 delegate; the
      -- paymaster rejects any code() ≠ the hardcoded IMPL constant
      -- (see [[project_railgun_poi]]).
      let sym ← fieldOrErr draft "asset"
      if sym.toLower ≠ "eth" then
        .error s!"DirectSynth: railgun shield only supports native ETH; got '{sym}'"
      else
        let amtStr ← fieldOrErr draft "amountBase"
        let amount ← natOrErr "amountBase" amtStr
        let _ := chain
        pure (.railgunShield chainId amount)
  | .railgunUnshield =>
      -- Railgun unshield. ETH-only + amountBase + recipient. Railgun
      -- handles relayer selection internally so there's no
      -- `viaRelayer` field to carry.
      let sym ← fieldOrErr draft "asset"
      if sym.toLower ≠ "eth" then
        .error s!"DirectSynth: railgun unshield only supports native ETH; got '{sym}'"
      else
        let amtStr    ← fieldOrErr draft "amountBase"
        let amount    ← natOrErr "amountBase" amtStr
        let recipStr  ← fieldOrErr draft "to"
        let recipient ← parseAddr "recipient" recipStr
        let _ := chain
        pure (.railgunUnshield chainId amount recipient)
  | .approvalsAudit =>
      -- Read-only. The optional `wallet` field is a 0x address by the
      -- time the chat.draft wallet-resolver has run; if it's absent,
      -- the daemon scopes to the default wallet.
      let wallet ←
        match draft.field? "wallet" with
        | none => pure (none : Option Address)
        | some s =>
            if s.startsWith "0x" || s.startsWith "0X" then
              match parseAddr "wallet" s with
              | .ok a    => pure (some a)
              | .error m => .error m
            else
              -- Unresolved wallet-name (e.g. "leanWallet") — chat.draft's
              -- resolver should have substituted, but if it didn't we
              -- defer to the LLM rather than silently dropping the hint.
              .error s!"DirectSynth: approvals.audit wallet '{s}' not resolved to 0x"
      let _ := chain
      pure (.approvalsAudit chainId wallet)
  | .freshAddress =>
      -- `.eoa` is the only wallet kind after the P-256/R1 path was
      -- removed; any extracted `kind` field is ignored.
      let kind : WalletKind := .eoa
      let label := draft.field? "label"
      let deployImmediately :=
        match draft.field? "deploy" with
        | some "true" => true
        | _           => false
      let _ := chain
      pure (.freshAddress chainId kind label deployImmediately)
  | _ =>
      .error s!"DirectSynth: action '{Action.toString draft.action}' is not in the pure-Lean synth set (defer to LLM)"

end LeanCli.LlmAgent.DirectSynth
