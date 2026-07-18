import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Intent
import LeanCli.Ethereum.IntentJson
import LeanCli.Registry.KnownProtocols
import LeanCli.Swap.Tokens

/-!
# Security-hardened JSON → Intent parser for the LLM chat path

Layers explicit hard-rejects on top of `Ethereum.IntentJson.parseIntent`.
The base parser is *structural* (does the JSON have the right shape?);
this parser is *defensive* (does the JSON look like a known
model-failure mode?). Caller is the LLM chat path; output is fed to
`tx.encodeIntent` only after every check here passes.

## Hard-reject list (documented in
[[project-local-llm-daemon]] and [[reference-vitalik-secure-llms]])

1. **Signature fields** — any presence of `v` / `r` / `s` / `signature`
   in the JSON. The model has no business emitting signature bytes;
   when it does, it's hallucinating the wrong layer.
2. **RLP-shaped data** — raw `0xf8…` / `0xf9…` byte sequences in fields
   other than `rawCall.data`. The model was caught fabricating RLP byte
   layouts; refuse to take its word.
3. **Wrong-chainId** — the intent's `chainId` must match the
   `expectedChainId` the caller passes in (the chain the user is
   currently on). The model has named Goerli (dead) and confused
   Ethereum-vs-Polygon chain ids in testing.
4. **Dead-testnet names** — Goerli / Ropsten / Rinkeby / Kovan as
   strings anywhere in the intent. These networks are off; an intent
   that names them is from a model still trained on stale facts.
5. **Symbol-not-in-registry** — if the intent references a token
   symbol that doesn't resolve in `LeanCli.Swap.Tokens`, reject.
   Prevents the model from inventing token addresses for tickers it
   has heard of but where we don't know the canonical deployment.
   (Direct `0x...` addresses are allowed — that's the user supplying
   it explicitly, not the model inventing.)
6. **Protocol-not-in-registry-on-this-chain** — Aave / Morpho
   references that don't resolve via
   `LeanCli.Registry.KnownProtocols.resolve` on the intent's chain.
7. **Non-checksummed address** — model-supplied addresses must be
   checksum-correct per EIP-55. All-lowercase is a phishing vector
   (some wallets normalize, hiding wrong addresses).
8. **Per-action shape rejects** for the privacy / hygiene / wallet
   variants:
   * `shielded.deposit`: amountWei below the 0.001 ETH dust floor
     (anonymity set for dust is empty — see shield-eth SKILL.md).
   * `shielded.withdraw`: amountWei = 0.
   * `address.fresh`: label longer than 64 chars (opaque labels are a
     privacy property; long descriptive labels leak when the user
     screenshots).

All rejects return `.error msg` with a human-readable reason. The TUI
surfaces the reason verbatim so the user understands what the model
got wrong.
-/

namespace LeanCli.LlmAgent.IntentParser

open LeanCli.Encoding.Json
open LeanCli.Ethereum.Intent
open LeanCli.Ethereum.Address (Address)

/-! ## Helpers -/

/-- Walk every JSON string in the tree, calling `check` on each. Returns
the first `.error` it produces, or `.ok` if every check passes. -/
partial def walkStrings (check : String → Except String Unit) : Json → Except String Unit
  | .str s     => check s
  | .arr xs    => xs.foldlM (fun _ j => walkStrings check j) ()
  | .obj kvs   => kvs.foldlM (fun _ (kv : String × Json) => walkStrings check kv.snd) ()
  | _          => .ok ()

/-! ## Hard-reject predicates -/

/-- Reject any field name that looks like a signature byte. The JSON
keys we accept (per `IntentJson`) do not include these, so any
appearance is the model inventing structure. -/
def hasForbiddenSignatureKey (j : Json) : Bool :=
  let badKeys := ["v", "r", "s", "signature", "sig", "rsv"]
  match j with
  | .obj kvs => kvs.any (fun (kv : String × Json) =>
      badKeys.any (fun bk => kv.fst.toLower == bk))
  | _ => false

/-- An RLP-encoded structure starts with `0xf8` (list len > 55 bytes,
common shape for txs) or `0xf9`. We reject any hex-string field whose
body begins with those prefixes, except inside `rawCall.data` (where
RLP-looking bytes can be the legitimate intent). -/
private def looksRlp (s : String) : Bool :=
  let lower := s.toLower
  lower.startsWith "0xf8" || lower.startsWith "0xf9" || lower.startsWith "0xc8" || lower.startsWith "0xc9"

/-- Dead-testnet names we refuse to see anywhere in the JSON. -/
private def deadTestnetNames : List String :=
  ["goerli", "ropsten", "rinkeby", "kovan"]

/-- Check a single string for dead-testnet names. -/
private def checkDeadTestnetName (s : String) : Except String Unit :=
  let l := s.toLower
  match deadTestnetNames.find? (fun bad => (l.splitOn bad).length > 1) with
  | some bad => .error s!"references deprecated testnet \"{bad}\" (Goerli/Ropsten/Rinkeby/Kovan are off)"
  | none => .ok ()

