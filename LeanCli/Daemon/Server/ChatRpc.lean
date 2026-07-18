import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.AddressBook
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.SkillsStore
import LeanCli.Daemon.State
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Erc20
import LeanCli.Ethereum.Ens
import LeanCli.Ethereum.Intent
import LeanCli.Ethereum.IntentCanonical
import LeanCli.Ethereum.IntentEncode
import LeanCli.Ethereum.IntentJson
import LeanCli.Ethereum.Ownership
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.Wallet.EoaStore
import LeanCli.Wallet.SphincsHybridStore
import LeanCli.Aave.Prepare
import LeanCli.LlmAgent.AmountGuard
import LeanCli.LlmAgent.Bridge
import LeanCli.LlmAgent.DirectSynth
import LeanCli.LlmAgent.IntentParser
import LeanCli.LlmAgent.RuleParser
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Swap.Prepare
import LeanCli.Util.Units

/-!
# Daemon server: `chat.*` RPC family

The opt-in local-LLM chat-drafting pipeline. Five methods:

  chat.draft           — full pipeline: regex parse → llm.parseIntent
                          → IntentParser validate → IntentEncode, with
                          all intermediate state returned for TUI display
  chat.rolloverSession — clear the sticky (chainId, sessionKey) cache
  chat.listSessions    — list chat sessions stored on disk
  chat.getSession      — read a single session's tool-call log
  chat.listProposedTxs — extract every propose_send invocation across
                          sessions (pure read-through, no signing)

Every produced calldata still flows through decodeIntent → simulate →
ConfirmGate at the TUI / SendRawFlow boundary; chat.* never signs.
-/

namespace LeanCli.Daemon.Server.ChatRpc

open LeanCli.Encoding.Json
open LeanCli.Keystore.Tpm2Runtime
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-! Walk the agent's `trace` array for the LAST `propose_send` tool
call. The agent's `propose_send` has already validated the shape on
its side; this is the canonical signal "the model has reached its
final answer". When present in the trace, `extractProposeSendFromTrace`
returns the decoded args and `chat.draft` uses it as the intent,
overriding the prose-text path (the model's final assistant content
is then informational rather than the source of intent). A
malformed propose_send is treated as `none` rather than an error so
the existing IntentParser path runs as a fallback. -/

/-- Decoded shape of a propose_send tool call lifted out of the
    trace. `sender` is optional: the agent passes it whenever
    slot_lookup resolved a wallet for the user, which lets the TUI's
    SendRawFlow skip its wallet picker. -/
structure ProposeSendArgs where
  chainId : Nat
  to      : String
  value   : Nat
  data    : String
  sender  : Option String
  deriving Repr

private def parseProposeArgs (args : Json) : Option ProposeSendArgs :=
  match getField "chainId" args >>= asNat with
  | none => none
  | some cid =>
      match getField "to" args >>= asString with
      | none => none
      | some to =>
          let val : Nat := ((getField "value" args).bind asNat).getD 0
          let data : String :=
            ((getField "data" args).bind asString).getD "0x"
          let sender : Option String :=
            (getField "sender" args).bind asString
          some {
            chainId := cid, to := to, value := val,
            data := data, sender := sender
          }

private def proposeSendFromItem (item : Json) : Option ProposeSendArgs :=
  match item with
  | .obj fields =>
      let kind  := (fields.find? (·.1 == "kind")     |>.map (·.2)).getD .null
      let name  := (fields.find? (·.1 == "name")     |>.map (·.2)).getD .null
      let argsJ := (fields.find? (·.1 == "argsJson") |>.map (·.2)).getD .null
      match kind, name, argsJ with
      | .str "tool_call", .str "propose_send", .str argsStr =>
          match LeanCli.Encoding.Json.parse argsStr with
          | .ok args => parseProposeArgs args
          | _ => none
      | _, _, _ => none
  | _ => none

private partial def scanProposeSend :
    List Json → Option ProposeSendArgs
  | [] => none
  | item :: rest =>
      match scanProposeSend rest with
      | some hit => some hit
      | none => proposeSendFromItem item

private def extractProposeSendFromTrace (trace : Json) :
    Option ProposeSendArgs :=
  match trace with
  | .arr items => scanProposeSend items.toList
  | _ => none

/-- Map a 4-byte function selector to the canonical Intent action tag
    the TUI / skill-picker keys on. Used by the `agent-propose-send`
    branch of `chat.draft` so the response label reflects what the
    model's calldata actually does (e.g. "aaveV3Supply") rather than
    falling back to the regex's `.unknown` when the chat path went
    through the agent loop.

    This is the cheap side of the cross-validate gate (Phase 2 / PR 4
    of the privacy slice): we DO NOT walk the full ERC-7730 descriptor
    here — that's the sidecar's job — we just look up the selector
    against the set of selectors the wallet itself emits through its
    `prepare_*` tools + the standard ERC-20 surface. Unknown selectors
    return `none`; callers fall back to a generic label and the
    user still goes through `tx.simulate` + ConfirmGate before
    signing. -/
private def selectorToActionTag (data : String) : Option String :=
  -- A 4-byte selector occupies 8 hex chars; strip the leading `0x` and
  -- normalize to lowercase before lookup. `data` may legitimately be
  -- shorter than 10 chars for native ETH transfers ("0x") — fall
  -- through to `none` in that case.
  if data.length < 10 then none
  else
    let sel := (data.take 10).toString.toLower
    match sel with
    -- ERC-20 standard surface (Erc20.encodeTransfer / encodeApprove).
    | "0xa9059cbb" => some "erc20Transfer"
    | "0x095ea7b3" => some "erc20Approve"
    -- Aave Sepolia test faucet mint(address,address,uint256).
    | "0xc6c3bbe6" => some "faucet.mint"
    -- Uniswap V3 SwapRouter02 — token→token exact-input single-pool.
    | "0x414bf389" => some "uniswapV3SwapSingle"
    -- Aave V3 Pool surface (see LeanCli/Aave/V3Pool.lean).
    | "0x617ba037" => some "aaveV3Supply"
    | "0x69328dec" => some "aaveV3Withdraw"
    | "0xa415bcad" => some "aaveV3Borrow"
    | "0x573ade81" => some "aaveV3Repay"
    | "0x5a3b74b9" => some "aaveV3SetCollateral"
    -- Tornado Cash deposit / withdraw (sidecar-emitted; here for the
    -- day the bridge integration lands and propose_send carries
    -- tornado calldata).
    | "0xb214faa5" => some "shielded.tornado.deposit"
    | "0xb438689f" => some "shielded.tornado.withdraw"
    -- Smart-wallet batched output (see Wallet/ExecuteBatch.lean) —
    -- common shape for SCWs combining approve + supply into one
    -- ConfirmGate prompt.
    | "0x34fcd5be" => some "executeBatch"
    | _ => none

/-- Parser-driven skill selection (primary). Map the deterministic
    `RuleParser` action tag to the single most-specific skill directory.
    With a small context window (≈32k on the local Qwen3.6 setup), the
    value is precision: inject exactly the verb's skill, not a pile of
    protocol docs. Exhaustive over the action tags that HAVE a dedicated
    skill; tags with no skill yet (`wrap`/`unwrap`, `bridge`,
    `faucet.mint`, `stake`/`unstake`, `protocol.*`) return `none` and
    fall through to the phrase scan + the agent daemon's keyword trigger
    matcher. Keep this in sync with the `skills/` tree. -/
private def skillForActionTag (tag : String) (sawRevoke : Bool) : Option String :=
  match tag with
  | "nativeTransfer"            => some "send-native"
  | "erc20Transfer"             => some "send-erc20"
  | "erc20Approve"              => some (if sawRevoke then "revoke-approval" else "approve-erc20")
  | "swap"                      => some "swap-uniswap-v3"
  | "aaveSupply"                => some "aave"
  | "aaveWithdraw"              => some "aave"
  | "aaveBorrow"                => some "aave"
  | "aaveRepay"                 => some "aave"
  | "shielded.deposit"          => some "shield-eth"
  | "shielded.withdraw"         => some "unshield-eth"
  | "shielded.railgun.shield"   => some "railgun"
  | "shielded.railgun.unshield" => some "railgun"
  | "shielded.tornado.deposit"  => some "tornado-cash"
  | "shielded.tornado.withdraw" => some "tornado-cash"
  | "approvals.audit"           => some "audit-approvals"
  | "address.fresh"             => some "fresh-address"
  | "liquity.openTrove"         => some "bold-liquity"
  | "liquity.closeTrove"        => some "bold-liquity"
  | "ens.register"              => some "register-ens-name"
  | "ens.renew"                 => some "ens"
  | "ens.setAddr"               => some "ens"
  | "ens.setName"               => some "ens"
  | _                           => none

/-- Phrase-scan fallback (secondary). Fires only when the action tag
    yielded no skill — i.e. `RuleParser` returned `unknown`/`rejected` or
    an unmapped action. Best-effort context only: `IntentParser` still
    validates the actual emitted intent and `ConfirmGate` is the trust
    anchor, so a loose match costs nothing but a slightly-off skill body.
    Order tightest-first: privacy/audit/fresh before the generic
    send/approve/swap verbs (which the templates usually catch anyway),
    and `send` last as the catch-all. -/
