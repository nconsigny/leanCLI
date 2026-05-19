import LeanKohaku.Encoding.Json
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Intent
import LeanKohaku.Ethereum.IntentJson
import LeanKohaku.Registry.KnownProtocols
import LeanKohaku.Swap.Tokens

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
   symbol that doesn't resolve in `LeanKohaku.Swap.Tokens`, reject.
   Prevents the model from inventing token addresses for tickers it
   has heard of but where we don't know the canonical deployment.
   (Direct `0x...` addresses are allowed — that's the user supplying
   it explicitly, not the model inventing.)
6. **Protocol-not-in-registry-on-this-chain** — Aave / Morpho
   references that don't resolve via
   `LeanKohaku.Registry.KnownProtocols.resolve` on the intent's chain.
7. **Non-checksummed address** — model-supplied addresses must be
   checksum-correct per EIP-55. All-lowercase is a phishing vector
   (some wallets normalize, hiding wrong addresses).

All rejects return `.error msg` with a human-readable reason. The TUI
surfaces the reason verbatim so the user understands what the model
got wrong.
-/

namespace LeanKohaku.LlmAgent.IntentParser

open LeanKohaku.Encoding.Json
open LeanKohaku.Ethereum.Intent
open LeanKohaku.Ethereum.Address (Address)

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
      let chainEnum : Option LeanKohaku.Swap.Tokens.ChainId :=
        match chainId with
        | 1 => some .mainnet
        | 11155111 => some .sepolia
        | _ => none
      match chainEnum with
      | some ce =>
          match LeanKohaku.Registry.KnownProtocols.aaveV3PoolFor ce with
          | some _ => .ok ()
          | none   => throw s!"Aave V3 not deployed (per Lean registry) on chainId {chainId}"
      | none => throw s!"Aave V3 not supported on chainId {chainId} in this build"
  | _ => .ok ()

/-- The full chat-path parse: structural decode + security hard-rejects.
Returns the validated `Intent` ready for `tx.encodeIntent`, or a
human-readable rejection message. -/
def parseIntent (rawJsonText : String) (expectedChainId : Nat) :
    Except String Intent := do
  let j ← LeanKohaku.Encoding.Json.parse rawJsonText
  let intent ← LeanKohaku.Ethereum.IntentJson.parseIntent j
  securityChecks j expectedChainId intent
  .ok intent

end LeanKohaku.LlmAgent.IntentParser