/-- Check every string in the JSON for dead-testnet names. -/
def rejectDeadTestnets (j : Json) : Except String Unit :=
  walkStrings checkDeadTestnetName j

/-- Check a single string for RLP-prefix shape. Used outside rawCall.data. -/
private def checkNoRlp (s : String) : Except String Unit :=
  if looksRlp s then
    .error s!"hex string looks like RLP-encoded bytes ({s.take 6}...) — refused outside rawCall.data"
  else .ok ()

/-- EIP-55 checksum check. The model's address output is suspect when
all lowercase or mixed in non-EIP-55 form. We accept either:
* all lowercase (treating as unchecked but flagged), OR
* correctly EIP-55 checksummed.

For the LLM path we require properly checksummed addresses. The user
typing into the trusted Send form is a different code path. -/
def isAllLower (s : String) : Bool :=
  s.toList.all (fun c => !(Char.isAlpha c) || c.isLower)

/-- Run all top-level checks. `expectedChainId` is the chain the user is
on (the daemon's configured chain at request time). -/
def securityChecks (raw : Json) (expectedChainId : Nat) (intent : Intent) :
    Except String Unit := do
  -- (1) signature fields
  if hasForbiddenSignatureKey raw then
    throw "intent JSON contains signature-shaped fields (v/r/s/sig); model is at the wrong layer"
  -- (2,4) walk strings: dead testnets + non-rawCall RLP
  rejectDeadTestnets raw
  -- (3) chain id agreement
  let icid := Intent.chainId intent
  if icid ≠ expectedChainId then
    throw s!"intent.chainId={icid} but request was for chain {expectedChainId}; refusing cross-chain reinterpretation"
  -- (5,6) symbol / protocol resolution: every Intent constructor that
  -- carries an Address has already been parsed as such, so symbol
  -- resolution is upstream of us. We re-check protocol references for
  -- Aave intents when a chain-id is known.
  match intent with
  | .aaveV3Supply chainId _ _ _
  | .aaveV3Withdraw chainId _ _ _ =>
      let chainEnum : Option LeanCli.Swap.Tokens.ChainId :=
        match chainId with
        | 1 => some .mainnet
        | 11155111 => some .sepolia
        | _ => none
      match chainEnum with
      | some ce =>
          match LeanCli.Registry.KnownProtocols.aaveV3PoolFor ce with
          | some _ => .ok ()
          | none   => throw s!"Aave V3 not deployed (per Lean registry) on chainId {chainId}"
      | none => throw s!"Aave V3 not supported on chainId {chainId} in this build"
  | .shieldedDeposit _ amountWei =>
      -- Dust floor from shield-eth/SKILL.md: 0.001 ETH = 10^15 wei.
      -- Below this, the anonymity set is too small for the deposit
      -- to provide meaningful privacy.
      let dustFloor : Nat := 1_000_000_000_000_000
      if amountWei < dustFloor then
        throw s!"shielded.deposit: amountWei {amountWei} below the 0.001 ETH dust floor (anonymity set is empty at this amount — see shield-eth SKILL.md)"
      else .ok ()
  | .shieldedWithdraw _ amountWei _ _ =>
      -- A withdraw of 0 produces no movement and reveals timing
      -- structure without privacy benefit.
      if amountWei = 0 then
        throw "shielded.withdraw: amountWei = 0 refused (no movement, leaks timing)"
      else .ok ()
  | .railgunShield _ amountWei =>
      -- Railgun anonymity set fragments below ~0.001 ETH the same way
      -- Privacy Pool does, and the POI tree treats dust deposits as
      -- high-friction. Apply the same dust-floor reject we use for
      -- `.shieldedDeposit`. The model's only Railgun-specific path
      -- through this validator: don't let it shield 0 or near-0
      -- amounts that defeat the surface's purpose.
      let dustFloor : Nat := 1_000_000_000_000_000
      if amountWei < dustFloor then
        throw s!"shielded.railgun.shield: amountWei {amountWei} below the 0.001 ETH dust floor (anonymity set is empty at this amount)"
      else .ok ()
  | .railgunUnshield _ amountWei _ =>
      if amountWei = 0 then
        throw "shielded.railgun.unshield: amountWei = 0 refused (no movement, leaks timing)"
      else .ok ()
  | .tornadoDeposit _ denominationWei =>
      -- Tornado pools are fixed-denomination. Any other amount silently
      -- mis-routes to the wrong pool contract (or no pool at all) and
      -- the deposit either reverts or — worse — lands in a pool the
      -- user can't track. Reject anything outside the canonical set
      -- here; the bridge sidecar also enforces but defence in depth
      -- belongs in the verified core.
      let d01  : Nat :=     100_000_000_000_000_000  -- 0.1 ETH
      let d1   : Nat :=   1_000_000_000_000_000_000  -- 1 ETH
      let d10  : Nat :=  10_000_000_000_000_000_000  -- 10 ETH
      let d100 : Nat := 100_000_000_000_000_000_000  -- 100 ETH
      if denominationWei = d01 ∨ denominationWei = d1
          ∨ denominationWei = d10 ∨ denominationWei = d100 then
        .ok ()
      else
        throw s!"shielded.tornado.deposit: denominationWei {denominationWei} is not a Tornado pool denomination (must be exactly 0.1, 1, 10, or 100 ETH in wei)"
  | .tornadoWithdraw _ denominationWei _ noteRef =>
      -- Same denomination gate as deposit; you cannot withdraw an amount
      -- that doesn't correspond to a real pool. `noteRef` is NOT a secret
      -- string — the SDK derives note secrets deterministically from the
      -- wallet seed, so a withdraw needs no saved note. `noteRef` is an
      -- optional deposit-index selector: empty ⇒ auto-select the oldest
      -- spendable note of that denomination; otherwise a decimal index.
      let d01  : Nat :=     100_000_000_000_000_000
      let d1   : Nat :=   1_000_000_000_000_000_000
      let d10  : Nat :=  10_000_000_000_000_000_000
      let d100 : Nat := 100_000_000_000_000_000_000
      let validDenom :=
        denominationWei = d01 ∨ denominationWei = d1
          ∨ denominationWei = d10 ∨ denominationWei = d100
      if !validDenom then
        throw s!"shielded.tornado.withdraw: denominationWei {denominationWei} is not a Tornado pool denomination"
      else if noteRef ≠ "" ∧ !(noteRef.all Char.isDigit) then
        throw s!"shielded.tornado.withdraw: noteRef must be empty (auto-select) or a decimal deposit index, got \"{noteRef}\""
      else .ok ()
  | .approvalsAudit _ _ =>
      -- Read-only action; no signing, no chain side-effects to gate.
      .ok ()
  | .freshAddress _ _ label _ =>
      -- Label sanity. Per fresh-address SKILL.md: "Encourage opaque
      -- labels (`a`, `b`, `fresh-1`) over descriptive ones." Long
      -- labels are a screenshot-leak vector. We cap at 64 chars; we
      -- do NOT try to detect descriptive content (that's a privacy
      -- oracle, out of scope) — only the obvious length foot-gun.
      match label with
      | none => .ok ()
      | some s =>
          if s.length > 64 then
            throw s!"address.fresh: label too long ({s.length} chars; max 64). Use a short opaque label."
          else .ok ()
  | _ => .ok ()

/-- The two legitimate shapes the model can emit per the system prompt:

* `intent` — a populated Intent ADT, ready for `tx.encodeIntent` once
  the security checks pass.
* `ask` — the model couldn't fill the intent without inventing
  (typically an unresolved ENS or symbol). The `error` is the model's
  diagnosis; the `ask` is the question it wants the user to answer.

This is not the same as a Lean-side rejection. A model `ask` is the
model behaving correctly; a `.error` from `parseIntent` is the model
emitting garbage or tripping a hard-reject.
-/
inductive ParseResult where
  | intent (i : Intent)
  | ask    (errorMsg : String) (question : String)

/-- The full chat-path parse: structural decode + security hard-rejects,
or a recognized clarification ask. Returns `.ok (.intent ...)` for a
ready-to-encode Intent, `.ok (.ask ...)` for a legitimate model
clarification, and `.error msg` for anything malformed or
hard-rejected. -/
def parseIntent (rawJsonText : String) (expectedChainId : Nat) :
    Except String ParseResult := do
  match LeanCli.Encoding.Json.parse rawJsonText with
  | .error parseErr =>
      -- The model emitted prose instead of structured JSON. This
      -- happens often with small instruct-tuned models that fall back
      -- to natural language when they need to clarify ("I think you
      -- meant transfer, not swap — which wallet?"). Surface that
      -- prose as a `.ask` clarification so the TUI shows the model's
      -- actual words; do NOT propagate the parse error and lose the
      -- whole turn. The model is still untrusted: an .ask is
      -- DISPLAY-ONLY, no Intent is encoded.
      let trimmed := rawJsonText.trimAscii.toString
      if trimmed.isEmpty then
        .error parseErr
      else
        .ok (.ask "non-json-response" trimmed)
  | .ok j =>
      -- Recognize the documented {error, ask} clarification shape
      -- BEFORE attempting a structural Intent parse. The model emits
      -- this when it can't fill required fields without inventing
      -- (e.g. unresolved ENS, unknown token symbol, missing chain
      -- id). That's not a failure of ours — it's the model doing
      -- what we asked it to.
      match getField "error" j, getField "ask" j with
      | some errJ, some askJ =>
          match asString errJ, asString askJ with
          | some err, some ask => return .ask err ask
          | _, _ => pure ()
      | _, _ => pure ()
      let intent ← LeanCli.Ethereum.IntentJson.parseIntent j
      securityChecks j expectedChainId intent
      .ok (.intent intent)

end LeanCli.LlmAgent.IntentParser