private def skillForPhrases (promptLower : String) : String :=
  let containsAny (needles : List String) : Bool :=
    needles.any (fun n => (promptLower.splitOn n).length > 1)
  if containsAny ["unshield", "withdraw from privacy",
                  "exit privacy pool", "exit the privacy pool"] then
    "unshield-eth"
  else if containsAny ["shield ", "privacy pool", "privacy-pool",
                       "make this private", "make it private",
                       "make this anonymous", "deposit privately"] then
    "shield-eth"
  else if containsAny ["audit approvals", "list approvals",
                       "show approvals", "show my approvals",
                       "check approvals", "check allowances",
                       "check my approvals", "check my allowances",
                       "what have i approved", "list allowances",
                       "current allowances", "outgoing approvals"] then
    "audit-approvals"
  else if containsAny ["fresh address", "fresh wallet",
                       "rotate identity", "rotate to a new",
                       "new identity", "generate a new wallet",
                       "generate a fresh"] then
    "fresh-address"
  else if containsAny ["revoke", "cancel approval", "remove allowance",
                       "remove approval"] then
    "revoke-approval"
  else if containsAny ["approve ", "allowance", "grant approval"] then
    "approve-erc20"
  else if containsAny ["swap ", "trade ", "exchange ", " into ",
                       "convert "] then
    "swap-uniswap-v3"
  else if containsAny ["supply ", "borrow ", "repay ", "lend "] then
    "aave"
  else if containsAny ["send ", "transfer ", "pay "] then
    "send-native"
  else ""

/-- Drop the conjunction matcher's "can't batch / please split" notes
    (`RuleParser.matchConjunction`) from a regex JSON's `unresolved`
    list. The atomic-batch path uses this: once we've actually drafted
    (or attempted) an `executeBatch` for a smart account, those notes are
    stale and contradict the drafted batch — leaving them in makes the
    TUI say "please split into separate prompts" right next to a
    submitted two-leg batch. The legitimate EOA/unsupported case never
    reaches this — it falls through to the clarification short-circuit
    with the notes intact. -/
private def stripBatchSplitNotes (regexJson : Json) : Json :=
  let isSplitNote (s : String) : Bool :=
    (s.splitOn "split into separate").length > 1
      || (s.splitOn "does not draft batched").length > 1
  match regexJson with
  | .obj fields =>
      .obj (fields.map (fun kv =>
        if kv.fst = "unresolved" then
          match kv.snd with
          | .arr xs => (kv.fst, .arr (xs.filter (fun x =>
              match x with
              | .str s => !isSplitNote s
              | _      => true)))
          | other => (kv.fst, other)
        else kv))
  | other => other

/-- Uniform output re-check for a built `chat.draft` response. If the
    response carries an `encoded` leaf, re-decode its native `value` and
    calldata `data` and assert every magnitude equals a Lean-derived
    `allowed` amount (`AmountGuard.revalidate`). This makes the
    verify-at-output guarantee uniform across BOTH the `propose_send`
    tool path and the prose-JSON `IntentParser` path — the latter lets
    the model write an amount straight into the Intent, so it needs the
    same backstop. Responses with no `encoded` leaf (prepare / audit /
    create directives, asks) pass through: their calldata, when it
    exists, is Lean-encoded by the downstream `prepare_*` RPC. -/
private def guardEncodedAmounts (resp : Json) (allowed : List Nat) :
    Except String Json :=
  match getField "encoded" resp with
  | some enc =>
      let value : Nat :=
        match getField "value" enc with
        | some (.str s) =>
            let body := if s.startsWith "0x" then (s.drop 2).toString else s
            (LeanCli.LlmAgent.AmountGuard.hexToNat? body).getD 0
        | some j => (asNat j).getD 0
        | none => 0
      let data := (getField "data" enc >>= asString).getD "0x"
      match LeanCli.LlmAgent.AmountGuard.revalidate value data allowed with
      | .ok ()  => .ok resp
      | .error m => .error m
  | none => .ok resp

/-- Build the `chat.draft` response JSON for a parsed/synthesized Intent.

For leaf-encodable variants (nativeTransfer, erc20*, swap-leg, aave*,
rawCall) this returns the `encoded` tx shape the TUI feeds into
`tx.simulate` + ConfirmGate exactly as before.

For the privacy / hygiene / wallet variants the encoder isn't applicable
(see `IntentEncode.encode`'s explicit `.error` branches). Instead we
return a `prepare` / `audit` / `create` directive naming the daemon RPC
the TUI should call next:

* `shielded.deposit`  → `prepare = {rpc: "shielded.prepareDeposit",  …}`
* `shielded.withdraw` → `prepare = {rpc: "shielded.prepareWithdraw", …}`
* `approvals.audit`   → `audit   = {rpc: "daemon.approvals.list",    …}`
* `address.fresh`     → `create  = {rpc: "eoa.create",  …}`

The TUI dispatches the directive, then per-tx ConfirmGate over the
returned prepared txs (for shielded) or shows the read-only result
(for audit / create). The trust boundary — every tx still flows
through `tx.simulate` + per-tx ConfirmGate before signing — is
preserved by routing through `prepare*` RPCs that return prepared
(unsigned) txs, NOT the existing one-shot `shielded.deposit` /
`shielded.withdraw` RPCs which sign-and-broadcast internally. -/
private def chatDraftIntentResponse
    (intent : LeanCli.Ethereum.Intent.Intent)
    (baseFields : Array (String × Json))
    (synthLabel : Option String)
    (chainId : Nat) :
    Json :=
  let canonical := LeanCli.Ethereum.IntentCanonical.toCanonicalString intent
  let actionTag := LeanCli.Ethereum.IntentCanonical.actionTag intent
  let synthArr : Array (String × Json) :=
    match synthLabel with
    | some s => #[("synth", .str s)]
    | none   => #[]
  let commonFields : Array (String × Json) :=
    baseFields ++ #[
      ("intentActionTag", .str actionTag),
      ("canonical",       .str canonical)
    ] ++ synthArr
  let addrJson (a : LeanCli.Ethereum.Address.Address) : Json :=
    .str (LeanCli.Crypto.Hex.encode a.bytes)
  match intent with
  | .shieldedDeposit _ amountWei =>
      let amountEth := LeanCli.Util.Units.formatUnits amountWei 18
      .obj <| commonFields ++ #[
        ("prepare", .obj #[
          ("rpc",    .str "shielded.prepareDeposit"),
          ("params", .obj #[
            ("amountEth", .str amountEth),
            ("chainId",   .num (Int.ofNat chainId))
          ])
        ])
      ]
  | .shieldedWithdraw _ amountWei recipient viaRelayer =>
      let amountEth := LeanCli.Util.Units.formatUnits amountWei 18
      .obj <| commonFields ++ #[
        ("prepare", .obj #[
          ("rpc",    .str "shielded.prepareWithdraw"),
          ("params", .obj #[
            ("amountEth",  .str amountEth),
            ("recipient",  addrJson recipient),
            ("viaRelayer", .bool viaRelayer),
            ("chainId",    .num (Int.ofNat chainId))
          ])
        ])
      ]
  | .railgunShield _ amountWei =>
      -- Railgun shield: route to the existing `shielded.railgun.prepareShield`
      -- RPC. The Lean side has done amount parsing + dust-floor checks
      -- (see [[project_railgun_poi]] for the paymaster/POI constraints
      -- the sidecar still enforces).
      let amountEth := LeanCli.Util.Units.formatUnits amountWei 18
      .obj <| commonFields ++ #[
        ("prepare", .obj #[
          ("rpc",    .str "shielded.railgun.prepareShield"),
          ("params", .obj #[
            ("amountEth", .str amountEth),
            ("chainId",   .num (Int.ofNat chainId))
          ])
        ])
      ]
  | .railgunUnshield _ amountWei recipient =>
      -- Railgun unshield: route to `shielded.railgun.unshield`. Unlike
      -- the Privacy Pool path there is no `prepareUnshield` step — the
      -- bridge SDK builds the unshield userOp in one pass. The
      -- daemon's `shielded.railgun.unshield` still returns prepared
      -- (unsigned) calldata, so the TUI's ConfirmGate is preserved.
      let amountEth := LeanCli.Util.Units.formatUnits amountWei 18
      .obj <| commonFields ++ #[
        ("prepare", .obj #[
          ("rpc",    .str "shielded.railgun.unshield"),
          ("params", .obj #[
            ("amountEth", .str amountEth),
            ("recipient", addrJson recipient),
            ("chainId",   .num (Int.ofNat chainId))
          ])
        ])
      ]
  | .tornadoDeposit _ denominationWei =>
      -- Tornado deposit: route to `shielded.tornado.prepareDeposit`.
      -- The bridge derives the note secrets from the wallet seed,
      -- Pedersen-hashes the commitment, and returns UNSIGNED deposit
      -- calldata (multiple legs for a multi-denomination amount) that the
      -- TUI confirms and signs. No note to save — the seed recovers it.
      let amountEth := LeanCli.Util.Units.formatUnits denominationWei 18
      .obj <| commonFields ++ #[
        ("prepare", .obj #[
          ("rpc",    .str "shielded.tornado.prepareDeposit"),
          ("params", .obj #[
            ("amountEth", .str amountEth),
            ("chainId",   .num (Int.ofNat chainId))
          ])
        ])
      ]
  | .tornadoWithdraw _ denominationWei recipient _noteRef =>
      -- Tornado withdraw: route to `shielded.tornado.quoteWithdraw` (the
      -- pre-broadcast quote step). The bridge syncs the pool's merkle
      -- state, and — after the ConfirmGate accepts the quoted fee/net —
      -- `executeWithdraw` builds the groth16 proof and submits it via the
      -- paymaster (default) or a relayer. No saved note is required; the
      -- wallet re-derives spendable notes from its seed.
      let amountEth := LeanCli.Util.Units.formatUnits denominationWei 18
      .obj <| commonFields ++ #[
        ("prepare", .obj #[
          ("rpc",    .str "shielded.tornado.quoteWithdraw"),
          ("params", .obj #[
            ("amountEth", .str amountEth),
            ("recipient", addrJson recipient),
            ("mode",      .str "paymaster"),
            ("chainId",   .num (Int.ofNat chainId))
          ])
        ])
      ]
  | .approvalsAudit _ wallet =>
      let walletEntry : Array (String × Json) :=
        match wallet with
        | some a => #[("wallet", addrJson a)]
        | none   => #[]
      .obj <| commonFields ++ #[
        ("audit", .obj #[
          ("rpc",    .str "daemon.approvals.list"),
          ("params", .obj <| #[("chainId", .num (Int.ofNat chainId))] ++ walletEntry)
        ])
      ]
  | .freshAddress _ kind label deployImmediately =>
      let rpc : String :=
        match kind with
        | .eoa => "eoa.create"
      let labelEntry : Array (String × Json) :=
        match label with
        | some l => #[("label", .str l)]
        | none   => #[]
      .obj <| commonFields ++ #[
        ("create", .obj #[
          ("rpc",    .str rpc),
          ("params", .obj <| #[
            ("kind",              .str (LeanCli.Ethereum.Intent.WalletKind.toString kind)),
            ("deployImmediately", .bool deployImmediately),
            ("chainId",           .num (Int.ofNat chainId))
          ] ++ labelEntry)
        ])
      ]
  | _ =>
      match LeanCli.Ethereum.IntentEncode.encode intent with
      | .error msg =>
          .obj <| commonFields ++ #[("encodeError", .str msg)]
      | .ok enc =>
          .obj <| commonFields ++ #[
            ("encoded", .obj #[
              ("to",      .str enc.to),
              -- Wei as a 0x-quantity hex STRING, not a JSON number: a JS
              -- client's JSON.parse would silently round any value above
              -- 2^53 to a double before it could be widened to bigint.
              -- Same encoder the tx-framing path uses (natQuantityHex).
              ("value",   .str (natQuantityHex enc.valueWei)),
              ("data",    .str enc.data),
              ("chainId", .num (Int.ofNat chainId))
            ])
          ]

