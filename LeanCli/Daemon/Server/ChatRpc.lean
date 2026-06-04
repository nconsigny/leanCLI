import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.AddressBook
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.SkillsStore
import LeanCli.Daemon.State
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Ens
import LeanCli.Ethereum.Intent
import LeanCli.Ethereum.IntentCanonical
import LeanCli.Ethereum.IntentEncode
import LeanCli.Ethereum.IntentJson
import LeanCli.Ethereum.Ownership
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.Wallet.EoaStore
import LeanCli.LlmAgent.Bridge
import LeanCli.LlmAgent.DirectSynth
import LeanCli.LlmAgent.IntentParser
import LeanCli.LlmAgent.RuleParser
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
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
* `address.fresh`     → `create  = {rpc: "eoa.create"|"tpm.create",  …}`

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
      -- The bridge sidecar generates the spending note + Pedersen-
      -- hashed commitment and returns deposit calldata. PR 2 ships
      -- the sidecar as a stub; the user sees a clear "Tornado SDK
      -- not yet integrated" error in the TUI until snarkjs + Baby
      -- Jubjub Pedersen lands.
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
  | .tornadoWithdraw _ denominationWei recipient note =>
      -- Tornado withdraw: route to `shielded.tornado.prepareWithdraw`.
      -- The bridge sidecar consumes the saved deposit note, fetches
      -- the pool's current merkle state, generates the ZK proof, and
      -- returns withdraw calldata. Same stub status as deposit until
      -- the sidecar lands.
      let amountEth := LeanCli.Util.Units.formatUnits denominationWei 18
      .obj <| commonFields ++ #[
        ("prepare", .obj #[
          ("rpc",    .str "shielded.tornado.prepareWithdraw"),
          ("params", .obj #[
            ("amountEth", .str amountEth),
            ("recipient", addrJson recipient),
            ("note",      .str note),
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
        | .r1  => "tpm.create"
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
                        let viaEns? ← colibriVia state 1
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
          -- derivable) and `none` for TPM/R1 entries (hardware-bound,
          -- not re-derivable). See Invariants/AddressOwnership.lean for
          -- the safety proof.
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
          let tpmNames ← listSepoliaKeys
          let tpmStateDir : System.FilePath := ".leancli/keystore/tpm2"
          for name in tpmNames do
            let addrFile := tpmStateDir / name / "r1-account-address.txt"
            if ← addrFile.pathExists then
              let raw ← IO.FS.readFile addrFile
              let addr := raw.trimAscii.toString
              if !addr.isEmpty then
                walletEntries := walletEntries ++ [(name, addr, none)]
          let bookEntries ← LeanCli.Daemon.AddressBook.loadIO
          let book := match bookEntries with
            | .ok xs => xs
            | .error _ => []
          -- Per-entry ownership status. EOA + unlocked → re-derive and
          -- compare; EOA + locked → `.locked`; TPM → `.hardware`. The
          -- only branch that emits `.verified` performs the actual
          -- `deriveAddressFromSeed` and structurally compares
          -- (invariant 14.1).
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
          let ownerships : List LeanCli.Ethereum.Ownership.Witness :=
            [w_to, w_spender, w_from].filterMap id
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
          let regex := match regex5.field? "amount", regex5.field? "asset" with
            | some amt, some asset =>
                match decimalsForAsset asset with
                | none => regex5
                | some d =>
                    match LeanCli.Util.Units.parseUnits amt d with
                    | some n =>
                        (regex5.setField "amountBase" (toString n)).note
                          s!"parseUnits {amt} {d} = {n} ({asset})"
                    | none => regex5.note s!"could not parseUnits {amt} with decimals {d}"
            | _, _ => regex5
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
          let containsAny (needles : List String) : Bool :=
            needles.any (fun n => (promptLower.splitOn n).length > 1)
          let skillName : String :=
            match actionTag with
            | "nativeTransfer"    => "send-native"
            | "erc20Transfer"     => "send-erc20"
            | "erc20Approve"      =>
                if regexSawRevoke then "revoke-approval" else "approve-erc20"
            -- New explicit action tags from matchShielded /
            -- matchAuditApprovals / matchFreshAddress. The phrase-
            -- fallback below remains as a safety net for aliased
            -- forms the templates don't cover (e.g. "make this
            -- anonymous").
            | "shielded.deposit"  => "shield-eth"
            | "shielded.withdraw" => "unshield-eth"
            -- Railgun chat shortcut (PR 1). Both shield/unshield share
            -- the `railgun` skill so the model sees the SDK-specific
            -- guidance (paymaster, POI delay, viewing keys) when it
            -- needs to clarify post-DirectSynth.
            | "shielded.railgun.shield"   => "railgun"
            | "shielded.railgun.unshield" => "railgun"
            -- Tornado Cash chat shortcut (PR 2). Same skill for both
            -- legs; the skill body covers the fixed-denomination
            -- constraint + the note-handling caveats.
            | "shielded.tornado.deposit"  => "tornado-cash"
            | "shielded.tornado.withdraw" => "tornado-cash"
            | "approvals.audit"   => "audit-approvals"
            | "address.fresh"     => "fresh-address"
            | "swap"              => "swap-uniswap-v3"
            | _                   =>
                -- Order tightest-first: "unshield" before "shield " to
                -- keep the prefix collision off; rotate/fresh phrases
                -- are kept specific so generic "send to a new address"
                -- doesn't get hijacked into fresh-address.
                if containsAny ["unshield", "withdraw from privacy",
                                "exit privacy pool", "exit the privacy pool"] then
                  "unshield-eth"
                else if containsAny ["shield ", "privacy pool", "privacy-pool",
                                     "make this private", "make it private",
                                     "make this anonymous", "deposit privately"] then
                  "shield-eth"
                else if containsAny ["audit approvals", "list approvals",
                                     "show approvals", "show my approvals",
                                     "what have i approved", "list allowances",
                                     "current allowances", "outgoing approvals"] then
                  "audit-approvals"
                else if containsAny ["fresh address", "fresh wallet",
                                     "rotate identity", "rotate to a new",
                                     "new identity", "generate a new wallet",
                                     "generate a fresh"] then
                  "fresh-address"
                else ""
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
          let effectiveSenderAddr? : Option String :=
            match regex.field? "from" with
            | some s => if isResolvedAddr s then some s else defaultSenderAddr?
            | none   => defaultSenderAddr?
          let earlyReturn : Option Json :=
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
          -- 1f. Regex-clarification short-circuit. When the regex has
          -- already emitted a deliberate `.rejected` draft with a
          -- complete user-facing clarification in `unresolved` (e.g.
          -- `shield X with railgun` → "coming soon — use Privacy
          -- menu"), the LLM has nothing to add. Calling it anyway
          -- burns 30s of tool chains and ends in `http timeout`,
          -- which the user sees as a confusing red error line under
          -- the perfectly good regex answer.
          --
          -- This trips ONLY when:
          --   * action == .unknown          (regex chose to reject)
          --   * confidence == .rejected     (intentional, not a fallthrough)
          --   * unresolved is non-empty     (there IS a clarification to show)
          --
          -- The response shape mirrors the wallet-direct path: just
          -- the regex draft, no `llmRaw`/`encoded`/`modelAsk`. The
          -- TUI's `llm:` line disappears; the `!` lines from
          -- `regex.unresolved` are the user-facing answer.
          let regexIsClarification : Bool :=
            (regex.action == LeanCli.Ethereum.Intent.Action.unknown)
              && (regex.confidence == LeanCli.Ethereum.Intent.Confidence.rejected)
              && (regex.unresolved.length > 0)
          if regexIsClarification then
            return .ok <| .obj #[
              ("regex",   regexJson),
              ("backend", .str "regex-clarification")
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
              ("walletContext", walletContextJson)
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
              let proposeFromTrace : Option Json :=
                match getField "trace" llmResult with
                | some t =>
                    match extractProposeSendFromTrace t with
                    | some ps =>
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
                        some <| .obj <| #[
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
              | some resp => pure (.ok resp)
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
                    pure <| .ok withTrace
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