/-- `"0.5%"` / `"0.5"` → `50` bps; `"1%"` → `100`. Strips a trailing `%`
    and reads the percentage with two implied decimals (pct × 100 = bps,
    which is exactly `parseUnits pct 2`). `none` on a non-numeric body. -/
private def parseSlippagePctToBps (s : String) : Option Nat :=
  let body := if s.endsWith "%" then (s.take (s.length - 1)).toString else s
  LeanCli.Util.Units.parseUnits body 2

/-- Encode a `Swap.Prepare.TxFrame` as the `encoded` object the TUI feeds
    into `tx.simulate` + ConfirmGate. `value` is a `0x`-quantity STRING,
    never a JSON number (JS `JSON.parse` would round wei > 2^53). -/
private def swapFrameEncoded (f : LeanCli.Swap.Prepare.TxFrame) (chainId : Nat) : Json :=
  .obj #[
    ("to",      .str f.to),
    ("value",   .str (natQuantityHex f.value)),
    ("data",    .str f.data),
    ("chainId", .num (Int.ofNat chainId))
  ]

/-- Encode an Aave prepared frame as the `encoded` object the TUI feeds
    into `tx.simulate` + ConfirmGate. Includes `sender` so chat can skip
    the wallet picker when the prompt named a slot. -/
private def aaveFrameEncoded
    (f : LeanCli.Aave.Prepare.TxFrame) (chainId : Nat) (sender : String) : Json :=
  .obj #[
    ("to",      .str f.to),
    ("value",   .str (natQuantityHex f.value)),
    ("data",    .str f.data),
    ("chainId", .num (Int.ofNat chainId)),
    ("sender",  .str sender)
  ]

/-- Map a deterministic `prepareUniswapV3Swap` result into a `chat.draft`
    response. `.ready` drafts the swap leg directly; `.needsApproval`
    drafts the ERC-20 approve leg FIRST — re-issuing the same swap prompt
    after it broadcasts yields leg 2 (allowance now suffices), matching the
    EOA "one leg per confirm" model. Both land in the standard `encoded`
    shape so the TUI's existing simulate → ConfirmGate path renders them
    unchanged. `.err` surfaces a deterministic `swapError` rather than
    detouring through the LLM. -/
private def swapResultToDraftJson
    (result : LeanCli.Swap.Prepare.PrepareResult)
    (baseFields : Array (String × Json)) (chainId : Nat) : Json :=
  let common := baseFields ++ #[("backend", .str "wallet-direct-swap")]
  match result with
  | .ready swap _ _ _ _ _ summary =>
      .obj <| common ++ #[
        ("intentActionTag", .str "uniswapV3SwapSingle"),
        ("canonical",       .str summary),
        ("encoded",         swapFrameEncoded swap chainId)
      ]
  | .needsApproval approve _ _ _ _ _ _ _ _ summary =>
      .obj <| common ++ #[
        ("intentActionTag", .str "erc20Approve"),
        ("canonical",       .str s!"Approve router (leg 1 of 2) — then {summary}"),
        ("swapNote",        .str "router approval first; re-issue the swap to broadcast leg 2"),
        ("encoded",         swapFrameEncoded approve chainId)
      ]
  | .err kind msg =>
      -- Give the failure a friendly head + one-line reason (no `encoded`,
      -- so it is NOT signable) instead of letting the TUI fall back to the
      -- bare regex action "swap" with the cause hidden.
      .obj <| common ++ #[
        ("intentActionTag", .str "uniswapV3SwapSingle"),
        ("canonical",       .str s!"Swap not prepared ({kind})"),
        ("swapError",       .str msg)
      ]

/-- Map an Aave prepare result into a `chat.draft` response. For a
    SPHINCS native-ETH supply this is normally a single `ready`
    executeBatch frame. Plain EOA ERC-20 supply can still surface the
    approval leg first. -/
private def aaveResultToDraftJson
    (result : LeanCli.Aave.Prepare.PrepareResult)
    (baseFields : Array (String × Json)) (chainId : Nat) (sender : String)
    (actionTag : String) (noun : String) : Json :=
  let common := baseFields ++ #[("backend", .str "wallet-direct-aave")]
  match result with
  | .ready action summary =>
      .obj <| common ++ #[
        ("intentActionTag", .str actionTag),
        ("canonical",       .str summary),
        ("encoded",         aaveFrameEncoded action chainId sender)
      ]
  | .needsApproval approve _action _current _required summary =>
      .obj <| common ++ #[
        ("intentActionTag", .str "erc20Approve"),
        ("canonical",       .str s!"Approve Aave Pool (leg 1 of 2) — then {summary}"),
        ("aaveNote",        .str s!"pool approval first; re-issue the Aave {noun} to broadcast leg 2"),
        ("encoded",         aaveFrameEncoded approve chainId sender)
      ]
  | .err kind msg =>
      .obj <| common ++ #[
        ("intentActionTag", .str actionTag),
        ("canonical",       .str s!"Aave {noun} not prepared ({kind})"),
        ("aaveError",       .str msg)
      ]

private structure AaveBatchLeg where
  verb : String
  amount : String
  asset : String
  deriving Repr

private def stripCashtagLocal (s : String) : String :=
  if s.startsWith "$" then (s.drop 1).toString else s

private def isAaveRetailVerb : String → Bool
  | "supply" | "deposit" | "withdraw" | "borrow" | "repay" => true
  | _ => false

private def canonicalAaveVerb : String → String
  | "deposit" => "supply"
  | v => v

private def firstConjunctionIndex (toks : List String) : Option Nat :=
  (List.range toks.length).find? fun i =>
    match toks[i]? with
    | some "and" | some "then" => true
    | _ => false

private def splitAtConjunction (toks : List String) :
    Option (List String × List String) := do
  let i ← firstConjunctionIndex toks
  some (toks.take i, toks.drop (i + 1))

private def parseAaveBatchLeg (toks : List String) : Option AaveBatchLeg := do
  let verbIdx ← (List.range toks.length).find? fun i =>
    match toks[i]? with
    | some v => isAaveRetailVerb v
    | none => false
  let verb ← toks[verbIdx]?
  let amountRaw ← toks[verbIdx + 1]?
  let amount ← LeanCli.LlmAgent.RuleParser.normalizeAmount amountRaw
  let assetRaw ← toks[verbIdx + 2]?
  let asset := stripCashtagLocal assetRaw
  some {
    verb := canonicalAaveVerb verb
    amount := amount
    asset := asset
  }

private def parseTwoAaveBatchLegs (prompt : String) :
    Option (AaveBatchLeg × AaveBatchLeg) := do
  let toks := LeanCli.LlmAgent.RuleParser.tokenize prompt
  if !(toks.any (fun t => t = "aave" || t = "aavev3")) then none
  let (left, right) ← splitAtConjunction toks
  let a ← parseAaveBatchLeg left
  let b ← parseAaveBatchLeg right
  some (a, b)

private def aaveDecimalsForAsset (chainId : Nat) (asset : String) : Option Nat := do
  let chain ← LeanCli.Aave.Prepare.chainIdToEnum? chainId
  let (tok?, _) ← LeanCli.Aave.Prepare.resolveAsset
    (LeanCli.Aave.Prepare.poolAssetInput asset) chain
  match tok? with
  | some t => some t.decimals
  | none => some 18

private def readyFrameOrError
    (result : LeanCli.Aave.Prepare.PrepareResult) :
    Except (String × String) (LeanCli.Aave.Prepare.TxFrame × String) :=
  match result with
  | .ready frame summary => .ok (frame, summary)
  | .needsApproval _ _ _ _ summary =>
      .error ("approval_required", s!"Aave batch leg needs an approval first: {summary}")
  | .err kind msg => .error (kind, msg)

/-- Map the error branch of `prepareNativeEthSupplySmartLegs` (always a
    `PrepareResult.err`) to the batch path's `(kind, msg)` pair. The
    other constructors cannot occur there; surfaced as a stable
    protocol error rather than a panic if they ever do. -/
private def prepareErrPair
    (r : LeanCli.Aave.Prepare.PrepareResult) : String × String :=
  match r with
  | .err kind msg => (kind, msg)
  | .needsApproval _ _ _ _ summary =>
      ("approval_required", s!"Aave batch leg needs an approval first: {summary}")
  | .ready _ _ => ("protocol_error", "unexpected ready result in error branch")

/-- Prepare one conjunction leg as RAW frames — never a self-directed
    `executeBatch`. The two-leg batch path composes every leg into ONE
    outer `executeBatch`, and the account contract's `executeBatch`
    entry is EntryPoint-only: a leg that is itself
    `executeBatch(self, …)` self-calls with `msg.sender ==
    address(this)` and reverts the whole batch on-chain. Native-ETH
    supply therefore expands to its wrap / approve / supply legs here
    instead of the pre-collapsed single frame
    `prepareNativeEthSupplySmart` returns. -/
private def prepareAaveBatchLegFrames
    (chainId : Nat) (sender : String) (shim : LeanCli.Aave.Prepare.ChainEthCallShim)
    (leg : AaveBatchLeg) :
    IO (Except (String × String) (List LeanCli.Aave.Prepare.TxFrame × String)) := do
  let some decimals := aaveDecimalsForAsset chainId leg.asset
    | pure (.error ("unknown_asset", s!"asset {leg.asset} is not known to the Aave market on chainId {chainId}"))
  let some amountBase := LeanCli.Util.Units.parseUnits leg.amount decimals
    | pure (.error ("bad_amount", s!"could not parseUnits {leg.amount} with decimals {decimals}"))
  if leg.verb == "supply" && LeanCli.Aave.Prepare.isNativeEthInput leg.asset then
    match ← LeanCli.Aave.Prepare.prepareNativeEthSupplySmartLegs
        chainId sender sender amountBase shim with
    | .error r => pure (.error (prepareErrPair r))
    | .ok (frames, summary) => pure (.ok (frames, summary))
  else
    let result ← match leg.verb with
      | "supply" =>
          LeanCli.Aave.Prepare.prepareSupply
            chainId sender sender leg.asset amountBase shim
      | "withdraw" =>
          LeanCli.Aave.Prepare.prepareWithdraw
            chainId sender sender leg.asset amountBase shim
      | "borrow" =>
          LeanCli.Aave.Prepare.prepareBorrow
            chainId sender sender leg.asset amountBase
            LeanCli.Aave.V3Pool.InterestRateMode.variable shim
      | "repay" =>
          LeanCli.Aave.Prepare.prepareRepay
            chainId sender sender leg.asset amountBase
            LeanCli.Aave.V3Pool.InterestRateMode.variable shim
      | _ =>
          pure (.err "unsupported_batch_leg" s!"Aave batch leg is not supported yet: {leg.verb}")
    match readyFrameOrError result with
    | .error e => pure (.error e)
    | .ok (frame, summary) => pure (.ok ([frame], summary))

/-- Handle every `chat.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (_notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "chat.draft" =>
      -- Unified entry point for the opt-in local-LLM chat path.
      --
      -- Composes (regex parse → llm.parseIntent → IntentParser validate
      -- → IntentEncode) into one round-trip. Returns ALL intermediate
      -- state so the TUI can show the user what the regex saw, what
      -- the model said, and what was rejected (if anything). The TUI
      -- still has the final say: it shows the encoded tx + canonical
      -- text in ConfirmGate, then signs.
      --
      -- params: { prompt : String, chainId : Nat, history? : Array { role, content } }
      -- `history` is forwarded verbatim to the sidecar. The sidecar
      -- filters to {role: user|assistant, content: string} and caps to
      -- the last N turns; the daemon does not need to inspect it. Trust
      -- model: history text is untrusted exactly like `prompt` — the
      -- Lean IntentParser still hard-rejects whatever the model emits.
      match paramString req.params "prompt",
            getField "chainId" req.params >>= asNat with
      | .ok prompt, some chainId =>
          -- 1. Regex pass (pure Lean). Always runs.
          let regex0 := LeanCli.LlmAgent.RuleParser.parse prompt
          -- 1a. ENS pre-resolution. The model has no network egress; the
          -- daemon does. Resolving `.eth` names here removes the most
          -- common ask-loop ("can't resolve ENS, please paste 0x..."),
          -- and the model's prompt context gets the canonical 0x in the
          -- seed. Walks the conventionally-named recipient fields the
          -- RuleParser produces.
          let resolveEnsField : String → LeanCli.Ethereum.Intent.RegexDraft → IO LeanCli.Ethereum.Intent.RegexDraft :=
            fun key d => do
              match d.field? key with
              | none => pure d
              | some s =>
                  if !s.endsWith ".eth" then pure d
                  else
                    match cfg.ensRpcEndpoint with
                    | none =>
                        pure (d.note s!"ENS resolution unavailable: set ens_rpc_url to auto-resolve {s}")
                    | some ensEp =>
                        let viaEns? ← verifiedReadVia state 1 ensEp
                        match ← LeanCli.Ethereum.Ens.resolveIO cfg.policy ensEp 1 s viaEns? with
                        | .ok r =>
                            pure ((d.setField key r.address).note s!"resolved {s} → {r.address}")
                        | .error (_, m) =>
                            pure (d.note s!"failed to resolve {s}: {m}")
          let regex1 ← resolveEnsField "to" regex0
          let regex2 ← resolveEnsField "spender" regex1
          -- 1a-bis. Wallet-name + address-book-label resolution. The
          -- CLI knows the user's wallets ("leanWallet", "fresh1") and
          -- the address book labels ("alice", "niard"). When the regex
          -- extracted those, swap in the resolved address before the
          -- LLM ever sees the prompt — saves an entire ask-loop. Same
          -- pattern as ENS resolution above.
          -- Per-entry shape carries derivation info so the resolver can
          -- *re-derive* an unlocked EOA seed at the recorded path and
          -- structurally compare against the on-disk address. The third
          -- slot is `some (slotName, path)` for EOA entries (BIP-44
          -- derivable). See Invariants/AddressOwnership.lean for the
          -- safety proof.
          let eoaNames ← LeanCli.Wallet.EoaStore.list
          let mut walletEntries : List (String × String × Option (String × String)) := []
          for name in eoaNames do
            match ← LeanCli.Wallet.EoaStore.load name with
            | .ok rec =>
                walletEntries := walletEntries ++
                  [(rec.name, rec.address, some (rec.name, rec.derivationPath))]
                for acct in recordAccounts rec do
                  let subKey :=
                    match acct.label with
                    | some l => s!"{rec.name}/{l}"
                    | none   => s!"{rec.name}/{acct.index}"
                  walletEntries := walletEntries ++
                    [(subKey, acct.address, some (rec.name, acct.path))]
            | .error _ => pure ()
          let sphincsNames ← LeanCli.Wallet.SphincsHybridStore.listSlotNames
          for name in sphincsNames do
            match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
            | .ok rec =>
                match rec.smartAccountAddress with
                | some addr =>
                    walletEntries := walletEntries ++ [(rec.name, addr, none)]
                | none => pure ()
            | .error _ => pure ()
          let bookEntries ← LeanCli.Daemon.AddressBook.loadIO
          let book := match bookEntries with
            | .ok xs => xs
            | .error _ => []
          -- Per-entry ownership status. EOA + unlocked → re-derive and
          -- compare; EOA + locked → `.locked`; non-derivable (no recorded
          -- path) → `.hardware`. The only branch that emits `.verified`
          -- performs the actual `deriveAddressFromSeed` and structurally
          -- compares (invariant 14.1).
          let computeOwnership :
              String → Option (String × String) →
              IO LeanCli.Ethereum.Ownership.Status :=
            fun addr deriv? => do
              match deriv? with
              | none => pure .hardware
              | some (slotName, path) =>
                  match ← LeanCli.Daemon.State.getUnlocked? state slotName with
                  | none => pure .locked
                  | some slot =>
                      match ← deriveAddressFromSeed slot.seed path with
                      | .ok derived =>
                          if derived.toLower = addr.toLower then
                            pure (.verified path)
                          else
                            pure (.mismatch derived)
                      | .error _ => pure .locked
          let resolveLocal (key : String) (d : LeanCli.Ethereum.Intent.RegexDraft) :
              IO (LeanCli.Ethereum.Intent.RegexDraft ×
                  Option LeanCli.Ethereum.Ownership.Witness) := do
            match d.field? key with
            | none => pure (d, none)
            | some s =>
                let lower := s.toLower
                match walletEntries.find? (fun e => e.fst.toLower = lower) with
                | some (_, addr, deriv?) =>
                    let d' := (d.setField key addr).note s!"resolved wallet '{s}' → {addr}"
                    let status ← computeOwnership addr deriv?
                    pure (d', some { key := key, address := addr, status := status })
                | none =>
                    match book.find? (fun e => e.label.toLower = lower) with
                    | some e =>
                        let d' := (d.setField key e.address).note
                          s!"resolved book label '{s}' → {e.address}"
                        pure (d',
                          some { key := key, address := e.address, status := .book })
                    | none => pure (d, none)
          let (regex3, w_to) ← resolveLocal "to" regex2
          let (regex4, w_spender) ← resolveLocal "spender" regex3
          let (regex5, w_from) ← resolveLocal "from" regex4
          let (regex6, w_wallet) ← resolveLocal "wallet" regex5
          let ownerships : List LeanCli.Ethereum.Ownership.Witness :=
            [w_to, w_spender, w_from, w_wallet].filterMap id
          -- 1a-ter. Deterministic amount conversion. Models are
          -- documented unreliable at unit conversion (we caught gpt-oss
          -- emit `1e15` for "0.01 ETH" instead of `1e16`). The daemon
          -- already has the decimals via Swap.Tokens; parse here and
          -- inject `amountBase` so the model only has to copy.
          let chainEnumOpt0 : Option LeanCli.Swap.Tokens.ChainId :=
            match chainId with
            | 1 => some .mainnet
            | 11155111 => some .sepolia
            | _ => none
          let decimalsForAsset (asset : String) : Option Nat :=
            let a := asset.toLower
            if a = "eth" || a = "wei" || a = "ether" then some 18
            else match LeanCli.Swap.Tokens.findBySymbol asset with
                 | some t => some t.decimals
                 | none => none
          let regex := match regex6.field? "amount", regex6.field? "asset" with
            | some amt, some asset =>
                match decimalsForAsset asset with
                | none => regex6
                | some d =>
                    match LeanCli.Util.Units.parseUnits amt d with
                    | some n =>
                        (regex6.setField "amountBase" (toString n)).note
                          s!"parseUnits {amt} {d} = {n} ({asset})"
                    | none => regex6.note s!"could not parseUnits {amt} with decimals {d}"
            | _, _ => regex6
          -- 1a-quater. Publish the Lean-converted amount as a referenceable
          -- table entry. The model addresses an amount by its `ref`
          -- ("amt1") and is forbidden — by the `amountRef`-only tool
          -- schemas and the `revalidateAmounts` output check — from ever
          -- typing a magnitude. `base` crosses the wire as a decimal
          -- string (JSON numbers truncate past 2^53). Today we publish at
          -- most one entry (the single amount the templates extract);
          -- multi-amount prompts ("swap A for B at most C") and
          -- balance-relative amounts ("half", "all") are a Lean-side
          -- follow-up — they must also be daemon-derived, never modelled.
          let amountsJson : Json :=
            match regex.field? "amount", regex.field? "asset",
                  regex.field? "amountBase" with
            | some amt, some asset, some baseStr =>
                .arr #[ .obj #[
                  ("ref",      .str "amt1"),
                  ("human",    .str amt),
                  ("symbol",   .str asset.toUpper),
                  ("base",     .str baseStr),
                  ("decimals", .num (Int.ofNat ((decimalsForAsset asset).getD 0)))
                ]]
            | _, _, _ => .arr #[]
          let _ := chainEnumOpt0  -- chainEnumOpt rebuilt below; this binding keeps the helper alive while we widen the scope of the chain enum after the upcoming chainContext step
          -- Encode each ownership witness as a self-describing object.
          -- The TUI parses `status` to pick a badge color; `derivationPath`
          -- is present only for `.verified`, `derived` only for `.mismatch`.
          let ownershipJson :
              LeanCli.Ethereum.Ownership.Witness → Json :=
            fun w =>
              let base : List (String × Json) :=
                [("key", .str w.key),
                 ("address", .str w.address),
                 ("status", .str w.statusTag)]
              let withPath : List (String × Json) :=
                match w.derivationPath? with
                | some p => base ++ [("derivationPath", Json.str p)]
                | none   => base
              let full : List (String × Json) :=
                match w.derivedAddress? with
                | some d => withPath ++ [("derived", Json.str d)]
                | none   => withPath
              Json.obj full.toArray
          let regexJson : Json :=
            .obj #[
              ("action",     .str (LeanCli.Ethereum.Intent.Action.toString regex.action)),
              ("fields",     .arr (regex.fields.map (fun kv =>
                                Json.obj #[("k", .str kv.fst), ("v", .str kv.snd)])
                              |>.toArray)),
              ("unresolved", .arr (regex.unresolved.map Json.str |>.toArray)),
              ("confidence", .str (LeanCli.Ethereum.Intent.Confidence.toString regex.confidence)),
              ("ownerships", .arr (ownerships.map ownershipJson |>.toArray))
            ]
          -- Lean-derived base-units amounts this turn authorizes. The
          -- output re-check (`AmountGuard.revalidate`) admits a drafted
          -- magnitude only if it appears here — the same value the
          -- daemon published to the model as the `amt1` handle. Empty
          -- when the prompt carried no parseable amount, in which case a
          -- non-zero drafted value/amount is refused (fail-closed).
          let allowedBases : List Nat :=
            match regex.field? "amountBase" with
            | some s => match s.toNat? with
                        | some n => [n]
                        | none   => []
            | none => []
          -- 1b. Skill picker. For erc20Approve, we pick between the
          -- two sibling skills based on what the regex saw: a revoke
          -- verb or amount=0 → revoke-approval; otherwise the general
          -- approve-erc20. This stops the old picker from forcing
          -- legitimate "approve 100 USDC" prompts through the revoke
          -- gate (which by design rejects any amount but zero).
          --
          -- When the regex can't classify the action, fall through to
          -- a phrase scan for the four privacy/hygiene skills the
          -- RuleParser has no action tag for yet (shield-eth /
          -- unshield-eth / audit-approvals / fresh-address). The LLM
          -- becomes ADVICE-ONLY for these: IntentParser does not
          -- accept `shielded.*` / `approvals.*` / `address.fresh`
          -- output shapes, so the model's emitted intent is rejected
          -- by the validator and the user still has to act via the
          -- CLI commands listed in the skill body. The win is the
          -- model gets the skill context (anonymity-set caveats,
          -- denomination constraints, dust thresholds) instead of
          -- silently guessing.
          let actionTag := LeanCli.Ethereum.Intent.Action.toString regex.action
          let regexSawRevoke : Bool :=
            (regex.field? "revoke").isSome
              || (regex.field? "amount" = some "0")
              || (regex.field? "verb" = some "revoke")
              || (regex.field? "verb" = some "cancel")
              || (regex.field? "verb" = some "remove")
          let promptLower := prompt.toLower
          -- Parser-driven first (precise), phrase-scan fallback second.
          let skillName : String :=
            (skillForActionTag actionTag regexSawRevoke).getD
              (skillForPhrases promptLower)
          let skillBody? : Option String ←
            if skillName.isEmpty then pure none
            else LeanCli.Daemon.SkillsStore.readBody skillName
          -- 1c. Build a small chainContext object the model can read
          -- to resolve token symbols. The daemon already knows the
          -- addresses for chains we support; passing them removes the
          -- "I don't know the USDC contract" ask-loop. We only include
          -- tokens for the request's chain to keep context small.
          let chainEnumOpt : Option LeanCli.Swap.Tokens.ChainId :=
            match chainId with
            | 1 => some .mainnet
            | 11155111 => some .sepolia
            | _ => none
          let knownTokensJson : Json := match chainEnumOpt with
            | none => .arr #[]
            | some ce =>
                let tokens := LeanCli.Swap.Tokens.registry.filterMap (fun t =>
                  match LeanCli.Swap.Tokens.addressOn t ce with
                  | none => none
                  | some addr => some (Json.obj #[
                      ("symbol",   .str t.symbol),
                      ("address",  .str addr),
                      ("decimals", .num (Int.ofNat t.decimals)),
                      ("name",     .str t.name)
                    ]))
                .arr tokens.toArray
          -- Surface canonical protocol addresses the wallet already knows
          -- so the LLM never has to ask "what's the Aave Pool?". Every
          -- entry the model uses must round-trip back through
          -- Registry.KnownProtocols on the security-check side
          -- (LlmAgent.IntentParser already enforces this), so passing
          -- them in is information-disclosure only — not a new trust
          -- vector. The address book + token registry follow the same
          -- pattern.
          let knownProtocolsJson : Json := match chainEnumOpt with
            | none => .arr #[]
            | some ce =>
                let entries : List (String × String × Option String) := [
                  ("Aave V3 Pool", "aave",
                    LeanCli.Registry.KnownProtocols.aaveV3PoolFor ce),
                  ("Morpho Blue",  "morpho",
                    LeanCli.Registry.KnownProtocols.morphoBlueFor ce)
                ]
                let filled := entries.filterMap (fun e =>
                  match e.snd.snd with
                  | none      => none
                  | some addr => some (Json.obj #[
                      ("name",    .str e.fst),
                      ("alias",   .str e.snd.fst),
                      ("address", .str addr)
                    ]))
                .arr filled.toArray
          let chainContextJson : Json := .obj #[
            ("chainId",        .num (Int.ofNat chainId)),
            ("knownTokens",    knownTokensJson),
            ("knownProtocols", knownProtocolsJson)
          ]
          -- 1d. Build walletContext: what the daemon knows about the
          -- user's local wallets + their address-book. Putting this in
          -- the LLM context removes the "which wallet do you mean?"
          -- ask-loop entirely. We already gathered walletEntries +
          -- bookEntries above for the regex-side substitution; reuse.
          let defaultPath ← defaultAccountPathIO
          let defaultWallet? : Option String ←
            if ← defaultPath.pathExists then do
              let raw ← try IO.FS.readFile defaultPath catch _ => pure ""
              let trimmed := raw.trimAscii.toString
              pure (if trimmed.isEmpty then none else some trimmed)
            else pure none
          let walletsJson : Json :=
            .arr (walletEntries.map (fun kv => Json.obj #[
              ("name",    .str kv.fst),
              ("address", .str kv.snd.fst)
            ])).toArray
          let bookJson : Json :=
            .arr (book.map (fun e => Json.obj #[
              ("label",   .str e.label),
              ("address", .str e.address),
              ("source",  .str e.source)
            ])).toArray
          let walletContextJson : Json := .obj <| #[
            ("wallets",     walletsJson),
            ("addressBook", bookJson)
          ] ++ (match defaultWallet? with
                | some n => #[("defaultWallet", .str n)]
                | none   => #[])
          -- 1e. DirectSynth short-circuit (pure Lean, no LLM).
          -- When the regex pipeline has already produced everything an
          -- Intent needs — recipient resolved to a 0x address, asset
          -- resolved to a registry token, amountBase computed via
          -- parseUnits — synthesize the Intent in Lean and encode it
          -- directly. Skips the LLM round-trip entirely for the regular
          -- nativeTransfer / erc20Transfer / erc20Approve / revoke
          -- cases. Falls through to the LLM on .error (the model gets
          -- the same regex seed, chainContext, walletContext as before).
          --
          -- This is the load-bearing piece of the "wallet does the
          -- regular work, LLM does the complex work" split: simple txs
          -- never touch a model. Display + verification on the encoded
          -- bytes still goes through tx.decodeIntent (ERC-7730 +
          -- 4byte) and tx.simulate before any signature.
          -- Resolve the default wallet name to a 0x address (DirectSynth
          -- uses it as onBehalfOf for Aave supply and recipient for Aave
          -- withdraw). Falls back to none when no default is set or the
          -- name doesn't resolve in walletEntries.
          let defaultSenderAddr? : Option String :=
            match defaultWallet? with
            | none => none
            | some n =>
                let lower := n.toLower
                (walletEntries.find? (fun kv => kv.fst.toLower = lower)).map (fun e => e.snd.fst)
          -- When the user explicitly named a wallet via "from <slot>"
          -- (or the "using <slot>" synonym), the resolveLocal pass
          -- earlier in chat.draft has already rewritten the regex's
          -- `from` field to a 0x address. Honor that over the daemon's
          -- default wallet: the user just told us which wallet to sign
          -- with, and DirectSynth shouldn't reach past that. If the
          -- from-field is present but unresolved (raw slot name still),
          -- fall back to defaultSenderAddr? — DirectSynth would refuse
          -- a raw name via its parseAddr check anyway, but better to
          -- surface a clean wallet-direct path than to bail on a name
          -- the daemon already has the answer for.
          let isResolvedAddr (s : String) : Bool :=
            (s.startsWith "0x" || s.startsWith "0X") && s.length = 42
          let resolveWalletName? (s : String) : Option String :=
            let lower := s.toLower
            (walletEntries.find? (fun kv => kv.fst.toLower = lower)).map (fun e => e.snd.fst)
          let effectiveSenderAddr? : Option String :=
            match regex.field? "from" with
            | some s =>
                if isResolvedAddr s then some s
                else (resolveWalletName? s).orElse (fun _ => defaultSenderAddr?)
            | none   => defaultSenderAddr?
          let isAavePrepareAction : Bool :=
            (regex.action == LeanCli.Ethereum.Intent.Action.aaveSupply
              || regex.action == LeanCli.Ethereum.Intent.Action.aaveWithdraw
              || regex.action == LeanCli.Ethereum.Intent.Action.aaveBorrow
              || regex.action == LeanCli.Ethereum.Intent.Action.aaveRepay)
              && (regex.confidence != LeanCli.Ethereum.Intent.Confidence.rejected)
          let earlyReturn : Option Json :=
            if isAavePrepareAction then none
            else
              match LeanCli.LlmAgent.DirectSynth.synth regex chainId effectiveSenderAddr? with
              | .error _ => none
              | .ok intent =>
                  some <| chatDraftIntentResponse
                    intent
                    #[("regex", regexJson)]
                    (some "wallet-direct")
                    chainId
          match earlyReturn with
          | some j => return .ok j
          | none   => pure ()
          -- 1e-bis. Faucet mint short-circuit (no LLM; Sepolia only). The
          -- Aave test faucet mints its OWN reserve tokens, so the asset is
          -- resolved off the Aave reserve table (`resolveAsset`) — NOT the
          -- generic swap registry, whose Sepolia USDC/WETH are different
          -- contracts (Circle / WETH9) the faucet cannot mint. The amount
          -- uses the Aave token's own decimals. Mint recipient = signing
          -- wallet (honors `from <slot>`). Result is the standard `encoded`
          -- shape, so it flows through tx.simulate (which surfaces the
          -- per-tx mint cap as a revert) → ConfirmGate like any other tx.
          let faucetEarly : Option Json ←
            if regex.action != LeanCli.Ethereum.Intent.Action.faucetMint then pure none
            else if chainId != 11155111 then pure none  -- faucet is Sepolia-only
            else
              match regex.field? "asset", effectiveSenderAddr? with
              | some asset, some sender =>
                  match LeanCli.Aave.Prepare.resolveAsset asset .sepolia with
                  | some (some tok, tokenAddr) =>
                      match (regex.field? "amount").bind
                              (fun a => LeanCli.Util.Units.parseUnits a tok.decimals) with
                      | some amount =>
                          let data := LeanCli.Ethereum.Erc20.encodeFaucetMint tokenAddr sender amount
                          let human := LeanCli.Util.Units.formatUnits amount tok.decimals
                          pure <| some <| .obj #[
                            ("regex",           regexJson),
                            ("backend",         .str "wallet-direct-faucet"),
                            ("intentActionTag", .str "faucet.mint"),
                            ("canonical",
                              .str s!"Aave Sepolia faucet: mint {human} {tok.symbol} to {sender}"),
                            ("encoded", .obj #[
                              ("to",      .str "0xc959483dba39aa9e78757139af0e9a2edeb3f42d"),
                              ("value",   .str (natQuantityHex 0)),
                              ("data",    .str data),
                              ("chainId", .num (Int.ofNat chainId)),
                              ("sender",  .str sender)
                            ])
                          ]
                      | none => pure none
                  | _ => pure none
              | _, _ => pure none
          match faucetEarly with
          | some j => return .ok j
          | none   => pure ()
          -- 1f. Aave retail-action short-circuit (no LLM). The daemon's
          -- typed Aave prepare path resolves market reserves, checks the
          -- Pool support surface, performs allowance reads where needed,
          -- and preserves special cases such as native-ETH smart-account
          -- supply. Keeping withdraw/borrow/repay on this path avoids the
          -- generic leaf encoder producing a signable tx without those
          -- protocol checks or verb-specific user-facing labels.
          let aaveEarly : Option Json ← do
            let verb? : Option (String × String × String) :=
              if regex.action == LeanCli.Ethereum.Intent.Action.aaveSupply then
                some ("supply", "aaveV3Supply", "supply")
              else if regex.action == LeanCli.Ethereum.Intent.Action.aaveWithdraw then
                some ("withdraw", "aaveV3Withdraw", "withdraw")
              else if regex.action == LeanCli.Ethereum.Intent.Action.aaveBorrow then
                some ("borrow", "aaveV3Borrow", "borrow")
              else if regex.action == LeanCli.Ethereum.Intent.Action.aaveRepay then
                some ("repay", "aaveV3Repay", "repay")
              else if ((regex.field? "verb" == some "supply" || regex.field? "verb" == some "deposit")
                    && ((regex.field? "protocol").map (fun p => p.toLower.startsWith "aave")).getD false) then
                some ("supply", "aaveV3Supply", "supply")
              else none
            if !isAavePrepareAction && verb?.isNone then pure none
            else
              match verb?, effectiveSenderAddr?, regex.field? "asset", regex.field? "amountBase" with
              | some (verb, actionTag, noun), some sender, some asset, some amountBaseStr =>
                  match amountBaseStr.toNat? with
                  | none => pure none
                  | some amountBase =>
                    let chainName : Option String :=
                      if chainId = 1 then some "mainnet"
                      else if chainId = 11155111 then some "sepolia" else none
                    match endpointForChain cfg chainName with
                    | .error _ => pure none
                    | .ok ep =>
                      let shim : LeanCli.Aave.Prepare.ChainEthCallShim :=
                        fun to data cid => do
                          let via? ← verifiedReadVia state cid ep
                          match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep to data "latest" via? with
                          | .ok ret =>
                              match asString ret with
                              | some hex => pure (.ok hex)
                              | none     => pure (.error "non-string return from eth_call")
                          | .error e => pure (.error e)
                      let accountKind ← discoverAccountKind sender
                      let result ←
                        match verb with
                        | "supply" =>
                            if LeanCli.Aave.Prepare.isNativeEthInput asset then
                              if accountKind.isSmartWallet then
                                LeanCli.Aave.Prepare.prepareNativeEthSupplySmart
                                  chainId sender sender amountBase shim
                              else
                                pure (.err "native_eth_requires_wrap"
                                  "Aave V3 Pool accepts ERC-20 WETH, not native ETH. For an EOA, wrap ETH to WETH first, then supply WETH.")
                            else
                              LeanCli.Aave.Prepare.prepareSupply
                                chainId sender sender asset amountBase shim
                        | "withdraw" =>
                            LeanCli.Aave.Prepare.prepareWithdraw
                              chainId sender sender asset amountBase shim
                        | "borrow" =>
                            LeanCli.Aave.Prepare.prepareBorrow
                              chainId sender sender asset amountBase
                              LeanCli.Aave.V3Pool.InterestRateMode.variable shim
                        | "repay" =>
                            LeanCli.Aave.Prepare.prepareRepay
                              chainId sender sender asset amountBase
                              LeanCli.Aave.V3Pool.InterestRateMode.variable shim
                        | _ => pure (.err "unknown_action" s!"unknown Aave action: {verb}")
                      let finalResult :=
                        LeanCli.Aave.Prepare.maybeBatch sender chainId accountKind result
                      pure (some (aaveResultToDraftJson finalResult #[("regex", regexJson)] chainId sender actionTag noun))
              | _, _, _, _ => pure none
          match aaveEarly with
          | some j => return .ok j
          | none   =>
              let looksLikeAaveSupply :=
                ((regex.action == LeanCli.Ethereum.Intent.Action.aaveSupply)
                  || ((regex.field? "verb" == some "supply" || regex.field? "verb" == some "deposit")
                      && ((regex.field? "protocol").map (fun p => p.toLower.startsWith "aave")).getD false))
                  && (regex.confidence != LeanCli.Ethereum.Intent.Confidence.rejected)
              if looksLikeAaveSupply
                  && ((regex.field? "asset").map LeanCli.Aave.Prepare.isNativeEthInput).getD false
                  && (regex.field? "amountBase").isSome
                  && effectiveSenderAddr?.isNone then
                return .ok <| .obj #[
                  ("regex",   regexJson),
                  ("backend", .str "wallet-direct-aave"),
                  ("intentActionTag", .str "aaveV3Supply"),
                  ("canonical", .str "Aave supply not prepared (sender unresolved)"),
                  ("aaveError", .str "Could not resolve the wallet in the prompt to a local EOA or SPHINCS smart-account address. Check the slot name in `account.list`.")
                ]
              else pure ()
          -- 1g. Chain-aware swap short-circuit (no LLM). The regex already
          -- recognizes `swap <a> <X> to <Y>` (and the `with <name>` signing
          -- hint); here we COMPLETE the missing fields deterministically
          -- rather than hand the prompt to the agent — which free-plans and
          -- tends to draft a bare approve. Same engine as
          -- `swap.prepareUniswapV3`: on-chain QuoterV2 quote → minOut at the
          -- default-or-stated slippage, allowance read → approve leg when
          -- needed. Reads are policy-gated; the calldata still flows through
          -- tx.simulate → ConfirmGate. Falls back to the LLM only when the
          -- pre-quote inputs (sender / token / amount) don't parse.
          let swapEarly : Option Json ← do
            let isSwap :=
              (regex.action == LeanCli.Ethereum.Intent.Action.swap)
                && (regex.confidence != LeanCli.Ethereum.Intent.Confidence.rejected)
            if !isSwap then pure none
            else
              match effectiveSenderAddr?, regex.field? "amountIn",
                    regex.field? "tokenIn", regex.field? "tokenOut" with
              | some sender, some amtHuman, some tokenIn, some tokenOut =>
                  match decimalsForAsset tokenIn with
                  | none => pure none
                  | some d =>
                    match LeanCli.Util.Units.parseUnits amtHuman d with
                    | none => pure none
                    | some amountBase =>
                      let chainName : Option String :=
                        if chainId = 1 then some "mainnet"
                        else if chainId = 11155111 then some "sepolia" else none
                      match endpointForChain cfg chainName with
                      | .error _ => pure none
                      | .ok ep =>
                        let fee := (regex.field? "feeTier" >>= (·.toNat?)).getD 3000
                        let slippageBps? :=
                          (regex.field? "slippage") >>= parseSlippagePctToBps
                        let shim : LeanCli.Swap.Prepare.ChainEthCallShim :=
                          fun to data cid => do
                            let via? ← verifiedReadVia state cid ep
                            match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep to data "latest" via? with
                            | .ok ret =>
                                match asString ret with
                                | some hex => pure (.ok hex)
                                | none     => pure (.error "non-string return from eth_call")
                            | .error e => pure (.error e)
                        let request : LeanCli.Swap.Prepare.SwapRequest :=
                          { chainId            := chainId,
                            sender             := sender,
                            recipient          := sender,
                            tokenIn            := tokenIn,
                            tokenOut           := tokenOut,
                            amountIn           := amountBase,
                            fee                := fee,
                            slippageBps        := slippageBps?.getD 50,
                            slippageWasDefault := slippageBps?.isNone,
                            deadlineSeconds    := 1200 }
                        let result ← LeanCli.Swap.Prepare.prepareUniswapV3Swap request shim
                        pure (some (swapResultToDraftJson result #[("regex", regexJson)] chainId))
              | _, _, _, _ => pure none
          match swapEarly with
          | some j => return .ok j
          | none   => pure ()
          -- 1h. Atomic two-leg Aave batch for SPHINCS/smart accounts.
          -- This is intentionally deterministic and narrow: exactly two
          -- retail Aave legs joined by `and` / `then`, both prepared by the
          -- existing Aave prepare layer, then wrapped into one
          -- executeBatch frame. If any leg needs a separate approval or the
          -- sender is not a smart account, fall through to the hard
          -- clarification below instead of proposing a partial sequence.
          -- The atomic-batch path drafts an executeBatch for smart
          -- accounts, so the conjunction matcher's "please split" notes
          -- are stale here — strip them so the response is coherent.
          let regexJsonBatch := stripBatchSplitNotes regexJson
          let aaveBatchEarly : Option Json ← do
            match parseTwoAaveBatchLegs prompt with
            | none => pure none
            | some (legA, legB) =>
                let toks := LeanCli.LlmAgent.RuleParser.tokenize prompt
                let senderFromPrompt? : Option String :=
                  walletEntries.findSome? fun entry =>
                    let name := entry.fst.toLower
                    if toks.any (fun t => t = name) then
                      some entry.snd.fst
                    else none
                let sender? := senderFromPrompt? <|> effectiveSenderAddr?
                match sender? with
                | none => pure none
                | some sender =>
                    let accountKind ← discoverAccountKind sender
                    if !accountKind.isSmartWallet then
                      pure none
                    else
                      let chainName : Option String :=
                        if chainId = 1 then some "mainnet"
                        else if chainId = 11155111 then some "sepolia" else none
                      match endpointForChain cfg chainName with
                      | .error _ => pure none
                      | .ok ep =>
                          let shim : LeanCli.Aave.Prepare.ChainEthCallShim :=
                            fun to data cid => do
                              let via? ← verifiedReadVia state cid ep
                              match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep to data "latest" via? with
                              | .ok ret =>
                                  match asString ret with
                                  | some hex => pure (.ok hex)
                                  | none     => pure (.error "non-string return from eth_call")
                              | .error e => pure (.error e)
                          -- Each leg arrives as RAW frames (native-ETH
                          -- supply is wrap/approve/supply, not a
                          -- pre-collapsed executeBatch), so the single
                          -- batchTxFrames below produces a FLAT
                          -- executeBatch. A nested self-directed
                          -- executeBatch leg would revert on-chain:
                          -- that entry is EntryPoint-only.
                          let resultA ← prepareAaveBatchLegFrames chainId sender shim legA
                          let resultB ← prepareAaveBatchLegFrames chainId sender shim legB
                          match resultA, resultB with
                          | .ok (framesA, summaryA), .ok (framesB, summaryB) =>
                              let batched :=
                                LeanCli.Aave.Prepare.batchTxFrames
                                  sender chainId (framesA ++ framesB)
                              let summary :=
                                s!"Aave V3 atomic batch via SPHINCS executeBatch: 1) {summaryA}; 2) {summaryB}"
                              pure <| some <| .obj #[
                                ("regex",          regexJsonBatch),
                                ("backend",        .str "wallet-direct-aave-batch"),
                                ("intentActionTag", .str "executeBatch"),
                                ("canonical",       .str summary),
                                ("encoded",         aaveFrameEncoded batched chainId sender)
                              ]
                          | .error (kind, msg), _ =>
                              pure <| some <| .obj #[
                                ("regex",          regexJsonBatch),
                                ("backend",        .str "wallet-direct-aave-batch"),
                                ("intentActionTag", .str "executeBatch"),
                                ("canonical",       .str s!"Aave batch not prepared ({kind})"),
                                ("aaveError",       .str msg)
                              ]
                          | _, .error (kind, msg) =>
                              pure <| some <| .obj #[
                                ("regex",          regexJsonBatch),
                                ("backend",        .str "wallet-direct-aave-batch"),
                                ("intentActionTag", .str "executeBatch"),
                                ("canonical",       .str s!"Aave batch not prepared ({kind})"),
                                ("aaveError",       .str msg)
                              ]
          match aaveBatchEarly with
          | some j => return .ok j
          | none => pure ()
          -- 1f. Regex-clarification short-circuit. When the regex has
          -- already emitted a deliberate clarification in `unresolved`,
          -- the LLM has nothing to add. Calling it anyway can turn a
          -- safety note into an unsafe proposal.
          --
          -- This trips ONLY when:
          --   * action == .unknown
          --   * confidence == .rejected OR a `conjunction` field exists
          --   * unresolved is non-empty     (there IS a clarification to show)
          --
          -- The `conjunction` case is deliberately hard-gated even
          -- though RuleParser marks it `.medium`: multi-leg prompts like
          -- "withdraw X and borrow Y" must not be reduced to the first
          -- leg, nor reinterpreted by the model as two unordered drafts.
          -- Until a typed batch composer exists, the safe answer is to
          -- ask the user to split the request or use an explicit batch UI.
          --
          -- The response shape mirrors the wallet-direct path: just
          -- the regex draft, no `llmRaw`/`encoded`/`modelAsk`. The
          -- TUI's `llm:` line disappears; the `!` lines from
          -- `regex.unresolved` are the user-facing answer.
          let regexIsConjunctionClarification : Bool :=
            (regex.action == LeanCli.Ethereum.Intent.Action.unknown)
              && (regex.field? "conjunction").isSome
              && (regex.unresolved.length > 0)
          let regexIsClarification : Bool :=
            (regex.action == LeanCli.Ethereum.Intent.Action.unknown)
              && ((regex.confidence == LeanCli.Ethereum.Intent.Confidence.rejected)
                  || regexIsConjunctionClarification)
              && (regex.unresolved.length > 0)
          if regexIsClarification then
            let clarificationText :=
              String.intercalate " " regex.unresolved
            return .ok <| .obj #[
              ("regex",   regexJson),
              ("backend", .str "regex-clarification"),
              ("llmRaw",  .str clarificationText),
              ("modelAsk", .obj #[
                ("error",    .str "regex-clarification"),
                ("question", .str clarificationText)
              ])
            ]
          -- 2. Call LLM sidecar with the regex as a seed + the matching
          -- skill body + the chain's token registry. Forward the
          -- optional history field verbatim — the sidecar filters and
          -- caps it.
          let historyField : Array (String × Json) :=
            match getField "history" req.params with
            | some (j@(.arr _)) => #[("history", j)]
            | _ => #[]
          -- `activeChainId` is explicit so the agentd's prompt builder
          -- can pin the model's tool calls to a single chain. `chainId`
          -- is preserved for legacy sidecar callers that look only at
          -- the historical field name; the two MUST agree.
          -- Forward the TUI's opaque per-chat-open `sessionKey` to the
          -- agent bridge so the agentd's sticky-session cache is keyed
          -- by `(chainId, sessionKey)` instead of `chainId` alone. An
          -- absent/empty key collapses to the legacy
          -- single-sticky-session-per-chainId behavior — backward
          -- compatible for callers that have not yet plumbed it.
          -- Trust: opaque bookkeeping, never gates a signing decision.
          let sessionKey : String := paramStringD req.params "sessionKey" ""
          let llmReq : Json :=
            .obj <| #[
              ("prompt",        .str prompt),
              ("seed",          regexJson),
              ("chainId",       .num (Int.ofNat chainId)),
              ("activeChainId", .num (Int.ofNat chainId)),
              ("sessionKey",    .str sessionKey),
              ("chainContext",  chainContextJson),
              ("walletContext", walletContextJson),
              ("amounts",       amountsJson)
            ] ++ historyField ++ (match skillBody? with
                  | some body => #[("skillContext", .obj #[
                      ("name", .str skillName),
                      ("body", .str body)
                    ])]
                  | none => #[])
          let llmResp ← LeanCli.LlmAgent.Bridge.call
            { method := "llm.parseIntent", params := llmReq, id := 0 }
          match llmResp with
          | .err code msg _ =>
              pure <| .ok <| .obj #[
                ("regex", regexJson),
                ("llmError", .str s!"[{code}] {msg}")
              ]
          | .crash stderr _ =>
              pure <| .ok <| .obj #[
                ("regex", regexJson),
                ("llmError", .str s!"sidecar crash: {stderr}")
              ]
          | .ok llmResult =>
              -- Sidecar returned { raw, backend, model, trace? }. The
              -- optional `trace` is the agentd's per-turn observability
              -- payload — display-only for the most part, but it ALSO
              -- carries the canonical `propose_send` tool call when
              -- the agent reaches a final answer. When that's present
              -- it IS the intent; the prose `raw` text becomes purely
              -- informational. See `LeanCli/Agent/Trace.lean`.
              let rawStr :=
                (getField "raw" llmResult >>= asString).getD ""
              let traceField : Array (String × Json) :=
                match getField "trace" llmResult with
                | some t => #[("agentTrace", t)]
                | none   => #[]
              -- Precedence: if the trace shows the agent already
              -- emitted a `propose_send` tool call, hand the TUI an
              -- `encoded` payload directly — same shape as the
              -- IntentParser-built encoded leaf, so `latestSignable`
              -- in the TUI picks it up and the user gets a Sign +
              -- broadcast button. The model's final prose stays
              -- under `llmRaw` for context but is no longer the
              -- source of intent. Without this, the TUI surfaces
              -- the prose as a non-JSON ask and there's no way to
              -- confirm a tool-call-driven draft.
              -- `none` → no propose_send in trace (fall to IntentParser);
              -- `some (.error m)` → a propose_send whose magnitude the
              -- model chose rather than referenced (fail-closed reject);
              -- `some (.ok resp)` → a clean draft ready for the TUI.
              let proposeFromTrace : Option (Except String Json) :=
                match getField "trace" llmResult with
                | some t =>
                    match extractProposeSendFromTrace t with
                    | some ps =>
                      match LeanCli.LlmAgent.AmountGuard.revalidate ps.value ps.data allowedBases with
                      | .error m => some (.error m)
                      | .ok () =>
                        let senderEntry : Array (String × Json) :=
                          match ps.sender with
                          | some s => #[("sender", .str s)]
                          | none   => #[]
                        -- Decode the propose_send selector so the TUI's
                        -- chat-chip surfaces what the agent's calldata
                        -- actually does — e.g. "aaveV3Supply" — instead
                        -- of falling back to the regex's `.unknown` /
                        -- `.rejected` when the chat went through the
                        -- LLM. Unknown selectors get a coarse
                        -- "agent.rawCall" label that still beats
                        -- "unknown · regex=rejected".
                        let actionTag : String :=
                          (selectorToActionTag ps.data).getD "agent.rawCall"
                        some <| .ok <| .obj <| #[
                          ("regex",          regexJson),
                          ("llmRaw",         .str rawStr),
                          ("backend",        .str "agent-propose-send"),
                          ("intentActionTag",.str actionTag),
                          ("encoded", .obj <| #[
                            ("to",      .str ps.to),
                            -- 0x-quantity hex STRING (see encodeIntentResult);
                            -- a JSON number would lose wei precision >2^53 in
                            -- the TUI's JSON.parse before BigInt() runs.
                            ("value",   .str (natQuantityHex ps.value)),
                            ("data",    .str ps.data),
                            ("chainId", .num (Int.ofNat ps.chainId))
                          ] ++ senderEntry)
                        ] ++ traceField
                    | none => none
                | none => none
              match proposeFromTrace with
              | some (.ok resp) => pure (.ok resp)
              | some (.error m) =>
                  -- Magnitude the model chose, not referenced. Refuse the
                  -- draft outright rather than fall through to a re-draft.
                  pure <| .ok <| .obj <| #[
                    ("regex",         regexJson),
                    ("llmRaw",        .str rawStr),
                    ("validateError", .str m)
                  ] ++ traceField
              | none =>
              if rawStr.isEmpty then
                pure <| .ok <| .obj <| #[
                  ("regex", regexJson),
                  ("llmRaw", .str (LeanCli.Encoding.Json.compact llmResult)),
                  ("validateError", .str "llm.parseIntent returned no `raw` field (full sidecar response shown above)")
                ] ++ traceField
              else
                -- 3. Parse + validate via Lean's IntentParser. Three outcomes:
                --    .error msg          — malformed JSON / hard-reject
                --    .ok (.ask err q)    — model legitimately asked for clarification
                --    .ok (.intent i)     — ready to encode
                match LeanCli.LlmAgent.IntentParser.parseIntent rawStr chainId with
                | .error msg =>
                    pure <| .ok <| .obj <| #[
                      ("regex", regexJson),
                      ("llmRaw", .str rawStr),
                      ("validateError", .str msg)
                    ] ++ traceField
                | .ok (.ask err q) =>
                    pure <| .ok <| .obj <| #[
                      ("regex", regexJson),
                      ("llmRaw", .str rawStr),
                      ("modelAsk", .obj #[
                        ("error",    .str err),
                        ("question", .str q)
                      ])
                    ] ++ traceField
                | .ok (.intent intent) =>
                    -- 4. Route via chatDraftIntentResponse: leaf-encodable
                    -- variants get the `encoded` tx shape; the new
                    -- privacy/hygiene/wallet variants get a
                    -- `prepare`/`audit`/`create` directive instead.
                    -- We splice the agentTrace into the top-level obj
                    -- after `chatDraftIntentResponse` has built its
                    -- payload. Both the encoded-tx and directive
                    -- variants are objects, so the splice is safe.
                    let baseResp : Json := chatDraftIntentResponse
                      intent
                      #[("regex", regexJson), ("llmRaw", .str rawStr)]
                      none
                      chainId
                    let withTrace : Json :=
                      match baseResp, traceField with
                      | _, #[] => baseResp
                      | .obj fields, _ => .obj (fields ++ traceField)
                      | _, _ => baseResp
                    -- Same fail-closed amount re-check as the
                    -- propose_send path: the prose-JSON Intent could
                    -- carry a model-chosen amountWei.
                    match guardEncodedAmounts withTrace allowedBases with
                    | .ok okResp => pure (.ok okResp)
                    | .error m =>
                        pure <| .ok <| .obj <| #[
                          ("regex",         regexJson),
                          ("llmRaw",        .str rawStr),
                          ("validateError", .str m)
                        ] ++ traceField
      | .error msg, _ =>
          pure (.error msg)
      | _, none =>
          pure <| .error { code := -32602, message := "chat.draft: chainId (Nat) required", data := none }
  | "chat.rolloverSession" =>
      -- Explicit rotation of the agentd's sticky-chat cache entry for
      -- `(chainId, sessionKey)`. Wired to the TUI's `/clear` command:
      -- the TUI fires this best-effort, then mints a new sessionKey and
      -- clears its visible turns. The agentd closes the underlying
      -- session id (running `runExtraction` if the message floor is
      -- met) and drops the cache entry.
      --
      -- Idempotent: a missing entry succeeds with `closed:false`.
      -- Trust: this RPC produces no calldata and never gates a signing
      -- decision; ConfirmGate stays the trust anchor.
      match getField "chainId" req.params >>= asNat with
      | none =>
          pure <| .error { code := -32602
                         , message := "chat.rolloverSession: chainId (Nat) required"
                         , data := none }
      | some chainId =>
          let sessionKey : String := paramStringD req.params "sessionKey" ""
          let resp ← LeanCli.LlmAgent.Bridge.rolloverChatSession chainId sessionKey
          pure <| .ok <| LeanCli.LlmAgent.Bridge.responseToJson resp
  | "chat.listSessions" =>
      -- Read-only enumeration of the agentd's SQLite session store.
      -- Pure proxy — the agentd applies the `chainId` / `sessionKey`
      -- filters and the incognito mask; this RPC adds no business
      -- logic. Trust: produces no calldata, never gates a signing
      -- decision.
      let limit?   : Option Nat    := getField "limit" req.params >>= asNat
      let chainId? : Option Nat    := getField "chainId" req.params >>= asNat
      let key?     : Option String := getField "sessionKey" req.params >>= asString
      let resp ← LeanCli.LlmAgent.Bridge.listSessions limit? chainId? key?
      pure <| .ok <| LeanCli.LlmAgent.Bridge.responseToJson resp
  | "chat.getSession" =>
      -- Read-only fetch of one session's full transcript. Refuses
      -- incognito sessions with a structured `kind:"incognito"`
      -- envelope, surfaced verbatim via the bridge's `data.kind`. The
      -- TUI uses this to render a "no rows stored" notice rather than
      -- a transport error.
      match getField "session_id" req.params >>= asNat with
      | none =>
          pure <| .error { code := -32602
                         , message := "chat.getSession: session_id (Nat) required"
                         , data := none }
      | some sid =>
          let resp ← LeanCli.LlmAgent.Bridge.getSession sid
          pure <| .ok <| LeanCli.LlmAgent.Bridge.responseToJson resp
  | "chat.listProposedTxs" =>
      -- Read-only walk of every non-incognito session's tool-call log
      -- to extract `propose_send` invocations. The agentd does the
      -- extraction; this RPC is a pure proxy. Trust: the listed txs
      -- have already traversed (or failed to traverse) ConfirmGate at
      -- the time they were proposed; surfacing them here adds no new
      -- signing authority — re-executing requires a fresh decode →
      -- simulate → confirm cycle.
      let limit?   : Option Nat := getField "limit" req.params >>= asNat
      let chainId? : Option Nat := getField "chainId" req.params >>= asNat
      let resp ← LeanCli.LlmAgent.Bridge.listProposedTxs limit? chainId?
      pure <| .ok <| LeanCli.LlmAgent.Bridge.responseToJson resp
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.ChatRpc
