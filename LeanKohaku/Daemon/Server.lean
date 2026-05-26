import LeanKohaku.Basic
import LeanKohaku.Daemon.AddressBook
import LeanKohaku.Daemon.LlmServer
import LeanKohaku.Daemon.Log
import LeanKohaku.Daemon.SkillsStore
import LeanKohaku.Daemon.State
import LeanKohaku.Daemon.Status
import LeanKohaku.Daemon.PpDestinations
import LeanKohaku.Daemon.TxJournal
import LeanKohaku.Daemon.Uds
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.Privacy.Bridge
import LeanKohaku.Clearsign.Bridge
import LeanKohaku.Sphincs.Bridge
import LeanKohaku.Sphincs.UserOp
import LeanKohaku.Sphincs.Send
import LeanKohaku.Colibri.Bridge
import LeanKohaku.Colibri.Persistent
import LeanKohaku.Helios.Bridge
import LeanKohaku.Helios.Persistent
import LeanKohaku.Daemon.Preflight
import LeanKohaku.Daemon.TokenMeta
import LeanKohaku.Daemon.EnsNames
import LeanKohaku.LlmAgent.Bridge
import LeanKohaku.LlmAgent.DirectSynth
import LeanKohaku.LlmAgent.IntentParser
import LeanKohaku.LlmAgent.RuleParser
import LeanKohaku.Cli.Commands
import LeanKohaku.Cli.NetworkConfig
import LeanKohaku.RPC.Outbound
import LeanKohaku.RPC.Server
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Eip712
import LeanKohaku.Ethereum.Ens
import LeanKohaku.Ethereum.Intent
import LeanKohaku.Ethereum.IntentCanonical
import LeanKohaku.Ethereum.IntentEncode
import LeanKohaku.Ethereum.IntentJson
import LeanKohaku.Ethereum.Ownership
import LeanKohaku.Ethereum.Tx
import LeanKohaku.Keystore.Tpm2Runtime
import LeanKohaku.Keystore.MasterKey
import LeanKohaku.Keystore.MasterPassphrase
import LeanKohaku.Wallet.Address
import LeanKohaku.Wallet.Bip44
import LeanKohaku.Wallet.EoaStore
import LeanKohaku.Wallet.Entropy
import LeanKohaku.Wallet.EOA
import LeanKohaku.Wallet.HDKey
import LeanKohaku.Wallet.Mnemonic
import LeanKohaku.Wallet.PpSecretStore
import LeanKohaku.Wallet.RgSecretStore
import LeanKohaku.Wallet.SphincsHybridStore
import LeanKohaku.Registry.KnownProtocols
import LeanKohaku.Swap.Tokens
import LeanKohaku.Swap.UniV3
import LeanKohaku.Swap.Prepare
import LeanKohaku.Aave.Prepare
import LeanKohaku.Util.Units
import LeanKohaku.Invariants.Swap

/-!
# Daemon server

Long-running process that exposes wallet operations over a local socket.
The daemon is the only component allowed to perform Ethereum node I/O, and
every attempted connection must pass `Privacy.NetworkPolicy`.
-/

namespace LeanKohaku.Daemon.Server

open LeanKohaku.Encoding.Json
open LeanKohaku.Keystore.Tpm2Runtime
open LeanKohaku.Wallet.Account
open LeanKohaku.Privacy.NetworkPolicy
open LeanKohaku.RPC.Server

def defaultDerivationPath : String := "m/44'/60'/0'/0/0"

/-- Resolve the default-account file path, owned by the daemon (CLI is a
    thin forwarder). Honors `XDG_CONFIG_HOME`, falls back to `~/.config`,
    finally `.` for testing without `HOME`. Same semantics the CLI used to
    implement directly. -/
private def defaultAccountPathIO : IO System.FilePath := do
  let dir : System.FilePath ← match ← IO.getEnv "XDG_CONFIG_HOME" with
    | some d => pure (System.FilePath.mk d)
    | none =>
        match ← IO.getEnv "HOME" with
        | some h => pure (System.FilePath.mk h / ".config")
        | none => pure (System.FilePath.mk ".")
  pure (dir / "leankohaku" / "default-account.txt")

/-- Decode a `0x`-prefixed hex string into `Nat`. Returns `none` on any
    non-hex character. Used to humanize hex receipt fields for the text
    summary; the wire JSON keeps raw hex. -/
private def hexNat? (s : String) : Option Nat :=
  let chars := s.toList
  let body :=
    match chars with
    | '0' :: 'x' :: rest => rest
    | '0' :: 'X' :: rest => rest
    | _ => chars
  if body.isEmpty then none
  else
    body.foldl (init := some 0) fun acc c =>
      match acc, LeanKohaku.Crypto.Hex.hexDigit? c with
      | some n, some d => some (n * 16 + d.toNat)
      | _, _ => none

private def formatGweiNat (n : Nat) : String :=
  let whole := n / 1000000000
  let frac := n % 1000000000
  if frac = 0 then s!"{whole} gwei"
  else
    let str := toString frac
    let pad := String.ofList (List.replicate (9 - str.length) '0')
    let trimmed := ((pad ++ str).dropEndWhile (· = '0')).toString
    s!"{whole}.{trimmed} gwei"

private def formatEthNat (n : Nat) : String :=
  let whole := n / 1000000000000000000
  let frac := n % 1000000000000000000
  if frac = 0 then s!"{whole} ETH"
  else
    let str := toString frac
    let pad := String.ofList (List.replicate (18 - str.length) '0')
    let trimmed := ((pad ++ str).dropEndWhile (· = '0')).toString
    s!"{whole}.{trimmed} ETH"

private def humanEth (weiNat : Nat) : String :=
  s!"{formatEthNat weiNat}  ({weiNat} wei)"

/-- Render a hex-encoded wei amount as gwei, falling back to the raw hex
    if decode fails (so a malformed receipt never produces an empty field). -/
private def humanGwei (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{formatGweiNat n}  ({hex})"
  | none   => hex

/-- Render a hex-encoded gas count as decimal. -/
private def humanGas (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{n}  ({hex})"
  | none   => hex

/-- Render a hex-encoded block number as decimal. -/
private def humanBlock (hex : String) : String :=
  match hexNat? hex with
  | some n => s!"{n}  ({hex})"
  | none   => hex

/-- Append one TxJournal entry for a tx the daemon just signed/broadcast.
    Best-effort: failures are logged but never raised. Why: keep journaling
    out of the success path so a write error can never fail the user's tx.

    The trailing keyword-style `signMs? / paramSet? / userOpHash?` knobs
    are SPHINCS+-specific metadata used by `kind = "sphincs.userOp"`
    entries to record the post-quantum sign duration ("the grind") and
    parameter set. Other kinds leave them as `none` and the JSON encoder
    drops them. -/
def journalRecord
    (slotName fromAddr toAddr txHash dataHex kind : String)
    (valueWei nonce chainId : Nat)
    (accountIndex? : Option Nat)
    (status? blockNumber? gasUsed? : Option String)
    (signMs? : Option Nat := none)
    (paramSet? : Option String := none)
    (userOpHash? : Option String := none) : IO Unit := do
  let nowMs ← IO.monoMsNow
  let nowSec : Nat := nowMs / 1000
  let entry : LeanKohaku.Daemon.TxJournal.Entry :=
    { timestamp := nowSec, txHash := txHash, fromAddr := fromAddr,
      toAddr := toAddr, valueWei := valueWei, dataHex := dataHex,
      nonce := nonce, chainId := chainId, kind := kind,
      accountIndex? := accountIndex?, slotName := slotName,
      status? := status?, blockNumber? := blockNumber?, gasUsed? := gasUsed?,
      signMs? := signMs?, paramSet? := paramSet?, userOpHash? := userOpHash? }
  LeanKohaku.Daemon.TxJournal.append slotName entry

/-- A single configured indexer entry. URL is persisted to disk; the API
    key is supplied via env (e.g. `LEANKOHAKU_ETHERSCAN_KEY`) and never
    written to the config file. -/
structure IndexerEntry where
  name : String
  url  : String
  deriving Repr

/-- Per-chain SPHINCS- verifier contract address, keyed by parameter set.
    The on-chain `SphincsAccount` contract delegates `verify(...)` to this
    address via `staticcall`, so an account on chain `chain` with param set
    `paramSet` must target the matching deployed verifier. Phase 2 ships the
    schema only; concrete addresses stay `none` until Phase 4's Sepolia
    deployment lands. -/
structure SphincsVerifierEntry where
  chain    : String
  paramSet : LeanKohaku.Sphincs.ParamSet
  /-- Lower-case `0x...` hex address as written in the JSON config; the
      daemon RPC layer will validate it on first use. `none` here means
      the user has not configured a verifier for this `(chain, paramSet)`
      pair, and any signing flow under that pair must fail closed. -/
  address  : Option String
  deriving Repr

structure Config where
  socketPath : String
  chainId    : Nat
  policy     : Policy
  rpcEndpoint : LeanKohaku.RPC.Outbound.Endpoint
  -- Why: ENS resolution targets mainnet regardless of the operating chain.
  -- Optional: if `none`, ENS requests fail with -32030 (no silent fallback).
  ensRpcEndpoint : Option LeanKohaku.RPC.Outbound.Endpoint := none
  -- Why: per-chain RPC endpoints picked at call time. Keys are user-supplied
  -- chain names ("mainnet", "sepolia", ...). When a request omits `chain`,
  -- `rpcEndpoint` is used. When `chain` is supplied and missing here, the
  -- handler must fail closed rather than fall back to a different chain.
  chainEndpoints : Array (String × LeanKohaku.RPC.Outbound.Endpoint) := #[]
  indexers   : Array IndexerEntry := #[]
  -- Why: per-(chain, paramSet) SPHINCS- verifier address map. Read by
  -- Phase 3 daemon RPCs (`sphincs.create`, `sphincs.send`, ...). Empty by
  -- default; populated from `daemon.json`'s `sphincs_verifiers` block.
  sphincsVerifiers : Array SphincsVerifierEntry := #[]
  -- Why: per-(chain, paramSet) SPHINCS- factory address map. Re-uses
  -- `SphincsVerifierEntry` because the per-row shape is identical
  -- (chain × paramSet → optional address). Read by
  -- `sphincs.account.computeAddress` and `sphincs.account.deploy` —
  -- both fail closed when no factory is configured. Populated from
  -- `daemon.json`'s `sphincs_factories` block.
  sphincsFactories : Array SphincsVerifierEntry := #[]
  -- Why: per-chain ERC-4337 bundler URL (the UserOp submission
  -- endpoint, e.g. Candide). Bundler is paramSet-agnostic — one URL
  -- handles every paramSet on that chain — so the key is just the
  -- chain name. Read by `sphincs.account.send`; populated from
  -- `daemon.json`'s `sphincs_bundlers` block.
  sphincsBundlers : Array (String × String) := #[]
  -- Why: hard cap on the number of BIP-44 indices the trusted-registry
  -- RPC (`wallet.lean_verified_addresses`, Phase 1d) will enumerate per
  -- path. Lower = stricter forward-privacy at the cost of less context
  -- in the agent's system prompt. The handler clamps user-supplied
  -- `count` to this value; a request for more is silently capped, not
  -- errored. See `docs/PHASE1D_THREAT_MODEL.md` §2 for the rationale.
  trustedRegistryMaxPerPath : Nat := 5

instance : Repr Config where
  reprPrec cfg _ :=
    "Config(socketPath := " ++ repr cfg.socketPath ++
      ", chainId := " ++ repr cfg.chainId ++
      ", policy := <function>)"

/-- Resolve the RPC endpoint for an optional chain selector. Returns the
default `cfg.rpcEndpoint` when `chain?` is `none`, or the matching entry from
`cfg.chainEndpoints`. Fails closed (returns an error string) when the user
asks for a chain that is not configured — never silently uses a different
chain's endpoint. -/
def endpointForChain (cfg : Config) : Option String →
    Except String LeanKohaku.RPC.Outbound.Endpoint
  | none => .ok cfg.rpcEndpoint
  | some name =>
      match cfg.chainEndpoints.find? (fun (k, _) => k = name) with
      | some (_, ep) => .ok ep
      | none =>
          let upper := name.toUpper
          .error s!"no rpc_url configured for chain '{name}'; add it via `kohaku network set-rpc-chain {name} <url>` or set {upper}_RPC_URL / LEANKOHAKU_RPC_URL_{upper} in your environment"

/-- Look up the deployed SPHINCS- verifier address for a given
    `(chain, paramSet)` pair. Fails closed when no entry is configured;
    the caller must surface the error rather than fall back to a
    different param set. Phase 2 schema-only — Phase 3 RPC handlers
    consume this. -/
def sphincsVerifierFor (cfg : Config)
    (chain : String) (ps : LeanKohaku.Sphincs.ParamSet)
    : Except String String :=
  match cfg.sphincsVerifiers.find?
      (fun e => e.chain = chain && e.paramSet = ps) with
  | some { address := some addr, .. } => .ok addr
  | some { address := none, .. } =>
      .error
        s!"no sphincs verifier address for chain '{chain}' paramSet '{ps.toString}': set it in daemon.json under `sphincs_verifiers`"
  | none =>
      .error
        s!"no sphincs verifier configured for chain '{chain}' paramSet '{ps.toString}'"

/-- Same shape as `sphincsVerifierFor` but reads `cfg.sphincsFactories`.
    Failure messages point at the `sphincs_factories` config key. -/
def sphincsFactoryFor (cfg : Config)
    (chain : String) (ps : LeanKohaku.Sphincs.ParamSet)
    : Except String String :=
  match cfg.sphincsFactories.find?
      (fun e => e.chain = chain && e.paramSet = ps) with
  | some { address := some addr, .. } => .ok addr
  | some { address := none, .. } =>
      .error
        s!"no sphincs factory address for chain '{chain}' paramSet '{ps.toString}': set it in daemon.json under `sphincs_factories`"
  | none =>
      .error
        s!"no sphincs factory configured for chain '{chain}' paramSet '{ps.toString}'"

/-- Bundler URL per chain. Failure → caller fails closed. -/
def sphincsBundlerFor (cfg : Config) (chain : String) : Except String String :=
  match cfg.sphincsBundlers.find? (fun (c, _) => c = chain) with
  | some (_, url) => .ok url
  | none =>
      .error
        s!"no sphincs bundler configured for chain '{chain}': set it in daemon.json under `sphincs_bundlers`"

-- Why: no `defaultConfig` with a URL substitute. The daemon must refuse to
-- start without a user-configured `rpc_url` (env or daemon.json); see
-- `LeanKohaku.Daemon.Config.resolve`. Avoids any silent loopback dial.

/-- Build the verified-read backend if the persistent Colibri client is
    running. Thin wrapper over `State.buildColibriVia`; kept as a private
    alias because most call sites in this file already use the short
    name. Recovery policy (one respawn + HTTP fallback on second crash)
    lives in `Daemon.State` so `Daemon.TokenMeta` and others share it. -/
private def colibriVia (state : LeanKohaku.Daemon.State.Shared) (chainId : Nat) :
    IO (Option LeanKohaku.RPC.Outbound.VerifyVia) :=
  LeanKohaku.Daemon.State.buildColibriVia state chainId

/-- Resolve an RPC endpoint from a request. Honors an explicit `chain`
    string in `params` first; falls back to a tiny chainId → name map for
    the common cases (1 → "mainnet", 11155111 → "sepolia") so callers that
    only know the chainId still hit the right per-chain endpoint when the
    daemon was configured with one. Falls back to `cfg.rpcEndpoint`
    silently for anything else (clearsign decimals prefetch is best-
    effort; sidecar gracefully renders raw addresses on miss). -/
def chainEndpointFor (cfg : Config) (params : Json) (chainId : Nat) :
    LeanKohaku.RPC.Outbound.Endpoint :=
  let chainName : Option String :=
    match getField "chain" params >>= asString with
    | some s => some s
    | none =>
        if chainId = 1 then some "mainnet"
        else if chainId = 11155111 then some "sepolia"
        else none
  match endpointForChain cfg chainName with
  | .ok ep => ep
  | .error _ => cfg.rpcEndpoint

/-- Merge defaults from the daemon's configured endpoint into a helios
    request's params object. Adds `executionRpc` (from `endpoint.url`)
    and `chainId` (from `endpoint.chainId`, falling back to `cfg.chainId`)
    only when the caller did not already supply them. Non-object params
    pass through unchanged so the sidecar's own validation surfaces the
    error. `consensusRpc` is helios-specific (beacon API, not in
    `Endpoint`) and stays caller-supplied; the sidecar defaults mainnet
    to `lightclientdata.org` and requires an explicit value otherwise. -/
private def mergeHeliosDefaults
    (params : Json) (endpoint : LeanKohaku.RPC.Outbound.Endpoint) (fallbackChainId : Nat) :
    Json :=
  match params with
  | .obj fields =>
      let has (k : String) : Bool := fields.any (fun (key, _) => key == k)
      let cid : Nat := endpoint.chainId.getD fallbackChainId
      let toAdd : Array (String × Json) :=
        (if has "executionRpc" then #[] else #[("executionRpc", .str endpoint.url)])
        ++ (if has "chainId" then #[] else #[("chainId", .num (Int.ofNat cid))])
      .obj (fields ++ toAdd)
  | other => other

/-- ERC-20 `Transfer(address,address,uint256)` event signature. -/
private def transferEventTopic : String :=
  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

/-- Walk a callTracer+withLog trace tree and pull every token address that
    appears as the emitter of a `Transfer` log. Used to prefetch ERC-20
    metadata so the TUI can render "100 USDC" instead of raw uint256.
    `partial` because the callTracer tree is recursive without a bounded
    measure; in practice depth is small. -/
private partial def collectTransferTokens : Json → Array String
  | .obj fields =>
      let lookup (k : String) :=
        (fields.find? (fun (key, _) => key = k)).map Prod.snd
      let fromLogs : Array String :=
        match lookup "logs" with
        | some (.arr logArr) =>
            logArr.filterMap fun log =>
              match log with
              | .obj lf =>
                  let ll (k : String) : Option Json :=
                    (lf.find? (fun (key, _) => key = k)).map Prod.snd
                  let isTransfer : Bool :=
                    match ll "topics" with
                    | some (Json.arr topics) =>
                        match (topics[0]? : Option Json) with
                        | some (Json.str s) => s.toLower = transferEventTopic
                        | _ => false
                    | _ => false
                  if isTransfer then ll "address" >>= asString else (none : Option String)
              | _ => none
        | _ => #[]
      let fromCalls : Array String :=
        match lookup "calls" with
        | some (.arr children) =>
            children.foldl (fun acc c => acc ++ collectTransferTokens c) #[]
        | _ => #[]
      fromLogs ++ fromCalls
  | _ => #[]

/-- Scan ABI-encoded calldata for 32-byte words that look like addresses
    (12 leading zero bytes + 20 nonzero bytes). Returns lowercased
    0x-prefixed addresses, deduplicated, in first-seen order. Used by
    `tx.decodeIntent` to prefetch ERC-20 metadata for tokens referenced
    *inside* a multicall payload — without this, inner `tokenAmount`
    fields fall back to the short-address tag.

    Sliding a 64-hex (32-byte) window in 4-byte (8 hex char) steps catches
    addresses at any selector-shifted alignment: an inner element of a
    `bytes[]` starts with a 4-byte function selector, so its parameter
    words live at byte offsets that are *not* 32-aligned relative to the
    outer calldata, but ARE always 4-aligned. False positives (small
    uint256 values that happen to fit in 160 bits) are harmless — the
    follow-up `decimals()`/`symbol()` eth_calls revert cleanly and the
    cache absorbs the miss. -/
private partial def scanCalldataAddrLoop
    (chars : List Char) (acc : Array String) : Array String :=
  let word := chars.take 64
  if word.length < 64 then acc
  else
    let lead := word.take 24
    let addrChars := word.drop 24
    let leadAllZero := lead.all (· == '0')
    -- Entropy guard: real EOA / contract addresses have ~35-40 nonzero hex
    -- characters out of 40. Shifted small-integer matches (e.g. a uint256
    -- value of 0x20 caught at a non-aligned offset) have only 1-4 nonzero
    -- characters. Requiring ≥ 10 nonzero hex chars in the address portion
    -- removes the vast majority of false positives without dropping any
    -- realistic token address — and keeps the daemon's metadata prefetch
    -- to a handful of eth_calls instead of dozens.
    let nonzeroCount := addrChars.foldl (fun n c => if c == '0' then n else n + 1) 0
    let acc' :=
      if leadAllZero && nonzeroCount ≥ 10 then
        let canonical := "0x" ++ (String.ofList addrChars).toLower
        if acc.contains canonical then acc else acc.push canonical
      else acc
    scanCalldataAddrLoop (chars.drop 8) acc'

def scanCalldataAddresses (data : String) : Array String :=
  -- Stay in `List Char` for the whole walk: `String.drop` returns a
  -- `String.Slice` in Lean 4.29 which doesn't roundtrip cleanly into the
  -- chunked loop. The list-based path is simpler and the cost is bounded
  -- by calldata length.
  let chars := data.toList
  let chars := match chars with
    | '0' :: 'x' :: rest => rest
    | _ => chars
  -- Skip the 4-byte (8 hex char) outer function selector. `List.drop`
  -- returns `[]` when the input is shorter, which the loop handles as a
  -- no-op.
  scanCalldataAddrLoop (chars.drop 8) #[]

private def slotMetadataJson (state : LeanKohaku.Daemon.State.Shared)
    (record : LeanKohaku.Wallet.EoaStore.Record) : IO Json := do
  let unlocked ← LeanKohaku.Daemon.State.isUnlocked state record.name
  pure <| .obj #[
    ("name", .str record.name),
    ("address", .str record.address),
    ("derivationPath", .str record.derivationPath),
    ("locked", .bool (!unlocked)),
    ("createdAt", .num (Int.ofNat record.createdAt))
  ]

private def textResultJson (text : String) (exitCode : UInt32) : Json :=
  .obj #[
    ("text", .str text),
    ("exitCode", .num (Int.ofNat exitCode.toNat))
  ]

private def tpm2CreateStatusText : CreateStatus → String
  | .created => "created"
  | .alreadyExists => "already exists"
  | .invalidKeyName => "invalid key name"
  | .invalidPin => s!"invalid PIN (must be at least {minPinLength} characters)"
  | .missingTpmDevice => "missing TPM device"
  | .missingTool tool => s!"missing required tool: {tool}"
  | .pinAuthFailed stderr =>
      s!"PIN auth failed\n\n{stderr}"
  | .pinDictionaryLockout stderr =>
      s!"TPM dictionary-attack lockout — wait for the lockout interval to elapse\n\n{stderr}"
  | .policyRejected => "Sepolia R1 account policy rejected"
  | .commandFailed cmd stderr =>
      s!"command failed: {cmd}\n\n{stderr}"

private def tpm2CreateReportText (report : CreateReport) : String :=
  "leanKohaku TPM2 R1 wallet creation\n\n\
   Requested wallet:\n\
     - account: r1-smart (chain-agnostic; deploy selects chain)\n\
     - backend: local Linux TPM2\n\
     - curve: P-256/R1\n\
     - custody: local only; no online keystore\n\n\
   Result:\n\
     - status: " ++ tpm2CreateStatusText report.status ++ "\n\
     - key directory: " ++ report.keyDir.toString ++ "\n\
     - public key: " ++ report.publicKey.toString ++ "\n\
     - manifest: " ++ report.manifest.toString ++ "\n\n\
   Security boundary:\n\
     - created through local tpm2-tools only\n\
     - PIN is bound to the TPM key as a userwithauth value\n\
     - no seed or raw private key is generated by Lean\n\
     - TPM private blob remains wrapped for the local TPM\n\
     - wrong-PIN attempts are rate-limited by the TPM's hardware dictionary-attack protection\n"

private def signStatusText : SignStatus → String
  | .signed => "signed"
  | .invalidKeyName => "invalid key name"
  | .invalidDigest => "invalid digest: expected 32-byte hex"
  | .invalidPin => s!"invalid PIN (must be at least {minPinLength} characters)"
  | .missingKey => "missing key"
  | .missingTpmDevice => "missing TPM device"
  | .missingTool tool => s!"missing required tool: {tool}"
  | .pinAuthFailed stderr =>
      s!"PIN auth failed\n\n{stderr}"
  | .pinDictionaryLockout stderr =>
      s!"TPM dictionary-attack lockout — wait for the lockout interval to elapse\n\n{stderr}"
  | .commandFailed cmd stderr =>
      s!"command failed: {cmd}\n\n{stderr}"

private def tpm2SignReportText (report : SignReport) : String :=
  let sigLine :=
    match report.signatureHex with
    | none => ""
    | some sig => "     - signature hex: " ++ sig ++ "\n"
  "leanKohaku TPM2 R1 signing\n\n\
   Requested signer:\n\
     - key name: " ++ report.keyName ++ "\n\
     - backend: local Linux TPM2\n\n\
   Result:\n\
     - status: " ++ signStatusText report.status ++ "\n\
     - key directory: " ++ report.keyDir.toString ++ "\n\
     - digest file: " ++ report.digest.toString ++ "\n\
     - signature file: " ++ report.signature.toString ++ "\n" ++ sigLine ++
  "\n\
   Security boundary:\n\
     - signing requires the TPM-bound PIN (auth value checked by the TPM)\n\
     - digest and signature stay under the local .leankohaku state directory\n\
     - TPM private blob remains wrapped for the local TPM\n"

private def formatKeyList : List String → String
  | [] => "No local Sepolia TPM2 keys found.\n"
  | names =>
      "Local Sepolia TPM2 keys:\n" ++
        String.join (names.map (fun name => "- " ++ name ++ "\n"))

/-- Build the chain-RPC env vars passed to every shell script we spawn.
    Anchors the user's daemon config as the single source of truth for RPC
    URLs: `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL` are populated when the
    matching endpoint exists in `cfg.chainEndpoints`, and `ETH_RPC_URL`
    (the default name `cast` / `forge` look for) is bound to whichever
    chain matches the daemon's active `chainId`. We deliberately emit
    only entries that resolve — passing `none` would *unset* the var
    in the child env, which would clobber a value the user exported
    manually for some other reason. -/
private def chainScriptEnv (cfg : Config) : Array (String × Option String) :=
  let urlFor (name : String) : Option String :=
    (cfg.chainEndpoints.find? (fun (k, _) => k = name)).map (fun (_, ep) => ep.url)
  let sepoliaUrl := urlFor "sepolia"
  let mainnetUrl := urlFor "mainnet"
  let activeUrl :=
    if cfg.chainId == 11155111 then sepoliaUrl
    else if cfg.chainId == 1 then mainnetUrl
    else none
  let pairs : List (String × Option String) :=
    [ ("SEPOLIA_RPC_URL", sepoliaUrl)
    , ("MAINNET_RPC_URL", mainnetUrl)
    , ("ETH_RPC_URL",    activeUrl) ]
  pairs.foldl (init := (#[] : Array (String × Option String))) fun acc (k, v) =>
    match v with
    | some s => acc.push (k, some s)
    | none   => acc

private def runScript (cfg : Config) (args : Array String)
    (env : Array (String × Option String) := #[]) : IO (UInt32 × String) := do
  try
    let out ← IO.Process.output
      { cmd := "./script/r1_sepolia.sh",
        args := args,
        env := chainScriptEnv cfg ++ env }
    pure (out.exitCode, out.stdout ++ out.stderr)
  catch e =>
    pure (1, e.toString ++ "\n")

/-- Like `runScript` but returns stdout and stderr separately, so the
    daemon can parse a structured first token from stdout (e.g. the
    digest hex) without having to disentangle script status chatter. -/
private def runScriptSplit (cfg : Config) (args : Array String)
    (env : Array (String × Option String) := #[]) :
    IO (UInt32 × String × String) := do
  try
    let out ← IO.Process.output
      { cmd := "./script/r1_sepolia.sh",
        args := args,
        env := chainScriptEnv cfg ++ env }
    pure (out.exitCode, out.stdout, out.stderr)
  catch e =>
    pure (1, "", e.toString ++ "\n")

private def paramName (params : Json) : Except RpcError String :=
  match params with
  | .obj _ =>
      match getField "name" params >>= asString with
      | some name => .ok name
      | none => .error invalidParams
  | .arr values =>
      match values.toList with
      | first :: _ =>
          match asString first with
          | some name => .ok name
          | none => .error invalidParams
      | [] => .error invalidParams
  | _ => .error invalidParams

private def paramString (params : Json) (key : String) : Except RpcError String :=
  match getField key params >>= asString with
  | some value => .ok value
  | none => .error invalidParams

private def paramStringD (params : Json) (key default : String) : String :=
  match getField key params >>= asString with
  | some value => value
  | none => default

private def paramNatD (params : Json) (key : String) (default : Nat) : Nat :=
  match getField key params >>= asNat with
  | some value => value
  | none => default

/-- Resolve the account-kind hint for an address by scanning the daemon's
    local stores. Used by prepare-style RPCs to decide whether to collapse
    a multi-leg result into a single `executeBatch` call.

    Scan order — first hit wins:
    1. TPM2 R1 deployments at `.leankohaku/keystore/tpm2/<name>/r1-account-address.txt`
    2. SPHINCs- hybrid records' `smartAccountAddress`
    3. (no EOA scan — `.eoa` is the default fall-through anyway)

    Address comparison is case-insensitive on the hex body. Empty / missing
    files are skipped without erroring; this is a best-effort hint, so any
    IO failure quietly falls through to `.eoa` rather than blocking the
    surrounding RPC.

    Caller note: when the JSON-RPC params already carry an explicit
    `accountKind` the caller wins — this helper is only invoked as the
    fallback. -/
private def discoverAccountKind (addr : String) :
    IO LeanKohaku.Wallet.ExecuteBatch.AccountKindHint := do
  let target := addr.toLower
  let tpmStateDir : System.FilePath := ".leankohaku/keystore/tpm2"
  try
    let tpmNames ← listSepoliaKeys
    for n in tpmNames do
      let addrFile := tpmStateDir / n / "r1-account-address.txt"
      if ← addrFile.pathExists then
        let raw ← (try IO.FS.readFile addrFile catch _ => pure "")
        let trimmed := raw.trimAscii.toString.toLower
        if !trimmed.isEmpty && trimmed = target then
          return LeanKohaku.Wallet.ExecuteBatch.AccountKindHint.r1Smart
  catch _ => pure ()
  try
    let sphincsNames ← LeanKohaku.Wallet.SphincsHybridStore.listSlotNames
    for n in sphincsNames do
      match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord n with
      | .error _ => pure ()
      | .ok r =>
          match r.smartAccountAddress with
          | some a =>
              if a.toLower = target then
                return LeanKohaku.Wallet.ExecuteBatch.AccountKindHint.sphincsHybrid
          | none => pure ()
  catch _ => pure ()
  return LeanKohaku.Wallet.ExecuteBatch.AccountKindHint.eoa

private def mnemonicFromPhrase (phrase : String) : LeanKohaku.Wallet.Mnemonic.Mnemonic :=
  { words := phrase.splitOn " " |>.filter (fun word => word != "") }

private def expectExcept {α : Type} : Except String α → IO α
  | .ok value => pure value
  | .error err => throw <| IO.userError err

private def deriveAddressFromSeed (seed : ByteArray) (path : String) :
    IO (Except String String) := do
  try
    discard <| expectExcept (LeanKohaku.Wallet.Bip44.validateEthereumPath path)
    let master ← expectExcept (← LeanKohaku.Wallet.HDKey.fromSeedIO seed)
    let child ← expectExcept (← LeanKohaku.Wallet.HDKey.derivePathIO master path)
    let pub ← expectExcept <| ← LeanKohaku.Crypto.Secp256k1Native.pubkeyIO
      (LeanKohaku.Crypto.Hex.encode (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 child.key))
      false
    let address ← expectExcept <| ← LeanKohaku.Wallet.Address.addressFromUncompressedPubkeyIO pub
    LeanKohaku.Wallet.Address.eip55Checksum address
  catch e =>
    pure (.error e.toString)

/-- Stable per-seed identifier used by the trusted-registry RPC.

Defined as the lowercased 16-character hex prefix (first 8 bytes) of
`keccak256(masterCompressedPubkey)`, where `masterCompressedPubkey` is
BIP-32's compressed master public key (33 bytes). The input is a
public quantity (anyone with a single non-hardened child pubkey can
derive it), so the fingerprint leaks no secret.

See `docs/PHASE1D_THREAT_MODEL.md` §"Seed fingerprint definition" for
the rationale. Used by `wallet.lean_verified_addresses` to let the
agent detect seed rotation between sessions without ever observing
the seed itself. -/
private def seedFingerprintFromSeed (seed : ByteArray) :
    IO (Except String String) := do
  try
    let master ← expectExcept (← LeanKohaku.Wallet.HDKey.fromSeedIO seed)
    let pub ← expectExcept <| ← LeanKohaku.Crypto.Secp256k1Native.pubkeyIO
      (LeanKohaku.Crypto.Hex.encode (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 master.key))
      true
    let digest ← expectExcept <| ← LeanKohaku.Crypto.Hacl.keccak256EthereumIO
      (LeanKohaku.Crypto.Hex.encode pub)
    -- Take 8 bytes ⇒ 16 hex chars; lowercased by `Hex.encode`.
    pure (.ok ("0x" ++ LeanKohaku.Crypto.Hex.encode (LeanKohaku.Wallet.HDKey.take digest 0 8)))
  catch e =>
    pure (.error e.toString)

private def derivePrivateKeyFromSeed (seed : ByteArray) (path : String) :
    IO (Except String ByteArray) := do
  try
    discard <| expectExcept (LeanKohaku.Wallet.Bip44.validateEthereumPath path)
    let master ← expectExcept (← LeanKohaku.Wallet.HDKey.fromSeedIO seed)
    let child ← expectExcept (← LeanKohaku.Wallet.HDKey.derivePathIO master path)
    pure (.ok (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 child.key))
  catch e =>
    pure (.error e.toString)

private def unlockedSlot (state : LeanKohaku.Daemon.State.Shared) (name : String) :
    IO (Except RpcError LeanKohaku.Daemon.State.UnlockedSlot) := do
  match ← LeanKohaku.Daemon.State.getUnlocked? state name with
  | some slot => pure (.ok slot)
  | none =>
      -- Sub-account-tolerant retry. The TUI's wallet objects carry
      -- display names like "leanWallet/0" / "leanWallet/ops" for
      -- BIP-44 sub-accounts; the unlocked-slot table is keyed by the
      -- base slot name. EoaStore writes slots as filesystem paths
      -- (`eoa/<name>.json`), so a literal '/' in a slot name is
      -- impossible — the split is unambiguous. The sub-account is
      -- selected later via the separate `account` parameter, which
      -- `resolveSigningTarget` already reads from the request.
      let baseName := (name.splitOn "/").headD name
      if baseName.length == name.length then
        pure (.error { code := -32012, message := "EOA slot is locked" })
      else
        match ← LeanKohaku.Daemon.State.getUnlocked? state baseName with
        | some slot => pure (.ok slot)
        | none => pure (.error { code := -32012, message := "EOA slot is locked" })

/-- Why: a freshly read record may carry a synthesized accounts list (when
    the on-disk JSON predates multi-account). Always returns a non-empty array
    with index 0 mirroring the primary path/address. -/
private def recordAccounts (r : LeanKohaku.Wallet.EoaStore.Record) :
    Array LeanKohaku.Wallet.EoaStore.Account :=
  if r.accounts.isEmpty then
    #[{ index := 0, path := r.derivationPath, address := r.address, label := none }]
  else
    r.accounts

private def accountToJson (a : LeanKohaku.Wallet.EoaStore.Account) : Json :=
  LeanKohaku.Wallet.EoaStore.Account.toJson a

private def findAccount (r : LeanKohaku.Wallet.EoaStore.Record) (idx : Nat) :
    Option LeanKohaku.Wallet.EoaStore.Account :=
  (recordAccounts r).find? (fun a => a.index = idx)

/-- Pick the smallest non-negative integer not already used as an account index. -/
private def nextAccountIndex (r : LeanKohaku.Wallet.EoaStore.Record) : Nat :=
  let used := (recordAccounts r).map (fun a => a.index)
  let rec loop (n : Nat) (fuel : Nat) : Nat :=
    match fuel with
    | 0 => n
    | fuel + 1 => if used.contains n then loop (n + 1) fuel else n
  loop 0 (used.size + 1)

/-- Resolve the optional `account` parameter into a `(path, address)` pair.
    If absent, returns the slot's primary (mirrors `derivationPath`/`address`).
    If present, looks up the account on the loaded record. -/
private def resolveAccount
    (r : LeanKohaku.Wallet.EoaStore.Record)
    (slot : LeanKohaku.Daemon.State.UnlockedSlot)
    (params : Json) : Except RpcError (String × String) :=
  match getField "account" params >>= asNat with
  | none => .ok (slot.derivationPath, slot.address)
  | some idx =>
      match findAccount r idx with
      | some a => .ok (a.path, a.address)
      | none =>
          .error { code := -32014, message := s!"account index {idx} not found in slot",
                   data := some (.str s!"slot has no account with index={idx}") }

private def loadRecord (name : String) :
    IO (Except RpcError LeanKohaku.Wallet.EoaStore.Record) := do
  match ← LeanKohaku.Wallet.EoaStore.load name with
  | .ok r => pure (.ok r)
  | .error _ =>
      -- Sub-account-tolerant retry for display-form names like
      -- "leanWallet/0" / "leanWallet/3". EoaStore writes slots as
      -- `eoa/<name>.json`, so a literal '/' in a slot name is
      -- impossible — the base name before the first '/' is the
      -- actual slot identifier. The sub-account index / label
      -- comes through the separate `account` parameter on send /
      -- sign RPCs (see `resolveSigningTarget`).
      let baseName := (name.splitOn "/").headD name
      if baseName.length == name.length then
        pure (.error { code := -32010, message := "EOA slot not found", data := some (.str name) })
      else
        match ← LeanKohaku.Wallet.EoaStore.load baseName with
        | .ok r => pure (.ok r)
        | .error err =>
            pure (.error { code := -32010, message := "EOA slot not found", data := some (.str err) })

/-- Resolve `(path, address)` for a sign/send operation, considering both
    legacy explicit `path` and new `account` params. `account` takes priority;
    if absent and `path` provided, only path is overridden (address stays
    primary — matches legacy behavior). If neither provided, returns slot
    primary `(derivationPath, address)`. -/
private def resolveSigningTarget
    (name : String)
    (slot : LeanKohaku.Daemon.State.UnlockedSlot) (params : Json) :
    IO (Except RpcError (String × String)) := do
  match getField "account" params >>= asNat with
  | some _ =>
      match ← loadRecord name with
      | .error err => pure (.error err)
      | .ok r => pure (resolveAccount r slot params)
  | none =>
      let path := paramStringD params "path" slot.derivationPath
      pure (.ok (path, slot.address))

private def signatureJson (sig : LeanKohaku.Crypto.Secp256k1.Signature) : Json :=
  .obj #[
    ("r", .str (LeanKohaku.Crypto.Hex.encode (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 sig.r))),
    ("s", .str (LeanKohaku.Crypto.Hex.encode (LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 sig.s))),
    ("v", .num (Int.ofNat sig.v.toNat))
  ]

private def bytesToNat (bytes : ByteArray) : Nat :=
  bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

private def hexChar (n : Nat) : Char :=
  match n with
  | 0 => '0' | 1 => '1' | 2 => '2' | 3 => '3'
  | 4 => '4' | 5 => '5' | 6 => '6' | 7 => '7'
  | 8 => '8' | 9 => '9' | 10 => 'a' | 11 => 'b'
  | 12 => 'c' | 13 => 'd' | 14 => 'e' | _ => 'f'

private def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then
    some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then
    some (10 + c.toNat - 'a'.toNat)
  else if 'A' ≤ c && c ≤ 'F' then
    some (10 + c.toNat - 'A'.toNat)
  else
    none

private def stripHexPrefix (s : String) : String :=
  if s.startsWith "0x" || s.startsWith "0X" then
    (s.drop 2).toString
  else
    s

partial def natHexDigits : Nat → List Char → List Char
  | 0, acc => acc
  | n, acc => natHexDigits (n / 16) (hexChar (n % 16) :: acc)

private def natQuantityHex (n : Nat) : String :=
  match n with
  | 0 => "0x0"
  | _ => "0x" ++ String.ofList (natHexDigits n [])

private def parseHexQuantityDigits : List Char → Nat → Option Nat
  | [], acc => some acc
  | c :: cs, acc => do
      let d ← hexDigit? c
      parseHexQuantityDigits cs (acc * 16 + d)

private def parseHexQuantity (s : String) : Option Nat :=
  let raw := stripHexPrefix s
  if raw.isEmpty then
    none
  else
    parseHexQuantityDigits raw.toList 0

private def jsonHexNat (json : Json) : Except RpcError Nat :=
  match asString json with
  | none => .error invalidParams
  | some s =>
      match parseHexQuantity s with
      | none => .error invalidParams
      | some n => .ok n

private def jsonHexNatIO (json : Json) (what : String) : IO Nat := do
  match jsonHexNat json with
  | .ok n => pure n
  | .error _ => throw <| IO.userError s!"invalid hex quantity for {what}"

private def txNatField (tx : Json) (key : String) : Except RpcError Nat :=
  match getField key tx >>= asNat with
  | some value => .ok value
  | none => .error invalidParams

private def paramNat (params : Json) (key : String) : Except RpcError Nat :=
  match getField key params >>= asNat with
  | some value => .ok value
  | none => .error invalidParams

/-- Read a `Nat` parameter from either a JSON integer (preferred — bigint
    serialised as a bare numeric literal by `tui/src/daemon.ts`) or a
    `String` containing a `0x`-prefixed hex quantity or a plain decimal.
    Used by `r1.sendRawSepolia` where the TUI ships a hex `value`. -/
private def paramNatOrHexStr (params : Json) (key : String) : Except RpcError Nat :=
  match getField key params with
  | none => .error invalidParams
  | some (.num n) =>
      if n ≥ 0 then .ok n.toNat else .error invalidParams
  | some (.str s) =>
      let trimmed := s.trimAscii.toString
      if trimmed.isEmpty then .error invalidParams
      else if trimmed.startsWith "0x" || trimmed.startsWith "0X" then
        match parseHexQuantity trimmed with
        | some n => .ok n
        | none   => .error invalidParams
      else
        match trimmed.toNat? with
        | some n => .ok n
        | none   => .error invalidParams
  | _ => .error invalidParams

private def txBytesFieldD (tx : Json) (key : String) (default : ByteArray := ByteArray.empty) :
    Except RpcError ByteArray :=
  match getField key tx with
  | none => .ok default
  | some json =>
      match asBytes json with
      | some bytes => .ok bytes
      | none => .error invalidParams

private def txToField (tx : Json) : Except RpcError (Option LeanKohaku.Ethereum.Address.Address) :=
  match getField "to" tx with
  | none => .ok none
  | some .null => .ok none
  | some (.str s) =>
      match LeanKohaku.Ethereum.Address.fromHex s with
      | some address => .ok (some address)
      | none => .error invalidParams
  | some _ => .error invalidParams

private def erc20BalanceOfData (owner : LeanKohaku.Ethereum.Address.Address) : String :=
  "0x70a08231" ++ String.ofList (List.replicate 24 '0') ++ stripHexPrefix (LeanKohaku.Crypto.Hex.encode owner.bytes)

private def paramTxRequest (params : Json) : Except RpcError Json :=
  match getField "tx" params with
  | some (.obj fields) => .ok (.obj fields)
  | some _ => .error invalidParams
  | none => .error invalidParams

private def txFromJson (tx : Json) : Except RpcError LeanKohaku.Ethereum.Tx.TxEip1559 := do
  let chainId ← txNatField tx "chainId"
  let nonce ← txNatField tx "nonce"
  let maxPriorityFeePerGas ← txNatField tx "maxPriorityFeePerGas"
  let maxFeePerGas ← txNatField tx "maxFeePerGas"
  let gasLimit ← txNatField tx "gasLimit"
  let to ← txToField tx
  let value ← txNatField tx "value"
  let data ← txBytesFieldD tx "data"
  .ok {
    chainId := chainId,
    nonce := nonce,
    maxPriorityFeePerGas := maxPriorityFeePerGas,
    maxFeePerGas := maxFeePerGas,
    gasLimit := gasLimit,
    to := to,
    value := value,
    data := data,
    accessList := []
  }

private def paramTx (params : Json) : Except RpcError LeanKohaku.Ethereum.Tx.TxEip1559 :=
  match getField "tx" params with
  | some tx => txFromJson tx
  | none => txFromJson params

private def estimateTxJson (fromAddr to : String) (value : Nat) (data : ByteArray) : Json :=
  .obj #[
    ("from", .str fromAddr),
    ("to", .str to),
    ("value", .str (natQuantityHex value)),
    ("data", .str (LeanKohaku.Crypto.Hex.encode data))
  ]

private def sendResultJson (to value raw txHash : String)
    (nonce gasLimit maxPriorityFeePerGas maxFeePerGas : Nat)
    (sig : LeanKohaku.Crypto.Secp256k1.Signature) : Json :=
  .obj #[
    ("to", .str to),
    ("value", .str value),
    ("nonce", .str (natQuantityHex nonce)),
    ("gasLimit", .str (natQuantityHex gasLimit)),
    ("maxPriorityFeePerGas", .str (natQuantityHex maxPriorityFeePerGas)),
    ("maxFeePerGas", .str (natQuantityHex maxFeePerGas)),
    ("raw", .str raw),
    ("txHash", .str txHash),
    ("signature", signatureJson sig)
  ]

private def saveMnemonicSlot
    (state : LeanKohaku.Daemon.State.Shared)
    (params : Json) (generated : Option LeanKohaku.Wallet.Mnemonic.Mnemonic := none) :
    IO (Except RpcError (LeanKohaku.Wallet.EoaStore.Record × Option LeanKohaku.Wallet.Mnemonic.Mnemonic)) := do
  try
    let name ← expectExcept <| paramString params "name" |>.mapError (fun _ => "missing name")
    -- If the wallet master KEK is currently held in memory, a per-slot
    -- passphrase is optional — we'll generate an ephemeral one for the
    -- on-disk wrap and immediately enroll the slot under master so future
    -- unlocks use the KEK. The ephemeral isn't returned to the client and
    -- isn't a recovery factor; it exists only because EoaStore.save expects
    -- an encrypted seed and we don't want to touch that schema yet.
    --
    -- When master is NOT loaded the passphrase is still required — that's
    -- the only way to encrypt the seed at rest in this branch.
    let masterSlot? ← LeanKohaku.Daemon.State.getMasterKek? state
    -- Track whether the user actually picked their own per-slot passphrase
    -- vs. us minting an ephemeral one. The flag drives the auto-enroll
    -- decision below (and gets persisted into the record so future
    -- master-unlock paths know to skip rewrap).
    let userSuppliedPassphrase : Bool :=
      match paramString params "passphrase" with
      | .ok p => p.length > 0
      | .error _ => false
    let passphrase ← match paramString params "passphrase" with
      | .ok p =>
          if p.length > 0 then pure p
          else if masterSlot?.isSome then
            let bytes ← LeanKohaku.Crypto.Random.getRandomBytes 32
            pure (LeanKohaku.Crypto.Hex.encode bytes)
          else
            throw <| IO.userError "missing passphrase (no master KEK loaded — set one with `wallet master init` or pick a per-slot passphrase)"
      | .error _ =>
          if masterSlot?.isSome then
            let bytes ← LeanKohaku.Crypto.Random.getRandomBytes 32
            pure (LeanKohaku.Crypto.Hex.encode bytes)
          else
            throw <| IO.userError "missing passphrase (no master KEK loaded — set one with `wallet master init` or pick a per-slot passphrase)"
    let derivationPath := paramStringD params "derivationPath" defaultDerivationPath
    let mnemonic ←
      match generated with
      | some m => pure m
      | none =>
          let phrase ← expectExcept <| paramString params "mnemonic" |>.mapError (fun _ => "missing mnemonic")
          pure (mnemonicFromPhrase phrase)
    let seed ← expectExcept <| ← LeanKohaku.Wallet.Mnemonic.mnemonicToSeedIO mnemonic ""
    let address ← expectExcept <| ← deriveAddressFromSeed seed derivationPath
    -- Persist the mnemonic phrase encrypted under the same passphrase so
    -- `eoa.revealMnemonic` can recover the words later. Words are joined
    -- with single spaces (BIP-39 canonical form).
    let phrase :=
      String.intercalate " " mnemonic.words.toArray.toList
    let baseRecord ← expectExcept <| ← LeanKohaku.Wallet.EoaStore.saveEncryptedSeed
      name passphrase seed derivationPath address (some phrase)
    -- customPassphrase records the user's intent: did they explicitly
    -- pick this passphrase, or did we generate it ephemerally? The flag
    -- gates the lazy-enroll path in `eoa.unlock` (line ~2733) — slots
    -- where the user picked their own pass shouldn't get rewrapped under
    -- master automatically.
    let record ←
      if userSuppliedPassphrase && !baseRecord.customPassphrase then
        let updated := { baseRecord with customPassphrase := true }
        try LeanKohaku.Wallet.EoaStore.save updated
        catch _ => pure ()
        pure updated
      else
        pure baseRecord
    -- Immediate enrollment under master KEK (mirrors the lazy-enroll path
    -- in `eoa.unlock`). Without this the slot is created with a per-slot
    -- wrap only, and the first unlock attempt via the master prompt would
    -- fail until the user enters the per-slot passphrase — which they
    -- don't have when we generated it ephemerally. Skipped when the user
    -- explicitly picked their own passphrase (customPassphrase=true) —
    -- that's a "I want to manage my own per-slot key" signal we respect.
    -- Failures are swallowed: the slot is still functional with whatever
    -- passphrase the caller supplied; only master-unlock convenience is
    -- degraded.
    let record ← match masterSlot? with
      | none => pure record
      | some slot =>
          if record.customPassphrase then pure record
          else
            match ← LeanKohaku.Keystore.MasterPassphrase.wrapSlot
                slot.kek record.name record.derivationPath record.address seed with
            | .error _ => pure record
            | .ok wrap =>
                let updated := { record with masterWrap := some wrap }
                try LeanKohaku.Wallet.EoaStore.save updated
                catch _ => pure ()
                pure updated
    pure (.ok (record, generated))
  catch e =>
    pure <| .error { invalidParams with data := some (.str e.toString) }

private def importResultJson (state : LeanKohaku.Daemon.State.Shared)
    (record : LeanKohaku.Wallet.EoaStore.Record)
    (mnemonic? : Option LeanKohaku.Wallet.Mnemonic.Mnemonic := none) : IO Json := do
  let base ← slotMetadataJson state record
  match base with
  | .obj fields =>
      match mnemonic? with
      | none => pure (.obj fields)
      | some m => pure (.obj (fields.push ("mnemonic", .arr (m.words.toArray.map Json.str))))
  | other => pure other

private def removeSocketFile (socketPath : String) : IO Unit := do
  try
    IO.FS.removeFile socketPath
  catch _ =>
    pure ()

private def socketActivated : IO Bool := do
  match ← IO.getEnv "LISTEN_FDS" with
  | some "1" => pure true
  | _ => pure false

private def exitSoon (socketPath : String) : IO Unit := do
  IO.sleep 50
  unless (← socketActivated) do
    removeSocketFile socketPath
  IO.Process.exit 0

/-- JSON-RPC error code returned when a shielded handler that requires the
    Privacy-Pools spending secret is invoked but no encrypted secret is
    stored on disk. The CLI surfaces this as a friendly hint. -/
private def ppSecretMissing : RpcError :=
  { code := -32021
    message := "no Privacy Pools secret stored — run 'kohaku shield <wallet> <eth>' to create one or 'kohaku shield import <mnemonic>' to restore"
    data := none }

/-- Forward a shielded RPC to the kohaku-bridge sidecar.

Privacy Pools v1 is **Sepolia-only** at the contract layer. Regardless
of the daemon's default chain (cfg.chainId), every shielded operation
targets the Sepolia deployment. This function:

* pins the policy check + sidecar env to Sepolia (chainId=11155111,
  cfg.chainEndpoints["sepolia"] for the RPC URL);
* falls back to cfg.rpcEndpoint when Sepolia isn't configured — the
  call will fail downstream with a chain-mismatch error, which is
  clearer than the policy-denial path it used to take.

The mnemonic is supplied by the caller (after decrypting the on-disk
secret slot); the env var fallback that used to live here is removed.
-/
private def shieldedBridgeCall (cfg : Config) (method : String) (params : Json)
    (ppMnemonic? : Option String) (_req : Request)
    (rgMnemonic? : Option String := none)
    (rgBundlerUrl? : Option String := none)
    (rgDelegatingKeyHex? : Option String := none)
    (rgSeedHex? : Option String := none) :
    IO (Except RpcError Json) := do
  let bridgeReq : LeanKohaku.Privacy.Bridge.Request :=
    { method := method, params := params, id := 0 }
  -- Privacy Pools v1 is Sepolia-only. Pin the policy chainId so the
  -- chain-aware policy's testnet branch fires regardless of what the
  -- daemon's default chain happens to be.
  let ppChainId : Nat := 11155111
  let allowed := LeanKohaku.Privacy.Bridge.policyAllows cfg.policy
    .configuredNode .direct bridgeReq (some ppChainId)
  if !allowed then
    pure <| .error
      { code := -32030
        message := "shielded surface denied by policy"
        data := some (.str ("policy denies " ++ method)) }
  else
    -- Pick the Sepolia endpoint, not cfg.rpcEndpoint. Without this the
    -- sidecar gets handed the mainnet URL when the daemon's default is
    -- mainnet, then the on-chain calls fail or hit the wrong contract.
    let ppEndpoint : LeanKohaku.RPC.Outbound.Endpoint :=
      match endpointForChain cfg (some "sepolia") with
      | .ok ep => ep
      | .error _ => cfg.rpcEndpoint
    let ppDir ← LeanKohaku.Wallet.PpSecretStore.storeDir
    try IO.FS.createDirAll ppDir catch _ => pure ()
    let statePath := (ppDir / "state.json").toString
    let storagePath := (ppDir / "storage.json").toString
    -- Railgun has its own encrypted secret store (`RgSecretStore`) and a
    -- separate on-disk storage file. The mnemonic isolation invariant
    -- (railgun secret never appears in PP method env, PP secret never
    -- appears in railgun method env) is enforced by conditionally
    -- emitting LEANKOHAKU_*_MNEMONIC env vars below.
    let rgDir ← LeanKohaku.Wallet.RgSecretStore.storeDir
    try IO.FS.createDirAll rgDir catch _ => pure ()
    let rgStoragePath := (rgDir / "storage.json").toString
    let baseEnv : Array (String × Option String) := #[
      ("LEANKOHAKU_RPC_URL", some ppEndpoint.url),
      ("LEANKOHAKU_CHAIN_ID", some (toString ppChainId)),
      ("LEANKOHAKU_PP_STATE_PATH", some statePath),
      ("LEANKOHAKU_PP_STORAGE_PATH", some storagePath),
      ("LEANKOHAKU_RG_STORAGE_PATH", some rgStoragePath)
    ]
    let env : Array (String × Option String) :=
      baseEnv
      ++ (match ppMnemonic? with
          | some m => #[("LEANKOHAKU_PP_MNEMONIC", some m)]
          | none   => #[])
      ++ (match rgMnemonic? with
          | some m => #[("LEANKOHAKU_RG_MNEMONIC", some m)]
          | none   => #[])
      ++ (match rgBundlerUrl? with
          | some u => #[("LEANKOHAKU_RG_BUNDLER_URL", some u)]
          | none   => #[])
      ++ (match rgDelegatingKeyHex? with
          | some k => #[("LEANKOHAKU_RG_DELEGATING_KEY", some k)]
          | none   => #[])
      ++ (match rgSeedHex? with
          | some s => #[("LEANKOHAKU_RG_SEED_HEX", some s)]
          | none   => #[])
    let resp ← LeanKohaku.Privacy.Bridge.callWithEnv bridgeReq env
    -- Propagate bridge errors as JSON-RPC errors instead of burying them
    -- inside a successful `{ok:false, error:…}` payload. Without this the
    -- TUI/CLI render the wrapper as a successful result and the user only
    -- learns the broadcast failed by reading the JSON — which is exactly
    -- the bug that surfaced with PP v1 `RelayFeeGreaterThanMax`. The
    -- success branch now hands callers the raw bridge result; callers
    -- that previously peeled `result` still work because they fall back
    -- to the top-level object.
    match resp with
    | .ok j => pure (.ok j)
    | .err code msg data =>
        pure <| .error { code := code, message := msg, data := data }
    | .crash stderr exitCode =>
        pure <| .error
          { code := -32603,
            message := s!"shielded bridge crashed (exit {exitCode})",
            data := some (.obj #[
              ("stderr", .str stderr),
              ("exitCode", .num (Int.ofNat exitCode.toNat))
            ]) }

/-- Load the on-disk PP secret if present, decrypt it with the supplied
    passphrase, and return the plaintext mnemonic. Returns `-32021` when
    no record exists, and `-32011` when decryption fails. -/
private def unlockPpSecret (passphrase : String) : IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
    pure (.error ppSecretMissing)
  else
    match ← LeanKohaku.Wallet.PpSecretStore.unlock passphrase with
    | .ok phrase => pure (.ok phrase)
    | .error err =>
        pure <| .error
          { code := -32011, message := "PP secret unlock failed", data := some (.str err) }

/-- Master-aware PP unlock. Prefers the wallet KEK when:
    (a) the daemon currently holds a master KEK in `DaemonState`,
    (b) the PP record carries a `masterWrap` field,
    (c) the caller did NOT supply an explicit `passphrase` parameter
    (an explicit per-PP passphrase wins so users can still override).

    Falls back to `unlockPpSecret` with the explicit (or empty) passphrase
    on miss. After a successful per-PP unlock with the master KEK loaded,
    attaches a `masterWrap` to the on-disk record so subsequent unlocks
    can come through the master path — same lazy-enrolment policy as
    EOA slots. -/
private def unlockPpSecretSmart (state : LeanKohaku.Daemon.State.Shared)
    (passphrase? : Option String) : IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
    pure (.error ppSecretMissing)
  else
    match passphrase? with
    | none =>
        match ← LeanKohaku.Daemon.State.getMasterKek? state with
        | none =>
            pure <| .error
              { code := -32011, message := "PP secret unlock failed",
                data := some (.str "no passphrase supplied and wallet master is locked") }
        | some slot =>
            match ← LeanKohaku.Wallet.PpSecretStore.unlockWithMaster slot.kek with
            | .ok phrase => pure (.ok phrase)
            | .error err =>
                pure <| .error
                  { code := -32011, message := "PP secret unlock failed",
                    data := some (.str err) }
    | some p =>
        match ← LeanKohaku.Wallet.PpSecretStore.unlock p with
        | .error err =>
            pure <| .error
              { code := -32011, message := "PP secret unlock failed",
                data := some (.str err) }
        | .ok phrase =>
            -- Lazy enrol the PP record into the master KEK when both
            -- credentials are present in this call. Best-effort; failure
            -- to attach must not fail the unlock.
            (do
              match ← LeanKohaku.Daemon.State.getMasterKek? state with
              | none => pure ()
              | some slot =>
                  -- Skip if already enrolled to avoid an extra disk write
                  -- on every PP-passphrase unlock.
                  match ← LeanKohaku.Wallet.PpSecretStore.unlockWithMaster slot.kek with
                  | .ok _ => pure ()
                  | .error _ =>
                      match ← LeanKohaku.Wallet.PpSecretStore.attachMasterWrap slot.kek phrase with
                      | .ok _ => pure ()
                      | .error _ => pure ())
            pure (.ok phrase)

/-- JSON-RPC error code for a missing Railgun secret on disk. Separate
    from `ppSecretMissing` so the CLI surfaces the right "no railgun
    secret" hint and so the lazy-init path can detect the specific
    missing-secret case without string matching. -/
private def rgSecretMissing : RpcError :=
  { code := -32023
    message := "no Railgun secret stored — run 'kohaku shield railgun <wallet> <eth>' to create one or 'kohaku shield railgun import <mnemonic>' to restore"
    data := none }

/-- Master-aware Railgun unlock. Mirror of `unlockPpSecretSmart` but
    reads from `RgSecretStore`. Returns `rgSecretMissing` (code -32023)
    when the file does not exist so callers can detect first-time setup
    and route to the lazy-init path. -/
private def unlockRgSecretSmart (state : LeanKohaku.Daemon.State.Shared)
    (passphrase? : Option String) : IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.RgSecretStore.existsOnDisk) then
    pure (.error rgSecretMissing)
  else
    match passphrase? with
    | none =>
        match ← LeanKohaku.Daemon.State.getMasterKek? state with
        | none =>
            pure <| .error
              { code := -32011, message := "Railgun secret unlock failed",
                data := some (.str "no passphrase supplied and wallet master is locked") }
        | some slot =>
            match ← LeanKohaku.Wallet.RgSecretStore.unlockWithMaster slot.kek with
            | .ok phrase => pure (.ok phrase)
            | .error err =>
                pure <| .error
                  { code := -32011, message := "Railgun secret unlock failed",
                    data := some (.str err) }
    | some p =>
        match ← LeanKohaku.Wallet.RgSecretStore.unlock p with
        | .error err =>
            pure <| .error
              { code := -32011, message := "Railgun secret unlock failed",
                data := some (.str err) }
        | .ok phrase =>
            -- Lazy-enrol into the wallet master KEK on per-secret unlock.
            (do
              match ← LeanKohaku.Daemon.State.getMasterKek? state with
              | none => pure ()
              | some slot =>
                  match ← LeanKohaku.Wallet.RgSecretStore.unlockWithMaster slot.kek with
                  | .ok _ => pure ()
                  | .error _ =>
                      match ← LeanKohaku.Wallet.RgSecretStore.attachMasterWrap slot.kek phrase with
                      | .ok _ => pure ()
                      | .error _ => pure ())
            pure (.ok phrase)

-- TODO(railgun): re-attach this docstring to its function (likely
-- `unlockOrLazyInitRgSecret`). It became orphaned during the
-- railgun-alpha-21 merge; Lean 4 rejects two consecutive `/-- -/`
-- docstrings with no declaration between them.
--   Unlock the Railgun secret if present, otherwise generate a fresh
--   BIP-39 mnemonic, persist it via `RgSecretStore.save`, enrol into
--   the wallet master KEK (best-effort), and return the plaintext
--   phrase. Mirrors the lazy-init in PP's `shielded.deposit` handler
--   but writes to the Railgun store. Used by `shielded.railgun.shield`
--   so first-time shielding into Railgun "just works" without a
--   separate setup step, while still keeping the Railgun spending
--   secret cryptographically isolated from the PP and EOA secrets.
/-- The Railgun keystore is rooted at the EOA's master BIP-39 seed.
    Railgun derives at its own BIP-32 paths (via
    `RailgunSigner.spendingKeyPath` / `viewingKeyPath`), disjoint from
    BIP-44 Ethereum, so the same seed root yields independent Railgun
    spending/viewing keys. One mnemonic on disk, one unlock surface.

    Returns the seed of the named wallet's currently-unlocked slot
    encoded as 0x-prefixed hex, ready to pass to the bridge as
    `LEANKOHAKU_RG_SEED_HEX`. Errors if the slot is locked. -/
private def rgSeedHexFromSlot
    (slot : LeanKohaku.Daemon.State.UnlockedSlot) : String :=
  -- Hex.encode emits an already-`0x`-prefixed string (`Crypto/Hex.lean`
  -- line 25), so we pass its output through verbatim. Double-prefixing
  -- here would produce `0x0x…` which the bridge's keystoreFromSeedHex
  -- rejects after stripping the leading `0x` once.
  LeanKohaku.Crypto.Hex.encode slot.seed

/-- Default-wallet variant of `rgSeedHexFromSlot`. Resolution order:

      1. `defaultAccountPathIO` (set by `kohaku wallet use <name>` or
         the `account.setDefault` RPC).
      2. If no default is set, fall back to the **single** currently
         unlocked slot in `state.unlocked`. This covers the common
         "I have one EOA, just unlocked it via master KEK" case
         without forcing the user to also run `wallet use`.

    Returns `-32013` if neither step yields a wallet, or `-32012`
    (slot locked) if the resolved name isn't in `state.unlocked`. -/
private def rgSeedHexFromDefault
    (state : LeanKohaku.Daemon.State.Shared) : IO (Except RpcError String) := do
  let defaultPath ← defaultAccountPathIO
  let defaultName? : Option String ← do
    if ← defaultPath.pathExists then
      let raw ← try IO.FS.readFile defaultPath catch _ => pure ""
      let trimmed := raw.trimAscii.toString
      pure (if trimmed.isEmpty then none else some trimmed)
    else pure none
  match defaultName? with
  | some name =>
      match ← unlockedSlot state name with
      | .error err => pure (.error err)
      | .ok slot => pure (.ok (rgSeedHexFromSlot slot))
  | none =>
      -- No default configured. If exactly one slot is currently
      -- unlocked, use it — that's the user's intent in the
      -- single-wallet / master-KEK-unlock-then-balance flow.
      let unlocked := (← state.get).unlocked
      match unlocked with
      | [slot] => pure (.ok (rgSeedHexFromSlot slot))
      | [] =>
          pure <| .error
            { code := -32013,
              message := "no default wallet set and no slot unlocked — unlock a wallet (`kohaku wallet unlock <name>`) or set a default (`kohaku wallet use <name>`)",
              data := none }
      | _ :: _ :: _ =>
          pure <| .error
            { code := -32013,
              message := "no default wallet set and multiple slots are unlocked — pick one with `kohaku wallet use <name>` or pass `name` explicitly to the RPC",
              data := none }

private def unlockOrCreateRgSecret
    (state : LeanKohaku.Daemon.State.Shared) (passphrase? : Option String) :
    IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.RgSecretStore.existsOnDisk) then
    IO.eprintln "[shield-rg] no Railgun secret on disk; generating fresh 12-word mnemonic"
    try
      let m ← LeanKohaku.Wallet.Entropy.generateMnemonic 12
      let phrase := LeanKohaku.Wallet.Mnemonic.phrase m
      let pass ← match passphrase? with
        | some p => pure p
        | none =>
            -- Same throwaway-passphrase pattern as PP: the durable unlock
            -- path is the master-wrap attached immediately after save.
            let r ← LeanKohaku.Crypto.Random.getRandomBytes 32
            pure (LeanKohaku.Crypto.Hex.encode r)
      match ← LeanKohaku.Wallet.RgSecretStore.save pass phrase with
      | .error err =>
          pure (.error
            ({ code := -32022,
               message := "failed to persist generated Railgun secret",
               data := some (.str err) } : RpcError))
      | .ok _ =>
          (do
            match ← LeanKohaku.Daemon.State.getMasterKek? state with
            | none => pure ()
            | some s =>
                let _ ← LeanKohaku.Wallet.RgSecretStore.attachMasterWrap s.kek phrase
                pure ())
          IO.eprintln "[shield-rg] Railgun secret generated and persisted"
          pure (.ok phrase)
    catch e =>
      pure (.error
        ({ code := -32022,
           message := "failed to generate Railgun secret",
           data := some (.str e.toString) } : RpcError))
  else
    IO.eprintln "[shield-rg] decrypting stored Railgun secret"
    unlockRgSecretSmart state passphrase?

/-- Default broadcast-confirmation timeout. Overridable per-call via the
    `LEANKOHAKU_BROADCAST_TIMEOUT_SECS` env var so the user can wait
    longer on congested networks without a rebuild. -/
private def defaultBroadcastTimeoutSecs' : Nat := 90

private def broadcastTimeoutSecs' : IO Nat := do
  match ← IO.getEnv "LEANKOHAKU_BROADCAST_TIMEOUT_SECS" with
  | some s =>
      match s.toNat? with
      | some n => pure n
      | none => pure defaultBroadcastTimeoutSecs'
  | none => pure defaultBroadcastTimeoutSecs'

/-- Poll `eth_getTransactionReceipt` until mined or the timeout elapses.
    Mirrors `waitForReceipt` but keeps a forward declaration so it can
    be reused by `broadcastAndAwait` without re-shuffling the file. -/
private partial def waitForReceiptShared
    (cfg : Config) (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (txHash : String) (deadlineMs startMs : Nat)
    (via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none) :
    IO (Except String Json) := do
  let now ← IO.monoMsNow
  if now ≥ deadlineMs then
    pure (.error s!"timed out waiting for receipt after {(now - startMs) / 1000}s")
  else
    match ← LeanKohaku.RPC.Outbound.getTransactionReceipt cfg.policy cfg.rpcEndpoint txHash via? with
    | .error err => pure (.error err)
    | .ok json =>
        match json with
        | .null =>
            notify "tx-pending" (.obj #[
              ("txHash", .str txHash),
              ("elapsedSec", .num (Int.ofNat ((now - startMs) / 1000)))
            ])
            IO.sleep 5000
            waitForReceiptShared cfg notify txHash deadlineMs startMs via?
        | _ => pure (.ok json)

/-- Broadcast a signed raw EIP-1559 tx and await its receipt, streaming
    `tx-broadcasted`, `tx-pending`, and `tx-mined` (or `tx-timeout`)
    notifications on the supplied notifier.

    Returns an extras JSON object with the broadcast/receipt fields
    that callers merge into their result payload:
      - `txHash`        : tx hash from `eth_sendRawTransaction`
      - `status`        : `"success" | "revert" | "pending"`
      - `blockNumber`   : 0x-hex block number (when mined)
      - `gasUsed`       : 0x-hex gas used (when mined)
      - `effectiveGasPrice` : 0x-hex effective gas price (when mined)
      - `receipt`       : raw receipt object (when mined)
      - `error`         : timeout/RPC error string (when pending)
    Existing callers are responsible for adding their own fields
    (e.g. `raw`, `signature`, `nonce`, ...). -/
private def broadcastAndAwait
    (cfg : Config) (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (rawTxHex from_ to : String) (valueWei : Nat)
    (via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none) :
    IO (Except RpcError Json) := do
  match ← LeanKohaku.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint rawTxHex with
  | .error err =>
      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | .ok txHashJson =>
      match txHashJson with
      | .str txHash =>
          notify "tx-broadcasted" (.obj #[
            ("txHash", .str txHash),
            ("from", .str from_),
            ("to", .str to),
            ("valueWei", .str (toString valueWei))
          ])
          let timeoutSecs ← broadcastTimeoutSecs'
          let startMs ← IO.monoMsNow
          let deadlineMs := startMs + timeoutSecs * 1000
          match ← waitForReceiptShared cfg notify txHash deadlineMs startMs via? with
          | .error err =>
              notify "tx-timeout" (.obj #[
                ("txHash", .str txHash),
                ("error", .str err)
              ])
              pure <| .ok <| .obj #[
                ("txHash", .str txHash),
                ("status", .str "pending"),
                ("error", .str err)
              ]
          | .ok receipt =>
              let blockNumber := (getField "blockNumber" receipt >>= asString).getD ""
              let gasUsed := (getField "gasUsed" receipt >>= asString).getD ""
              let effectiveGasPrice :=
                (getField "effectiveGasPrice" receipt >>= asString).getD ""
              let statusHex := (getField "status" receipt >>= asString).getD "0x0"
              let success := statusHex == "0x1"
              notify "tx-mined" (.obj #[
                ("txHash", .str txHash),
                ("blockNumber", .str blockNumber),
                ("gasUsed", .str gasUsed),
                ("effectiveGasPrice", .str effectiveGasPrice),
                ("status", .str (if success then "success" else "revert"))
              ])
              pure <| .ok <| .obj #[
                ("txHash", .str txHash),
                ("status", .str (if success then "success" else "revert")),
                ("blockNumber", .str blockNumber),
                ("gasUsed", .str gasUsed),
                ("effectiveGasPrice", .str effectiveGasPrice),
                ("receipt", receipt)
              ]
      | _ =>
          pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str "eth_sendRawTransaction returned non-string result") }

/-- Sepolia's `eth_maxPriorityFeePerGas` reports values as low as
    0x15f900 (1.44 mwei ≈ 0.00144 gwei) because validators see almost no
    real fee demand. Submitting that as the tip strands txns: most
    Sepolia nodes drop them from the mempool, and even when broadcast
    they sit indefinitely behind their own nonce. 1 gwei is the de-facto
    floor every public Sepolia faucet/relayer uses and is rounding error
    against real costs on mainnet too. -/
private def minPriorityFeeWei : Nat := 1_000_000_000

/-- Build, sign, and broadcast a single EIP-1559 transaction from an
    unlocked slot. If `nonceOverride?` is `some n`, that nonce is used
    instead of querying `eth_getTransactionCount` — needed when
    broadcasting a sequence of txns from one prepare call.

    The `notify?` argument, when provided, enables receipt-await with
    streamed `tx-broadcasted`/`tx-pending`/`tx-mined` notifications and
    augments the result JSON with `status`, `blockNumber`, `gasUsed`,
    `effectiveGasPrice`, and `receipt`. When `none`, the legacy
    fire-and-forget broadcast path is used (no waiting). -/
private def buildSignBroadcastTx
    (cfg : Config) (slot : LeanKohaku.Daemon.State.UnlockedSlot)
    (privateKey : ByteArray) (to : String) (toAddress : LeanKohaku.Ethereum.Address.Address)
    (value : Nat) (data : ByteArray) (nonceOverride? : Option Nat)
    (notify? : Option LeanKohaku.Keystore.Tpm2Runtime.Notifier := none)
    (via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none)
    (priorityFeeOverride? : Option Nat := none) :
    IO (Except RpcError Json) := do
  try
    let nonce ←
      match nonceOverride? with
      | some n => pure n
      | none =>
          let nonceJson ← expectExcept <| (← LeanKohaku.RPC.Outbound.getTransactionCount cfg.policy cfg.rpcEndpoint slot.address "pending" via?)
          jsonHexNatIO nonceJson "nonce"
    let priorityJson ← expectExcept <| (← LeanKohaku.RPC.Outbound.maxPriorityFeePerGas cfg.policy cfg.rpcEndpoint via?)
    let gasPriceJson ← expectExcept <| (← LeanKohaku.RPC.Outbound.gasPrice cfg.policy cfg.rpcEndpoint via?)
    let rpcPriorityFee ← jsonHexNatIO priorityJson "maxPriorityFeePerGas"
    -- Explicit override wins (used by `eoa.dropNonce`, where the caller has
    -- picked an aggressive tip to outbid the stuck pending tx). Otherwise
    -- apply the floor so the silly-low Sepolia RPC value doesn't strand us.
    let maxPriorityFeePerGas :=
      match priorityFeeOverride? with
      | some t => t
      | none   => Nat.max rpcPriorityFee minPriorityFeeWei
    let gasPrice ← jsonHexNatIO gasPriceJson "gasPrice"
    -- 2× basefee headroom: `eth_gasPrice` is a moment-in-time snapshot
    -- (basefee + suggested tip). Submitting at exactly that cap means
    -- any basefee bump between assembly and inclusion strands the tx
    -- in the mempool (saw this with sphincs.account.deploy at 1.106
    -- gwei vs network basefee 1.224). Mirrors the same fix already
    -- applied in `executeSphincsUserOp` for the bundler's floor.
    -- Cost-safe: validators only collect actual basefee + tip, not the
    -- cap, so this raises the success rate without raising the bill.
    let maxFeePerGas := 2 * gasPrice + maxPriorityFeePerGas
    let estimateRequest := estimateTxJson slot.address to value data
    -- Pin estimateGas to direct RPC. Colibri's stateless EVM verifies
    -- state reads against committee proofs, but can't faithfully replay
    -- multicall / router calls (Aave supply, Uniswap V3 swap, Morpho
    -- bundler, etc.) — its light-client validation surfaces those as
    -- spurious "execution reverted" errors. `tx.simulate` already pins
    -- itself to direct RPC for this exact reason; we apply the same fix
    -- here so the send-path gas estimate doesn't fail on contracts that
    -- the pre-send simulate succeeded against. Other reads in this
    -- function (nonce, gasPrice, maxPriorityFeePerGas) are simple state
    -- queries that Colibri handles correctly, so they keep `via?`.
    let gasJson ← expectExcept <| (← LeanKohaku.RPC.Outbound.estimateGas cfg.policy cfg.rpcEndpoint estimateRequest "latest" none)
    let gasLimit ← jsonHexNatIO gasJson "gasLimit"
    let tx : LeanKohaku.Ethereum.Tx.TxEip1559 := {
      chainId := cfg.chainId,
      nonce := nonce,
      maxPriorityFeePerGas := maxPriorityFeePerGas,
      maxFeePerGas := maxFeePerGas,
      gasLimit := gasLimit,
      to := some toAddress,
      value := value,
      data := data,
      accessList := []
    }
    match ← LeanKohaku.Wallet.EOA.signEip1559IO tx privateKey with
    | .error err =>
        pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
    | .ok signed =>
        let raw := LeanKohaku.Crypto.Hex.encode signed.encode
        match notify? with
        | none =>
            -- Legacy path: fire-and-forget broadcast, no receipt wait.
            match ← LeanKohaku.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint raw with
            | .error err =>
                pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
            | .ok txHashJson =>
                match txHashJson with
                | .str txHash =>
                    pure <| .ok <| sendResultJson to (toString value) raw txHash
                      nonce gasLimit maxPriorityFeePerGas maxFeePerGas signed.sig
                | _ =>
                    pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str "eth_sendRawTransaction returned non-string result") }
        | some notify =>
            -- Notifier-aware path: broadcast, stream notifications, await receipt.
            match ← broadcastAndAwait cfg notify raw slot.address to value via? with
            | .error err => pure (.error err)
            | .ok extras =>
                let txHash := (getField "txHash" extras >>= asString).getD ""
                let base := sendResultJson to (toString value) raw txHash
                  nonce gasLimit maxPriorityFeePerGas maxFeePerGas signed.sig
                -- Merge extras (status, blockNumber, gasUsed, effectiveGasPrice, receipt, [error]).
                match base, extras with
                | .obj baseFields, .obj extraFields =>
                    -- Drop duplicate `txHash` from extras (already in base).
                    let merged := extraFields.foldl
                      (fun acc (k, v) =>
                        if k == "txHash" then acc else acc.push (k, v))
                      baseFields
                    pure (.ok (.obj merged))
                | _, _ => pure (.ok base)
  catch e =>
    pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str e.toString) }

/-- Decode a single bridge-returned tx object `{to, data, value}`. The
    bridge serialises bigints as 0x-hex strings; `value` may be missing
    for zero-value calls. -/
private def parseBridgeTx (json : Json) :
    Except RpcError (String × LeanKohaku.Ethereum.Address.Address × Nat × ByteArray) := do
  let toStr ← match getField "to" json >>= asString with
    | some s => .ok s
    | none => .error invalidParams
  let toAddr ← match LeanKohaku.Ethereum.Address.fromHex toStr with
    | some a => .ok a
    | none => .error invalidParams
  let dataStr ← match getField "data" json >>= asString with
    | some s => .ok s
    | none => .error invalidParams
  let data ← match LeanKohaku.Crypto.Hex.decode dataStr with
    | some b => .ok b
    | none => .error invalidParams
  let value ← match getField "value" json with
    | none => .ok 0
    | some .null => .ok 0
    | some j =>
        match asString j with
        | some s =>
            match parseHexQuantity s with
            | some n => .ok n
            | none => .error invalidParams
        | none =>
            match asNat j with
            | some n => .ok n
            | none => .error invalidParams
  .ok (toStr, toAddr, value, data)

/-- Loop signing and broadcasting prepared bridge txns sequentially,
    incrementing the nonce locally. Returns an array of per-tx send
    results, or the first error. -/
private def signAndBroadcastBridgeTxns
    (cfg : Config) (slot : LeanKohaku.Daemon.State.UnlockedSlot)
    (privateKey : ByteArray) (txns : Array Json)
    (notify? : Option LeanKohaku.Keystore.Tpm2Runtime.Notifier := none)
    (via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none)
    (actionTag : String := "shielded.deposit") :
    IO (Except RpcError (Array Json)) := do
  let baseNonceJson ← LeanKohaku.RPC.Outbound.getTransactionCount cfg.policy cfg.rpcEndpoint slot.address "pending" via?
  match baseNonceJson with
  | .error err =>
      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | .ok nj =>
      match jsonHexNat nj with
      | .error err => pure (.error err)
      | .ok baseNonce =>
          let mut results : Array Json := #[]
          let mut idx : Nat := 0
          for raw in txns do
            match parseBridgeTx raw with
            | .error err => return .error err
            | .ok (toStr, toAddr, value, data) =>
                match ← buildSignBroadcastTx cfg slot privateKey toStr toAddr value data (some (baseNonce + idx)) notify? via? with
                | .error err => return .error err
                | .ok j =>
                    -- Why: best-effort shielded.deposit journal entry per broadcast tx.
                    let getStr (k : String) : String :=
                      (getField k j >>= asString).getD ""
                    let txHash := getStr "txHash"
                    let dataHex := LeanKohaku.Crypto.Hex.encode data
                    let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                    let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                    let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                    if !txHash.isEmpty then
                      journalRecord slot.name slot.address toStr txHash dataHex actionTag
                        value (baseNonce + idx) cfg.chainId none status? block? gas?
                    results := results.push j
                    idx := idx + 1
          pure (.ok results)

/-- Default broadcast-confirmation timeout. Overridable per-call via the
    `LEANKOHAKU_BROADCAST_TIMEOUT_SECS` env var so the user can wait
    longer on congested networks without a rebuild. -/
private def defaultBroadcastTimeoutSecs : Nat := 90

private def broadcastTimeoutSecs : IO Nat := do
  match ← IO.getEnv "LEANKOHAKU_BROADCAST_TIMEOUT_SECS" with
  | some s =>
      match s.toNat? with
      | some n => pure n
      | none => pure defaultBroadcastTimeoutSecs
  | none => pure defaultBroadcastTimeoutSecs

/-- Parse a `0x`-prefixed transaction hash printed by cast's --async
    output. cast prints the hex on a line by itself. -/
private def extractTxHash (stdout : String) : Option String := do
  let lines := (stdout.splitOn "\n").map (·.trimAscii.toString)
  lines.find? (fun line =>
    line.startsWith "0x" && line.length == 66 &&
      ((line.toList.drop 2).all (fun c =>
        ('0' ≤ c ∧ c ≤ '9') || ('a' ≤ c ∧ c ≤ 'f') || ('A' ≤ c ∧ c ≤ 'F'))))

/-- Parse a raw signed EIP-1559 tx hex printed by `cast mktx`. The
    command emits a single `0x02…` line (typed-2 envelope, RLP-encoded);
    we accept any 0x-prefixed even-length hex line that is unambiguously
    longer than a 32-byte hash (so we don't confuse it with an extra
    txhash line some cast builds may emit). -/
private def extractRawSignedTx (stdout : String) : Option String := do
  let lines := (stdout.splitOn "\n").map (·.trimAscii.toString)
  lines.find? (fun line =>
    line.startsWith "0x" && line.length > 66 && line.length % 2 == 0 &&
      ((line.toList.drop 2).all (fun c =>
        ('0' ≤ c ∧ c ≤ '9') || ('a' ≤ c ∧ c ≤ 'f') || ('A' ≤ c ∧ c ≤ 'F'))))

/-- Poll `eth_getTransactionReceipt` until the tx is mined or the
    timeout elapses. Emits `tx-pending` notifications every poll while
    the receipt is still null. Returns the receipt JSON on success, or
    a string error on timeout / RPC failure. -/
private partial def waitForReceipt
    (cfg : Config) (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (txHash : String) (deadlineMs startMs : Nat)
    (via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none) :
    IO (Except String Json) := do
  let now ← IO.monoMsNow
  if now ≥ deadlineMs then
    pure (.error s!"timed out waiting for receipt after {(now - startMs) / 1000}s")
  else
    match ← LeanKohaku.RPC.Outbound.getTransactionReceipt cfg.policy cfg.rpcEndpoint txHash via? with
    | .error err => pure (.error err)
    | .ok json =>
        match json with
        | .null =>
            notify "tx-pending" (.obj #[
              ("txHash", .str txHash),
              ("elapsedSec", .num (Int.ofNat ((now - startMs) / 1000)))
            ])
            IO.sleep 5000
            waitForReceipt cfg notify txHash deadlineMs startMs via?
        | _ => pure (.ok json)

/-- End-to-end R1 send flow:
    1. shell out to `prepare-digest(-eth)` to compute the digest;
    2. natively run `signSepoliaDigest` so PIN notifications stream live;
    3. shell out to `broadcast-signed` (which uses `cast send --async`);
    4. poll `eth_getTransactionReceipt` until mined or timeout, with
       `tx-broadcasted`, `tx-pending`, `tx-mined` notifications.
    The script-side calls are still captured via `IO.Process.output`,
    but the TPM auth-value check is now in-process Lean and reaches the
    CLI in real time over the existing UDS notification channel. -/
private def r1SendFlow (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (keyName to : String) (amount : String) (mode : String)
    (pin : String)
    (data? : Option String := none) :
    IO (Except RpcError Json) := do
  let scriptEnv : Array (String × Option String) := #[("LEAN_KOHAKU_TPM_KEY", some keyName)]
  -- Step 1: digest preparation. The script prints `<digest> <account> <wei>`
  -- on stdout and any `cast`/setup chatter on stderr.
  -- When `data?` is `none`, no extra arg is appended — preserving byte-identical
  -- behaviour for the value-only callers (`r1.sendSepolia`, `r1.sendEthSepolia`).
  -- When `some hex`, the script's optional `[data-hex]` 4th positional arg is
  -- forwarded to `prepare-digest(-eth)` and `broadcast-signed`.
  let dataArgs : Array String :=
    match data? with
    | some d => #[d]
    | none   => #[]
  let prepArgs : Array String :=
    if mode == "eth" then #["prepare-digest-eth", to, amount] ++ dataArgs
    else #["prepare-digest", to, amount] ++ dataArgs
  let (prepCode, prepOut, prepErr) ← runScriptSplit cfg prepArgs scriptEnv
  if prepCode != 0 then
    return .error
      { code := -32040,
        message := "r1 digest preparation failed",
        data := some (.str (prepOut ++ prepErr)) }
  let tokens := prepOut.trimAscii.toString.splitOn " " |>.filter (fun t => t.trimAscii.toString != "")
  match tokens with
  | digest :: account :: wei :: _ =>
      -- Step 2: native TPM2 sign with PIN auth value (live notifications).
      let report ← signSepoliaDigest digest pin { keyName := keyName } notify
      match report.status with
      | .signed =>
          let some sigHex := report.signatureHex
            | pure (.error
                { code := -32041,
                  message := "tpm sign returned no signature hex",
                  data := none })
          -- Step 3a: have the script ABI-encode + sign the EIP-1559
          -- envelope locally (relayer EOA pays gas) but NOT broadcast —
          -- it prints the raw signed tx hex. Append optional data hex so
          -- the signed tx carries calldata when the caller is
          -- `r1.sendRawSepolia`.
          let (bcCode, bcOut, bcErr) ← runScriptSplit cfg
            (#["broadcast-signed", sigHex, to, wei] ++ dataArgs) scriptEnv
          if bcCode != 0 then
            return .error
              { code := -32042,
                message := "r1 mktx failed",
                data := some (.str (bcOut ++ bcErr)) }
          let some rawTx := extractRawSignedTx bcOut
            | pure <| .error
                { code := -32042,
                  message := "could not parse raw signed tx from mktx output",
                  data := some (.str (bcOut ++ bcErr)) }
          -- Step 3b: broadcast through Outbound so the call lands in the
          -- daemon's network log (network monitor / audit trail). The
          -- response is the txHash string — that's the canonical hash
          -- per eth_sendRawTransaction.
          let txHashJson ← LeanKohaku.RPC.Outbound.sendRawTransaction
            cfg.policy cfg.rpcEndpoint rawTx
          match txHashJson with
          | .error err =>
              pure <| .error
                { code := -32020,
                  message := "chain RPC failed",
                  data := some (.str err) }
          | .ok j =>
            match asString j with
            | none =>
                pure <| .error
                  { code := -32020,
                    message := "chain RPC failed",
                    data := some (.str "eth_sendRawTransaction returned non-string result") }
            | some txHash =>
              notify "tx-broadcasted" (.obj #[
                ("txHash", .str txHash),
                ("from", .str account),
                ("to", .str to),
                ("valueWei", .str wei)
              ])
              -- Step 4: wait for receipt with periodic notifications.
              let timeoutSecs ← broadcastTimeoutSecs
              let startMs ← IO.monoMsNow
              let deadlineMs := startMs + timeoutSecs * 1000
              let via? ← colibriVia state cfg.chainId
              match ← waitForReceipt cfg notify txHash deadlineMs startMs via? with
              | .error err =>
                  let weiN := wei.toNat?.getD 0
                  let dataHexJ := data?.getD ""
                  journalRecord keyName account to txHash dataHexJ "r1.send"
                    weiN 0 cfg.chainId none (some "pending") none none
                  pure <| .ok <| .obj #[
                    ("text", .str s!"R1 send broadcast {txHash} but receipt wait failed: {err}\n"),
                    ("exitCode", .num 1),
                    ("status", .str "pending"),
                    ("txHash", .str txHash),
                    ("from", .str account),
                    ("to", .str to),
                    ("valueWei", .str wei),
                    ("error", .str err)
                  ]
              | .ok receipt =>
                  let blockNumber := (getField "blockNumber" receipt >>= asString).getD ""
                  let gasUsed := (getField "gasUsed" receipt >>= asString).getD ""
                  let effectiveGasPrice :=
                    (getField "effectiveGasPrice" receipt >>= asString).getD ""
                  let statusHex := (getField "status" receipt >>= asString).getD "0x0"
                  let success := statusHex == "0x1"
                  notify "tx-mined" (.obj #[
                    ("txHash", .str txHash),
                    ("blockNumber", .str blockNumber),
                    ("gasUsed", .str gasUsed),
                    ("effectiveGasPrice", .str effectiveGasPrice),
                    ("status", .str (if success then "success" else "revert"))
                  ])
                  let weiN := wei.toNat?.getD 0
                  let dataHexJ := data?.getD ""
                  journalRecord keyName account to txHash dataHexJ "r1.send"
                    weiN 0 cfg.chainId none
                    (some (if success then "success" else "revert"))
                    (some blockNumber) (some gasUsed)
                  let summary :=
                    s!"R1 send {txHash}\n  from: {account}\n  to: {to}\n  value: {humanEth weiN}\n  block: {humanBlock blockNumber}\n  gasUsed: {humanGas gasUsed}\n  effectiveGasPrice: {humanGwei effectiveGasPrice}\n  status: {if success then "success" else "revert"}\n"
                  pure <| .ok <| .obj #[
                    ("text", .str summary),
                    ("exitCode", .num (Int.ofNat (if success then 0 else 1))),
                    ("status", .str (if success then "success" else "revert")),
                    ("txHash", .str txHash),
                    ("from", .str account),
                    ("to", .str to),
                    ("valueWei", .str wei),
                    ("blockNumber", .str blockNumber),
                    ("gasUsed", .str gasUsed),
                    ("effectiveGasPrice", .str effectiveGasPrice),
                    ("receipt", receipt)
                  ]
      | other =>
          pure <| .error
            { code := -32043,
              message := "tpm sign failed: " ++ signStatusText other,
              data := none }
  | _ =>
      pure <| .error
        { code := -32040,
          message := "r1 digest preparation produced unexpected output",
          data := some (.str prepOut) }

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
          match LeanKohaku.Encoding.Json.parse argsStr with
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
    -- Aave V3 Pool surface (see LeanKohaku/Aave/V3Pool.lean).
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
    (intent : LeanKohaku.Ethereum.Intent.Intent)
    (baseFields : Array (String × Json))
    (synthLabel : Option String)
    (chainId : Nat) :
    Json :=
  let canonical := LeanKohaku.Ethereum.IntentCanonical.toCanonicalString intent
  let actionTag := LeanKohaku.Ethereum.IntentCanonical.actionTag intent
  let synthArr : Array (String × Json) :=
    match synthLabel with
    | some s => #[("synth", .str s)]
    | none   => #[]
  let commonFields : Array (String × Json) :=
    baseFields ++ #[
      ("intentActionTag", .str actionTag),
      ("canonical",       .str canonical)
    ] ++ synthArr
  let addrJson (a : LeanKohaku.Ethereum.Address.Address) : Json :=
    .str (LeanKohaku.Crypto.Hex.encode a.bytes)
  match intent with
  | .shieldedDeposit _ amountWei =>
      let amountEth := LeanKohaku.Util.Units.formatUnits amountWei 18
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
      let amountEth := LeanKohaku.Util.Units.formatUnits amountWei 18
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
      let amountEth := LeanKohaku.Util.Units.formatUnits amountWei 18
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
      let amountEth := LeanKohaku.Util.Units.formatUnits amountWei 18
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
      let amountEth := LeanKohaku.Util.Units.formatUnits denominationWei 18
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
      let amountEth := LeanKohaku.Util.Units.formatUnits denominationWei 18
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
            ("kind",              .str (LeanKohaku.Ethereum.Intent.WalletKind.toString kind)),
            ("deployImmediately", .bool deployImmediately),
            ("chainId",           .num (Int.ofNat chainId))
          ] ++ labelEntry)
        ])
      ]
  | _ =>
      match LeanKohaku.Ethereum.IntentEncode.encode intent with
      | .error msg =>
          .obj <| commonFields ++ #[("encodeError", .str msg)]
      | .ok enc =>
          .obj <| commonFields ++ #[
            ("encoded", .obj #[
              ("to",      .str enc.to),
              ("value",   .num (Int.ofNat enc.valueWei)),
              ("data",    .str enc.data),
              ("chainId", .num (Int.ofNat chainId))
            ])
          ]

/-- "sepolia" / "mainnet" guess from chainId so callers can omit `chain`.
    Empty string for unknown ids — every consumer checks the `endpointForChain`
    result so a wrong guess can't silently route to the default chain. -/
private def chainNameGuess (cid : Nat) : String :=
  if cid = 11155111 then "sepolia"
  else if cid = 1 then "mainnet"
  else ""

/-- Best-effort: query the configured factory's `getAddress(...)` view and
    return the resulting smart-account address. Swallows every error so
    callers can use this opportunistically (e.g. auto-populating
    `smartAccountAddress` on a freshly created slot without making the
    create RPC fail when the factory isn't deployed yet). -/
private def tryComputeSmartAccountAddress (cfg : Config)
    (rec : LeanKohaku.Wallet.SphincsHybridStore.Record) : IO (Option String) := do
  let chainName := chainNameGuess rec.chainId
  match sphincsFactoryFor cfg chainName rec.paramSet,
        endpointForChain cfg (some chainName) with
  | .error _, _ | _, .error _ => pure none
  | .ok factory, .ok ep =>
      match ← LeanKohaku.Crypto.Hacl.keccak256EthereumIO
          (LeanKohaku.Crypto.Hex.encode "getAddress(address,bytes32,bytes32)".toByteArray) with
      | .error _ => pure none
      | .ok kh =>
          -- Build the calldata in ByteArray space and hex-encode once at
          -- the end. `Hex.encode` always prepends "0x", so the previous
          -- `"0x" ++ Hex.encode a ++ Hex.encode b ++ ...` pattern emitted
          -- strings with embedded "0x" substrings — Sepolia geth/erigon
          -- rejects them as "invalid hex string into hexutil.Bytes".
          let selBytes := kh.extract 0 4
          let ownerB := (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.ownerAddress).getD ByteArray.empty
          let pkSeedB := (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.pkSeed).getD ByteArray.empty
          let pkRootB := (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.pkRoot).getD ByteArray.empty
          let dataHex := LeanKohaku.Crypto.Hex.encode
            (selBytes ++ ownerB ++ pkSeedB ++ pkRootB)
          match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep factory dataHex "latest" none with
          | .error _ => pure none
          | .ok ret =>
              let s := (asString ret).getD ""
              let cleaned := if s.startsWith "0x" then (s.drop 2).toString else s
              if cleaned.length < 64 then pure none
              else pure (some ("0x" ++ String.ofList (cleaned.toList.drop (cleaned.length - 40))))

/-- Full SPHINCS- hybrid UserOperation pipeline: unlock the SPHINCS- sk,
    derive the ECDSA private key from the wallet attachment, fetch nonce
    + gas + domain separator, build initCode if the account isn't yet
    deployed, run bundler gas estimation, dual-sign the userOpHash, and
    submit via the configured bundler.

    `callData` is the `userOp.callData` field — the caller decides what
    target/value/data shape it carries (e.g. `execute(...)` from
    `sphincs.account.send` or a self-call from a future
    `rotateOwner`/`rotateKeys` RPC).

    `params` carries optional `passphrase` + `chain` overrides; only
    those two fields are consulted. -/
-- `innerTo` / `innerValue` / `innerData` describe what `execute(...)`
-- will dispatch to. Used both to build the UserOp's callData
-- (`buildExecuteCalldata`) and to populate the journal entry with the
-- user-meaningful to/value/data instead of the ABI-encoded envelope.
private partial def executeSphincsUserOp
    (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (rec : LeanKohaku.Wallet.SphincsHybridStore.Record)
    (innerTo : String) (innerValue : Nat) (innerData : ByteArray)
    (params : Json) :
    IO (Except RpcError Json) := do
  let callData := Sphincs.Send.buildExecuteCalldata innerTo innerValue innerData
  match rec.smartAccountAddress with
  | none =>
      pure <| .error
        { code := -32033,
          message := "smartAccountAddress unset — run sphincs.account.computeAddress (or .deploy) first",
          data := none }
  | some sender =>
      let chainName := paramStringD params "chain" (chainNameGuess rec.chainId)
      match sphincsBundlerFor cfg chainName,
            endpointForChain cfg (some chainName) with
      | .error e, _ | _, .error e =>
          pure <| .error
            { code := -32030, message := "sphincs bundler/endpoint unavailable",
              data := some (.str e) }
      | .ok bundlerUrl, .ok ep =>
          -- 1) Unlock SPHINCS- sk (master KEK first, slot passphrase fallback).
          let skResult : IO (Except String String) := do
            match ← LeanKohaku.Daemon.State.getMasterKek? state with
            | some mslot =>
                match ← LeanKohaku.Wallet.SphincsHybridStore.openWithMaster mslot.kek rec with
                | .ok sk => pure (.ok sk)
                | .error _ =>
                    match paramString params "passphrase" with
                    | .error _ => pure (.error "passphrase required (master path failed)")
                    | .ok pp => LeanKohaku.Wallet.SphincsHybridStore.openSk rec pp
            | none =>
                match paramString params "passphrase" with
                | .error _ => pure (.error "passphrase required (master KEK not loaded)")
                | .ok pp => LeanKohaku.Wallet.SphincsHybridStore.openSk rec pp
          match ← skResult with
          | .error e => pure <| .error { code := -32011, message := "sphincs sk unlock failed", data := some (.str e) }
          | .ok sphincsSkHex =>
              -- 2) Resolve ECDSA half via the wallet attachment.
              let attach := rec.ecdsaAttachment
              let walletName := match attach with
                | .existing wn _ => wn | .derived wn _ => wn
              match ← LeanKohaku.Wallet.EoaStore.load walletName with
              | .error e => pure <| .error { code := -32010, message := "wallet not found", data := some (.str e) }
              | .ok wRec =>
                  let pathExc : Except String String := match attach with
                    | .existing _ idx =>
                        match wRec.accounts.find? (fun a => a.index == idx) with
                        | some a => .ok a.path
                        | none => .error s!"wallet has no account #{idx}"
                    | .derived _ dp => .ok dp.asString
                  match pathExc with
                  | .error e => pure <| .error { code := -32012, message := "ecdsa path resolve failed", data := some (.str e) }
                  | .ok path =>
                      match ← unlockedSlot state walletName with
                      | .error e => pure (.error e)
                      | .ok wSlot =>
                          match ← derivePrivateKeyFromSeed wSlot.seed path with
                          | .error e => pure <| .error { code := -32012, message := "ecdsa key derive failed", data := some (.str e) }
                          | .ok privKey =>
                              -- 3) Nonce, gas, initCode. The nonce calldata is
                              -- entryPoint.getNonce(sender, key=0): selector ‖
                              -- pad32(sender) ‖ pad32(0). Build in ByteArray
                              -- and hex-encode once (Hex.encode always
                              -- prepends "0x", so a "++" of two
                              -- already-encoded strings would yield an
                              -- embedded-"0x" hex blob that the RPC rejects).
                              let nonceSelBytes :=
                                (LeanKohaku.Crypto.Hex.decode
                                  Sphincs.Send.entryPointGetNonceSelector).getD ByteArray.empty
                              let nonceCalldata :=
                                LeanKohaku.Crypto.Hex.encode
                                  (nonceSelBytes
                                    ++ (LeanKohaku.Sphincs.UserOp.hexToWord32? sender).getD ByteArray.empty
                                    ++ LeanKohaku.Sphincs.UserOp.padLeft32 ByteArray.empty)
                              let nonceN : Nat ← do
                                match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep
                                    Sphincs.Send.entryPointV09Address nonceCalldata "latest" none with
                                | .ok r => pure ((parseHexQuantity ((asString r).getD "0x0")).getD 0)
                                | .error _ => pure 0
                              let gp ← LeanKohaku.RPC.Outbound.gasPrice cfg.policy ep none
                              let pp ← LeanKohaku.RPC.Outbound.maxPriorityFeePerGas cfg.policy ep none
                              let parseHexJ (j : Except String Json) : Nat :=
                                match j with
                                | .ok jj => (parseHexQuantity ((asString jj).getD "0x0")).getD 0
                                | .error _ => 0
                              let gasPriceN := parseHexJ gp
                              let priorityFee := Nat.max (parseHexJ pp) minPriorityFeeWei
                              -- Bundlers (Candide, Pimlico, …) reject userOps
                              -- whose `maxFeePerGas` < their estimate of the
                              -- next block's base fee. Our `gasPrice` read can
                              -- be a few seconds stale (especially when
                              -- Colibri-verified reads are in the path), so
                              -- the naive `gasPrice + priorityFee` lands
                              -- slightly below the bundler's floor on a
                              -- rising-fee block. Pad to `2*gasPrice +
                              -- priorityFee` — typical "fast-tx" multiplier
                              -- shared by viem / ethers — which clears any
                              -- realistic base-fee bump between read and
                              -- submit. Sphincs- userOps are gas-heavy
                              -- enough that paying ~2× base fee is rounding
                              -- error against the 1.2 M total gas budget.
                              let maxFee := 2 * gasPriceN + priorityFee
                              let initCodeBytes ← do
                                match ← LeanKohaku.RPC.Outbound.call cfg.policy ep
                                    .getCode (.arr #[.str sender, .str "latest"]) none with
                                | .ok r =>
                                    let codeHex := (asString r).getD "0x"
                                    if Sphincs.Send.hasCodeAt codeHex then pure ByteArray.empty
                                    else
                                      match sphincsFactoryFor cfg chainName rec.paramSet with
                                      | .error _ => pure ByteArray.empty
                                      | .ok factory =>
                                          match ← Sphincs.Send.buildInitCode factory
                                              rec.ownerAddress rec.pkSeed rec.pkRoot with
                                          | .error _ => pure ByteArray.empty
                                          | .ok bs => pure bs
                                | .error _ => pure ByteArray.empty
                              -- 4) Skeleton + estimate gas.
                              let senderAddrBs : ByteArray :=
                                (LeanKohaku.Crypto.Hex.decode sender).getD ByteArray.empty
                              -- Initial heuristic gas params for the
                              -- estimate-request skeleton. Must fit under
                              -- the bundler's total-gas cap (Candide:
                              -- 15M for the whole userOp), otherwise the
                              -- estimate request ITSELF is rejected and
                              -- the fallback would carry the same
                              -- too-large values into the send request.
                              --
                              -- Real on-chain cost for SPHINCS- C9
                              -- _validateSignature (verifier staticcall +
                              -- ECDSA recover + abi.decode of the dual
                              -- signature): ~250 K. We pad to 800 K to
                              -- cover the first-send-also-deploy case
                              -- where the EntryPoint also has to CREATE2
                              -- the SphincsAccount contract before
                              -- calling _validateSignature.
                              -- preVerificationGas covers the EntryPoint's
                              -- per-byte calldata cost. A SPHINCS-C9 signature
                              -- alone is ~3816 bytes, and the abi.encode of
                              -- (bytes ecdsaSig, bytes sphincsSig) pushes the
                              -- full userOp calldata to ~9 KB. Candide's
                              -- bundler computes a per-userOp minimum from
                              -- that and rejects estimate requests that
                              -- under-shoot (typical observed minimum on
                              -- C9 sends: ~0x15f00 ≈ 90 K). 200 K gives
                              -- comfortable margin without re-tripping the
                              -- 15 M total-gas cap.
                              let opSkeleton : LeanKohaku.Sphincs.UserOp.PackedUserOperation := {
                                sender             := senderAddrBs,
                                nonce              := LeanKohaku.Sphincs.UserOp.padLeft32
                                  ((LeanKohaku.Crypto.Hex.decode (Sphincs.Send.natToEvenHex nonceN)).getD ByteArray.empty),
                                initCode           := initCodeBytes,
                                callData           := callData,
                                accountGasLimits   := Sphincs.Send.packTwoHalves 800000 200000,
                                preVerificationGas := Sphincs.Send.natToWord32 200000,
                                gasFees            := Sphincs.Send.packTwoHalves priorityFee maxFee,
                                paymasterAndData   := ByteArray.empty
                              }
                              let dummyEcdsa := ByteArray.mk (Array.replicate 65 (0 : UInt8))
                              let dummySphincs := ByteArray.mk
                                (Array.replicate rec.paramSet.expectedSigBytes (0 : UInt8))
                              let dummySig := Sphincs.Send.abiEncodeBytesPair dummyEcdsa dummySphincs
                              let dummyOpJson := Sphincs.Send.packedUserOpToJson opSkeleton dummySig
                              let estParams : Json :=
                                .arr #[dummyOpJson, .str Sphincs.Send.entryPointV09Address]
                              let (vgl, cgl, pvg) ← do
                                match ← Sphincs.Send.bundlerCall bundlerUrl
                                    "eth_estimateUserOperationGas" estParams with
                                | .ok est =>
                                    let getNat (k : String) : Nat :=
                                      match getField k est >>= asString with
                                      | some s => (parseHexQuantity s).getD 0
                                      | none => 0
                                    let vgl0 := getNat "verificationGasLimit"
                                    let cgl0 := getNat "callGasLimit"
                                    let pvg0 := getNat "preVerificationGas"
                                    pure
                                      (if vgl0 = 0 then 800000 else vgl0,
                                       if cgl0 = 0 then 200000 else cgl0,
                                       if pvg0 = 0 then 200000 else pvg0)
                                | .error _ => pure (800000, 200000, 200000)
                              let userOp : LeanKohaku.Sphincs.UserOp.PackedUserOperation :=
                                { opSkeleton with
                                    accountGasLimits   := Sphincs.Send.packTwoHalves vgl cgl,
                                    preVerificationGas := Sphincs.Send.natToWord32 pvg }
                              -- 5) Domain separator + userOpHash. We compute the
                              -- EIP-712 domain separator locally instead of
                              -- eth_call'ing `getDomainSeparatorV4()` — that
                              -- method isn't public on EntryPoint v0.9 (OZ
                              -- EIP712 only exposes `_domainSeparatorV4()`
                              -- internally), so the call reverts. The local
                              -- compute matches EntryPoint v0.9's
                              -- `EIP712("ERC4337", "1")` constructor.
                              match ← Sphincs.Send.computeDomainSeparator rec.chainId with
                              | .error e => pure <| .error { code := -32020, message := "domain separator computation failed", data := some (.str e) }
                              | .ok ds =>
                                  if ds.size ≠ 32 then
                                    pure <| .error { code := -32034, message := s!"unexpected domain separator size {ds.size}", data := none }
                                  else
                                    match ← LeanKohaku.Sphincs.UserOp.userOpHash userOp ds with
                                    | .error e => pure <| .error { code := -32031, message := "userOpHash failed", data := some (.str e) }
                                    | .ok userOpH =>
                                        match ← LeanKohaku.Wallet.EOA.signDigestIO privKey userOpH with
                                        | .error e => pure <| .error { code := -32013, message := "ecdsa sign failed", data := some (.str e) }
                                        | .ok ecdsaSig =>
                                            let rBs := Sphincs.Send.natToWord32 ecdsaSig.r
                                            let sBs := Sphincs.Send.natToWord32 ecdsaSig.s
                                            -- libsecp256k1 returns v as the
                                            -- recovery id {0, 1}, but the
                                            -- Ethereum / OZ ECDSA.recover
                                            -- convention is {27, 28}. The
                                            -- upstream `SphincsAccount.sol`
                                            -- uses OZ's recover which throws
                                            -- `ECDSAInvalidSignature` for
                                            -- v < 27 (ecrecover returns 0).
                                            -- Normalize here.
                                            let vByte : UInt8 :=
                                              if ecdsaSig.v < 27 then ecdsaSig.v + 27
                                              else ecdsaSig.v
                                            let vBs := ByteArray.empty.push vByte
                                            let ecdsaBytes := rBs ++ sBs ++ vBs
                                            let userOpHashHex := LeanKohaku.Crypto.Hex.encode userOpH
                                            -- The SPHINCS+ shim call is the
                                            -- expensive ("the grind") step:
                                            -- C9 takes seconds even on a fast
                                            -- machine. Bracket it with start /
                                            -- done notifications so the TUI's
                                            -- RpcRunner can show live status,
                                            -- and capture the elapsed time so
                                            -- the post-broadcast journal entry
                                            -- can record it for later review.
                                            let paramSetStr := rec.paramSet.toString
                                            notify "sphincs:sign-start" (.obj #[
                                              ("paramSet", .str paramSetStr),
                                              ("sender", .str sender),
                                              ("digest", .str userOpHashHex)
                                            ])
                                            let signStartMs ← IO.monoMsNow
                                            let signResult ← LeanKohaku.Sphincs.signWithVerify rec.paramSet
                                                sphincsSkHex rec.pkSeed rec.pkRoot userOpHashHex
                                            let signEndMs ← IO.monoMsNow
                                            let signMs := signEndMs - signStartMs
                                            match signResult with
                                            | .error e =>
                                                notify "sphincs:sign-done" (.obj #[
                                                  ("paramSet", .str paramSetStr),
                                                  ("elapsedMs", .num (Int.ofNat signMs)),
                                                  ("ok", .bool false),
                                                  ("error", .str (reprStr e))
                                                ])
                                                pure <| .error { code := -32014, message := "sphincs sign failed", data := some (.str (reprStr e)) }
                                            | .ok sphincsSigHex =>
                                                notify "sphincs:sign-done" (.obj #[
                                                  ("paramSet", .str paramSetStr),
                                                  ("elapsedMs", .num (Int.ofNat signMs)),
                                                  ("ok", .bool true),
                                                  ("sigChars", .num (Int.ofNat sphincsSigHex.length))
                                                ])
                                                let sphincsBytes := (LeanKohaku.Crypto.Hex.decode sphincsSigHex).getD ByteArray.empty
                                                let signature := Sphincs.Send.abiEncodeBytesPair ecdsaBytes sphincsBytes
                                                let opJson := Sphincs.Send.packedUserOpToJson userOp signature
                                                let subParams : Json :=
                                                  .arr #[opJson, .str Sphincs.Send.entryPointV09Address]
                                                notify "sphincs:bundler-submit" (.obj #[
                                                  ("bundler", .str bundlerUrl),
                                                  ("sender", .str sender)
                                                ])
                                                match ← Sphincs.Send.bundlerCall bundlerUrl "eth_sendUserOperation" subParams with
                                                | .error e => pure <| .error { code := -32021, message := "bundler error", data := some (.str e) }
                                                | .ok r =>
                                                    let userOpHash := (asString r).getD ""
                                                    -- Append to the slot's local NDJSON journal.
                                                    -- innerTo/innerValue/innerData carry what the user
                                                    -- actually intended (not the ABI-encoded UserOp
                                                    -- envelope) so the HistoryPanel shows "to 0xRouter"
                                                    -- rather than "to 0xSmartAccount". The userOp's
                                                    -- identity is the bundler's userOpHash; we mirror
                                                    -- it into `txHash` (the canonical journal column)
                                                    -- AND `userOpHash` so existing readers don't have
                                                    -- to change shape, and a future inclusion-tx
                                                    -- lookup can rewrite `txHash` in a status update.
                                                    let innerDataHex := "0x" ++ LeanKohaku.Crypto.Hex.encode innerData
                                                    journalRecord rec.name sender innerTo userOpHash innerDataHex
                                                      "sphincs.userOp" innerValue 0 rec.chainId none
                                                      none none none
                                                      (signMs? := some signMs)
                                                      (paramSet? := some paramSetStr)
                                                      (userOpHash? := some userOpHash)
                                                    pure <| .ok <| .obj #[
                                                      ("userOpHash", .str userOpHash),
                                                      ("sender", .str sender),
                                                      ("bundler", .str bundlerUrl),
                                                      ("signMs", .num (Int.ofNat signMs)),
                                                      ("paramSet", .str paramSetStr)
                                                    ]

def methodHandler (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "daemon.ping" =>
      let shuttingDown ← LeanKohaku.Daemon.State.isShuttingDown state
      -- Why: surface the user's `network set-rpc-chain` config so TUI/CLI
      -- callers can pick a chain that actually has an RPC configured. The
      -- entries are read-only metadata (no URL leaked, just the names the
      -- user already typed), so no policy gate is required. Today we know
      -- numeric ids for "mainnet"/"sepolia" and surface 0 for others — the
      -- TUI uses the *name* as the daemon-RPC chainId selector, never the
      -- numeric id, since the daemon's `swap.*` handlers parse a string.
      let chainNumId : String → Int
        | "mainnet" => 1
        | "sepolia" => 11155111
        | _         => 0
      let isCurrent : String → Bool
        | "mainnet" => cfg.chainId == 1
        | "sepolia" => cfg.chainId == 11155111
        | _         => false
      let chainsArr : Array Json :=
        cfg.chainEndpoints.map fun (name, _) =>
          .obj #[
            ("name",      .str name),
            ("chainId",   .num (chainNumId name)),
            ("hasRpc",    .bool true),
            ("isCurrent", .bool (isCurrent name))
          ]
      pure <| .ok <| .obj #[
        ("ok", .bool true),
        ("version", .str LeanKohaku.version),
        ("uptime", .num 0),
        ("locked", .arr ((← LeanKohaku.Daemon.State.unlockedNames state).toArray.map Json.str)),
        ("chainId", .num (Int.ofNat cfg.chainId)),
        ("chains", .arr chainsArr),
        ("shuttingDown", .bool shuttingDown)
      ]
  | "daemon.version" =>
      pure <| .ok <| .obj #[
        ("version", .str LeanKohaku.version),
        ("rpcSchemaMajor", .num 1)
      ]
  | "daemon.shutdown" =>
      LeanKohaku.Daemon.State.requestShutdown state
      discard <| IO.asTask (exitSoon cfg.socketPath)
      pure <| .ok <| .obj #[("ok", .bool true)]
  | "status.snapshot" =>
      -- One-shot debugging snapshot for the TUI's Status page. Aggregates
      -- daemon identity, sidecar ping results, sandbox posture, version
      -- markers, and wallet posture. Read-only and policy-free — it's
      -- pure introspection on local process state and the recorded
      -- checkout. Network policy/chainId/socketPath are mirrored from
      -- the active config so the page renders atomically without a
      -- second `network.show` round-trip. See `Daemon/Status.lean` for
      -- the field contract.
      let (_, _, _, _, policyName) ← LeanKohaku.Cli.NetworkConfig.resolved
      let snap ← LeanKohaku.Daemon.Status.buildSnapshot
        state cfg.chainId policyName cfg.socketPath
        cfg.rpcEndpoint cfg.ensRpcEndpoint cfg.chainEndpoints
      pure <| .ok snap
  | "network.show" =>
      -- Structured snapshot of the daemon's *currently-active* network
      -- config: what handlers will dial *right now*. Mirrors what
      -- `kohaku network show` prints, but as JSON for the TUI. Read-only;
      -- mutations still flow through the CLI's NetworkConfig writers (and
      -- only take effect at daemon restart). Surfacing the resolved policy
      -- name from env/file lets the UI label "strict | tor | dev | …"
      -- without re-implementing the resolver.
      let endpointJson (ep : LeanKohaku.RPC.Outbound.Endpoint) : Json :=
        .obj #[
          ("url", .str ep.url),
          ("transport", .str ep.transport.asString),
          ("backend", .str ep.backend.asString)
        ]
      let chainNumId : String → Int
        | "mainnet" => 1
        | "sepolia" => 11155111
        | _ => 0
      let isCurrent : String → Bool
        | "mainnet" => cfg.chainId = 1
        | "sepolia" => cfg.chainId = 11155111
        | _ => false
      let chainsArr : Array Json :=
        cfg.chainEndpoints.map fun (name, ep) =>
          .obj #[
            ("name", .str name),
            ("chainId", .num (chainNumId name)),
            ("url", .str ep.url),
            ("transport", .str ep.transport.asString),
            ("backend", .str ep.backend.asString),
            ("isCurrent", .bool (isCurrent name))
          ]
      let ensJson : Json :=
        match cfg.ensRpcEndpoint with
        | some ep => endpointJson ep
        | none => .null
      let logPath ← LeanKohaku.RPC.Outbound.networkLogPath
      let configPath ← LeanKohaku.Cli.NetworkConfig.configPath
      -- The daemon's `Config` does not retain the policy *name*; the file/env
      -- resolver in `NetworkConfig` does. Reading it here matches what the
      -- daemon would adopt on next start, which is the most useful label
      -- for the user (the active in-process closure has no name).
      let (_, _, _, _, policyName) ← LeanKohaku.Cli.NetworkConfig.resolved
      let lightclientFlag : Bool :=
        match cfg.rpcEndpoint.transport with
        | .loopback => true
        | _ => false
      let indexersArr : Array Json :=
        cfg.indexers.map fun e =>
          .obj #[("name", .str e.name), ("url", .str e.url)]
      pure <| .ok <| .obj #[
        ("configFile", .str configPath),
        ("chainId", .num (Int.ofNat cfg.chainId)),
        ("rpc", endpointJson cfg.rpcEndpoint),
        ("ens", ensJson),
        ("perChain", .arr chainsArr),
        ("policy", .str policyName),
        ("socketPath", .str cfg.socketPath),
        ("logPath", match logPath with | some p => .str p | none => .null),
        ("lightclient", .bool lightclientFlag),
        ("indexers", .arr indexersArr)
      ]
  | "account.getDefault" =>
      -- Why: the default account is process-user state, not chain state, but
      -- the daemon is the right owner because the CLI is supposed to be a
      -- thin RPC forwarder (CLAUDE.md). File lives at
      -- `$XDG_CONFIG_HOME/leankohaku/default-account.txt` falling back to
      -- `~/.config/leankohaku/default-account.txt`. Returns `{ name: null }`
      -- when unset; never throws, so first-run callers don't have to special
      -- case missing files.
      let path ← defaultAccountPathIO
      if ← path.pathExists then
        let raw ← try IO.FS.readFile path catch _ => pure ""
        let trimmed := raw.trimAscii.toString
        if trimmed.isEmpty then
          pure <| .ok <| .obj #[("name", .null)]
        else
          pure <| .ok <| .obj #[("name", .str trimmed)]
      else
        pure <| .ok <| .obj #[("name", .null)]
  | "account.setDefault" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          let path ← defaultAccountPathIO
          match path.parent with
          | some parent => try IO.FS.createDirAll parent catch _ => pure ()
          | none => pure ()
          IO.FS.writeFile path (name ++ "\n")
          pure <| .ok <| .obj #[("ok", .bool true), ("name", .str name)]
  | "account.clearDefault" =>
      let path ← defaultAccountPathIO
      if ← path.pathExists then
        try IO.FS.removeFile path catch _ => pure ()
      pure <| .ok <| .obj #[("ok", .bool true)]
  | "daemon.preflight" =>
      -- Why: pushes the CLI's "preflight" dry-run check into the daemon so
      -- the CLI is a thin printer per CLAUDE.md. Accepts an action JSON
      -- shape `{ method: "balance"|"send", address?, to?, amountWei? }`,
      -- runs the same `strictCliPreflight` the CLI used, returns a
      -- pre-formatted summary + plan. The CLI just echoes the strings.
      let methodStr := paramStringD req.params "method" ""
      let action? : Option LeanKohaku.Cli.Commands.Action :=
        match methodStr with
        | "balance" =>
            (getField "address" req.params >>= asString)
              >>= LeanKohaku.Cli.Commands.parseBalance
        | "send" =>
            match (getField "to" req.params >>= asString),
                  (getField "amountWei" req.params >>= asNat) with
            | some to, some n => some (.send to n)
            | _, _ => none
        | _ => none
      match action? with
      | none =>
          pure <| .ok <| .obj #[
            ("ok",      .bool false),
            ("summary", .str s!"preflight denied: invalid {methodStr} action"),
            ("plan",    .str "")
          ]
      | some action =>
          let req' : LeanKohaku.Cli.Commands.DaemonRequest := { action }
          let plan := LeanKohaku.Cli.Commands.strictPlan req'
          let okBool := LeanKohaku.Cli.Commands.strictCliPreflight action
          pure <| .ok <| .obj #[
            ("ok", .bool okBool),
            ("summary",
              .str (if okBool then s!"preflight OK: {LeanKohaku.Cli.Commands.actionSummary action}"
                    else s!"preflight denied: {LeanKohaku.Cli.Commands.actionSummary action}")),
            ("plan", .str (LeanKohaku.Cli.Commands.planSummary plan))
          ]
  | "tpm.create" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "pin" with
          | .error err => pure (.error err)
          | .ok pin =>
              let report ← createR1Key pin { keyName := keyName } notify
              pure <| .ok <| textResultJson (tpm2CreateReportText report) report.status.exitCode
  -- Back-compat alias kept for one release; delegates to tpm.create.
  | "tpm.createSepolia" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "pin" with
          | .error err => pure (.error err)
          | .ok pin =>
              let report ← createR1Key pin { keyName := keyName } notify
              pure <| .ok <| textResultJson (tpm2CreateReportText report) report.status.exitCode
  | "tpm.deploy" =>
      -- Params:
      --   name             : string  (R1 key slot to deploy)
      --   chain            : string  ("sepolia" today; "mainnet" not yet enabled)
      --   deployer         : optional string ("env" | "eoa"; default "env")
      --   deployerEoa      : required when deployer="eoa" — slot name
      --   deployerPassphrase : required when deployer="eoa" — slot passphrase
      -- Why: the deploy script's deployer_private_key() reads
      -- SEPOLIA_DEPLOYER_PRIVATE_KEY (or PRIVATE_KEY) from env. When
      -- deployer="eoa" we transiently inject that env var from an
      -- unlocked-on-the-fly EOA seed → BIP-32-derived secp256k1 key,
      -- so users don't have to keep a raw pk in .env.
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "chain" with
          | .error err => pure (.error err)
          | .ok chain =>
              let deployer := (getField "deployer" req.params >>= asString).getD "env"
              let deployerEnvRes : IO (Except RpcError (Array (String × Option String))) := do
                match deployer with
                | "env" =>
                    pure (.ok #[("LEAN_KOHAKU_TPM_KEY", some keyName)])
                | "eoa" =>
                    match paramString req.params "deployerEoa",
                          paramString req.params "deployerPassphrase" with
                    | .ok eoaName, .ok pp =>
                        match ← LeanKohaku.Wallet.EoaStore.load eoaName with
                        | .error err =>
                            pure (.error
                              { code := -32050,
                                message := "deployer EOA load failed",
                                data := some (.str err) })
                        | .ok record =>
                            -- Master-KEK / already-unlocked fast path:
                            -- when `pp` is empty, prefer the in-memory
                            -- unlocked seed (set by an earlier
                            -- eoa.unlock — possibly via the master fast
                            -- path). This lets the TUI run UnlockEoaStep
                            -- before tpm.deploy and pass an empty
                            -- passphrase, instead of asking the user for
                            -- an ephemeral passphrase they don't have.
                            -- Additive: a real passphrase still runs the
                            -- per-slot KDF path below unchanged.
                            let seedRes ←
                              if pp.length == 0 then
                                match ← LeanKohaku.Daemon.State.getUnlocked? state eoaName with
                                | some slot => pure (.ok slot.seed)
                                | none =>
                                    pure (.error "deployer EOA is locked — unlock it first (no passphrase supplied)")
                              else
                                LeanKohaku.Wallet.EoaStore.unlockSeedIO record pp
                            match seedRes with
                            | .error err =>
                                pure (.error
                                  { code := -32051,
                                    message := "deployer EOA unlock failed",
                                    data := some (.str err) })
                            | .ok seed =>
                                match ← derivePrivateKeyFromSeed seed record.derivationPath with
                                | .error err =>
                                    pure (.error
                                      { code := -32052,
                                        message := "deployer EOA pk derivation failed",
                                        data := some (.str err) })
                                | .ok pk =>
                                    -- Hex.encode already prepends "0x"; do NOT
                                    -- add another one (forge rejects "0x0x…"
                                    -- with "Failed to decode private key").
                                    let pkHex := LeanKohaku.Crypto.Hex.encode pk
                                    pure (.ok #[
                                      ("LEAN_KOHAKU_TPM_KEY", some keyName),
                                      ("SEPOLIA_DEPLOYER_PRIVATE_KEY", some pkHex),
                                      ("PRIVATE_KEY", some pkHex)
                                    ])
                    | _, _ =>
                        pure (.error
                          { code := -32602,
                            message := "deployer=\"eoa\" requires deployerEoa and deployerPassphrase" })
                | other =>
                    pure (.error
                      { code := -32602,
                        message := s!"unknown deployer: {other} (expected \"env\" or \"eoa\")" })
              match ← deployerEnvRes with
              | .error err => pure (.error err)
              | .ok scriptEnv =>
                  match chain with
                  | "sepolia" =>
                      if accepted sepoliaR1Smart then
                        let (exitCode, text) ← runScript cfg #["deploy"] scriptEnv
                        pure <| .ok <| textResultJson text exitCode
                      else
                        pure <| .ok <| textResultJson
                          "Sepolia R1 account policy rejected\n" 1
                  | "mainnet" =>
                      pure <| .ok <| textResultJson
                        "mainnet R1 deploy is not enabled yet; deploy and verify the account path on Sepolia first\n" 2
                  | other =>
                      pure <| .ok <| textResultJson
                        s!"unsupported chain: {other} (expected sepolia or mainnet)\n" 2
  | "tpm.listSepolia" =>
      let names ← listSepoliaKeys
      pure <| .ok <| textResultJson (formatKeyList names) 0
  | "tpm.listSepoliaAddresses" =>
      let names ← listSepoliaKeys
      let stateDir : System.FilePath := ".leankohaku/keystore/tpm2"
      let mut entries : Array Json := #[]
      for name in names do
        let addrFile := stateDir / name / "r1-account-address.txt"
        let address ←
          if ← addrFile.pathExists then
            let raw ← IO.FS.readFile addrFile
            pure raw.trimAscii.toString
          else pure ""
        entries := entries.push <| .obj #[
          ("name", .str name),
          ("address", .str address)
        ]
      pure (.ok (.arr entries))
  | "tpm.signSepolia" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "digest", paramString req.params "pin" with
          | .ok digest, .ok pin =>
              let report ← signSepoliaDigest digest pin { keyName := keyName } notify
              pure <| .ok <| textResultJson (tpm2SignReportText report) report.status.exitCode
          | _, _ => pure (.error invalidParams)
  | "r1.sendSepolia" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "to",
                paramString req.params "amountWei",
                paramString req.params "pin" with
          | .ok to, .ok amountWei, .ok pin =>
              r1SendFlow cfg state notify keyName to amountWei "wei" pin
          | _, _, _ => pure (.error invalidParams)
  | "r1.sendEthSepolia" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "to",
                paramString req.params "amountEth",
                paramString req.params "pin" with
          | .ok to, .ok amountEth, .ok pin =>
              r1SendFlow cfg state notify keyName to amountEth "eth" pin
          | _, _, _ => pure (.error invalidParams)
  | "r1.sendRawSepolia" =>
      -- Why: lets the TUI swap flow (and any future R1-side raw-tx surface)
      -- ship `{to,value,data}` through the same TPM2-backed pre-sign pipeline
      -- as `r1.sendEthSepolia`, gated by the TPM-bound PIN. The TUI already
      -- round-trips the pre-sign Confirm step before calling here.
      -- `value` accepts a JSON integer (bigint from `daemon.ts`) or a
      -- `0x`-prefixed / decimal `String`. `data` must start with `0x` and
      -- contain at least one byte; for value-only sends use `r1.sendSepolia`.
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok keyName =>
          match paramString req.params "to",
                paramNatOrHexStr req.params "value",
                paramString req.params "data",
                paramString req.params "pin" with
          | .ok to, .ok value, .ok data, .ok pin =>
              let trimmed := data.trimAscii.toString
              if !(trimmed.startsWith "0x" || trimmed.startsWith "0X") then
                pure (.error invalidParams)
              else if trimmed.length ≤ 2 then
                -- "0x" alone is a value-only send; route via r1.sendSepolia.
                pure (.error invalidParams)
              else
                r1SendFlow cfg state notify keyName to (toString value) "wei" pin (some trimmed)
          | _, _, _, _ => pure (.error invalidParams)
  | "chain.balance" =>
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanKohaku.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let block := paramStringD req.params "block" "latest"
              -- Honor an optional `chain` selector (e.g. "mainnet"/"sepolia")
              -- so the TUI wallet list can query each row on its actual
              -- network — TPM/R1 slots are sepolia-only, while EOAs default
              -- to whatever the daemon's primary chain is. Falls back to
              -- `cfg.rpcEndpoint` when omitted, matching prior behavior.
              let chain? := getField "chain" req.params >>= asString
              match endpointForChain cfg chain? with
              | .error err =>
                  pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
              | .ok ep =>
                  -- Balance reads are display-only — mirror `swap.balances`
                  -- and skip the Colibri verifier so a stale or slow light
                  -- client can't poison the wallets hub with dust amounts /
                  -- intermittent failures. Soundness still comes from
                  -- `cfg.policy` gating; the result is never used for signing.
                  let via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none
                  match ← LeanKohaku.RPC.Outbound.getBalance cfg.policy ep address block via? with
                  | .ok balance =>
                      pure <| .ok <| .obj #[
                        ("address", .str address),
                        ("block", .str block),
                        ("balance", balance),
                        ("chain", .str (chain?.getD (
                          if cfg.chainId = 1 then "mainnet"
                          else if cfg.chainId = 11155111 then "sepolia"
                          else "default")))
                      ]
                  | .error err =>
                      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.nonce" =>
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanKohaku.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let block := paramStringD req.params "block" "pending"
              -- Per-call chain override mirrors `eoa.send`. The TUI's
              -- unstick flow queries `latest` + `pending` nonces on a
              -- specific chain, which may differ from daemon default.
              let chainName? := getField "chain" req.params >>= asString
              let cfgEff : Config :=
                match chainName? with
                | none => cfg
                | some name =>
                    match endpointForChain cfg (some name) with
                    | .error _ => cfg
                    | .ok ep =>
                        let cid := (LeanKohaku.RPC.Outbound.chainNameToId name).getD cfg.chainId
                        { cfg with rpcEndpoint := ep, chainId := cid }
              let via? ← colibriVia state cfgEff.chainId
              match ← LeanKohaku.RPC.Outbound.getTransactionCount cfgEff.policy cfgEff.rpcEndpoint address block via? with
              | .ok nonce =>
                  pure <| .ok <| .obj #[
                    ("address", .str address),
                    ("block", .str block),
                    ("nonce", nonce)
                  ]
              | .error err =>
                  pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.addressFreshness" =>
      -- Why: the wallets-hub TUI green-marks "0-link" rows so users
      -- can pick an unshield destination without leaking on-chain
      -- linkage. "0 link" here = nonce 0 (pending tag) AND no ERC-20
      -- Transfer event in/out within the lookback window. The window
      -- is bounded (default 5000 blocks ≈ 17 h on mainnet) because
      -- public RPCs cap eth_getLogs ranges; this is a best-effort
      -- signal, never used for signing decisions — the TUI degrades
      -- to "unknown" (no green) when either getLogs call fails.
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanKohaku.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let chain? := getField "chain" req.params >>= asString
              match endpointForChain cfg chain? with
              | .error err =>
                  pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
              | .ok ep =>
                  -- Freshness is a best-effort display signal — never used
                  -- for signing decisions (see handler-level comment).
                  -- Match `chain.balance` / `swap.balances` and skip Colibri
                  -- so stale light-client state can't flip 0-link tags.
                  let via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none
                  let lookback := paramNatD req.params "lookback" 5000
                  -- Nonce (pending) — primary "did this account ever send a tx" signal.
                  let nonceRes ← LeanKohaku.RPC.Outbound.getTransactionCount cfg.policy ep address "pending" via?
                  match nonceRes with
                  | .error err =>
                      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
                  | .ok nonceJ =>
                      let nonceN := (asString nonceJ >>= parseHexQuantity).getD 0
                      -- Local-knowledge signal: did we ever unshield to
                      -- this address from this daemon? The TUI uses it
                      -- to keep the green tag on PP-funded receivers
                      -- whose only inbound value came from us via the
                      -- relayer. False otherwise — we never try to read
                      -- the chain to claim a third-party-PP-funded
                      -- address is fresh (the Withdrawn event's
                      -- indexed topic is the relayer, not the recipient,
                      -- so we can't tell cheaply).
                      let ppFunded ← LeanKohaku.Daemon.PpDestinations.contains address
                      -- Head block — bound the getLogs window.
                      let headRes ← LeanKohaku.RPC.Outbound.blockNumber cfg.policy ep via?
                      match headRes with
                      | .error _ =>
                          pure <| .ok <| .obj #[
                            ("address", .str address),
                            ("nonce", .num (Int.ofNat nonceN)),
                            ("ppFunded", .bool ppFunded),
                            ("available", .bool false),
                            ("reason", .str "eth_blockNumber failed")
                          ]
                      | .ok headJ =>
                          let head := (asString headJ >>= parseHexQuantity).getD 0
                          let fromBlock := if head ≤ lookback then 0 else head - lookback
                          let fromHex := natQuantityHex fromBlock
                          let toHex := natQuantityHex head
                          let paddedSelf := "0x" ++ LeanKohaku.Swap.UniV3.encodeAddress address
                          -- Two scans: address as Transfer.from (topic1), address as Transfer.to (topic2).
                          -- No `address` filter on the eth_getLogs query so any ERC-20
                          -- contract matches; that's the heavier query, hence "best-effort".
                          let outTopics : Array Json := #[.str transferEventTopic, .str paddedSelf, .null]
                          let inTopics  : Array Json := #[.str transferEventTopic, .null, .str paddedSelf]
                          let outRes ← LeanKohaku.RPC.Outbound.getLogsAnyAddress cfg.policy ep fromHex toHex outTopics via?
                          let inRes  ← LeanKohaku.RPC.Outbound.getLogsAnyAddress cfg.policy ep fromHex toHex inTopics  via?
                          let countOpt? : Json → Option Nat := fun j =>
                            (asArray j).map (fun a => a.size)
                          match outRes, inRes with
                          | .ok oj, .ok ij =>
                              let oc := (countOpt? oj).getD 0
                              let ic := (countOpt? ij).getD 0
                              pure <| .ok <| .obj #[
                                ("address", .str address),
                                ("nonce", .num (Int.ofNat nonceN)),
                                ("erc20OutCount", .num (Int.ofNat oc)),
                                ("erc20InCount", .num (Int.ofNat ic)),
                                ("ppFunded", .bool ppFunded),
                                ("fromBlock", .num (Int.ofNat fromBlock)),
                                ("toBlock", .num (Int.ofNat head)),
                                ("available", .bool true)
                              ]
                          | _, _ =>
                              pure <| .ok <| .obj #[
                                ("address", .str address),
                                ("nonce", .num (Int.ofNat nonceN)),
                                ("ppFunded", .bool ppFunded),
                                ("fromBlock", .num (Int.ofNat fromBlock)),
                                ("toBlock", .num (Int.ofNat head)),
                                ("available", .bool false),
                                ("reason", .str "eth_getLogs unavailable on this RPC")
                              ]
  | "chain.gasPrice" =>
      let via? ← colibriVia state cfg.chainId
      match ← LeanKohaku.RPC.Outbound.gasPrice cfg.policy cfg.rpcEndpoint via? with
      | .ok gasPrice =>
          pure <| .ok <| .obj #[("gasPrice", gasPrice)]
      | .error err =>
          pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.maxPriorityFeePerGas" =>
      let via? ← colibriVia state cfg.chainId
      match ← LeanKohaku.RPC.Outbound.maxPriorityFeePerGas cfg.policy cfg.rpcEndpoint via? with
      | .ok maxPriorityFeePerGas =>
          pure <| .ok <| .obj #[("maxPriorityFeePerGas", maxPriorityFeePerGas)]
      | .error err =>
          pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.estimateGas" =>
      match paramTxRequest req.params with
      | .error err => pure (.error err)
      | .ok tx =>
          let block := paramStringD req.params "block" "latest"
          let via? ← colibriVia state cfg.chainId
          match ← LeanKohaku.RPC.Outbound.estimateGas cfg.policy cfg.rpcEndpoint tx block via? with
          | .ok gas =>
              pure <| .ok <| .obj #[
                ("tx", tx),
                ("block", .str block),
                ("gas", gas)
              ]
          | .error err =>
              pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.ethCall" =>
      -- Why: a general policy-gated `eth_call` for any contract method.
      -- Used by the LLM agent's tool layer (Aave health factor, future
      -- Uniswap V3 Quoter, etc.) to read contract state without each
      -- protocol getting its own daemon RPC. The daemon does no decoding
      -- of the return value — that's the caller's responsibility, since
      -- this is a general-purpose primitive.
      match paramString req.params "to", paramString req.params "data" with
      | .ok to, .ok data =>
          match LeanKohaku.Ethereum.Address.fromHex to with
          | none => pure (.error invalidParams)
          | some _ =>
              let block := paramStringD req.params "block" "latest"
              let chain? := getField "chain" req.params >>= asString
              match endpointForChain cfg chain? with
              | .error err =>
                  pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
              | .ok ep =>
                  let chainIdParam :=
                    ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
                  let via? ← colibriVia state chainIdParam
                  match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep to data block via? with
                  | .ok ret =>
                      pure <| .ok <| .obj #[
                        ("to", .str to),
                        ("data", .str data),
                        ("block", .str block),
                        ("returnData", ret)
                      ]
                  | .error err =>
                      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
      | _, _ => pure (.error invalidParams)
  | "chain.tokenBalance" =>
      match paramString req.params "token", paramString req.params "owner" with
      | .ok token, .ok owner =>
          match LeanKohaku.Ethereum.Address.fromHex token, LeanKohaku.Ethereum.Address.fromHex owner with
          | some _, some ownerAddr =>
              let block := paramStringD req.params "block" "latest"
              let data := erc20BalanceOfData ownerAddr
              let via? ← colibriVia state cfg.chainId
              match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy cfg.rpcEndpoint token data block via? with
              | .ok balance =>
                  pure <| .ok <| .obj #[
                    ("token", .str token),
                    ("owner", .str owner),
                    ("block", .str block),
                    ("balance", balance)
                  ]
              | .error err =>
                  pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
          | _, _ => pure (.error invalidParams)
      | _, _ => pure (.error invalidParams)
  | "swap.tokens.list" =>
      -- Read-only exposure of `LeanKohaku.Swap.Tokens.registry` filtered by
      -- the requested chain. The TUI consumes this so it does not duplicate
      -- the registry in TypeScript. No policy gate: the data is static and
      -- contains nothing chain-derived.
      let chainStr := paramStringD req.params "chainId" "mainnet"
      match LeanKohaku.Swap.Tokens.ChainId.fromString? chainStr with
      | none =>
          pure <| .error { code := -32602,
                           message := "unknown chainId for swap.tokens.list",
                           data := some (.str chainStr) }
      | some chainId =>
          let mut entries : Array Json := #[]
          for t in LeanKohaku.Swap.Tokens.registry do
            match LeanKohaku.Swap.Tokens.addressOn t chainId with
            | some addr =>
                entries := entries.push <| .obj #[
                  ("symbol",   .str t.symbol),
                  ("name",     .str t.name),
                  ("address",  .str addr),
                  ("decimals", .num (Int.ofNat t.decimals))
                ]
            | none => pure ()
          pure <| .ok <| .obj #[
            ("chainId", .num (Int.ofNat chainId.toNat)),
            ("tokens",  .arr entries)
          ]
  | "swap.balances" =>
      -- Why: fan out ERC-20 `balanceOf` + native `eth_getBalance` across the
      -- swap registry filtered by chain. This is the data source for the
      -- TUI swap from-picker (per-token balance column) and the
      -- `kohaku balances` CLI command. Concurrency is load-bearing: a
      -- sequential loop over ~10 tokens against a public RPC adds ~1s of
      -- wall time. We spawn one `IO.asTask` per call and join them so the
      -- whole response is bounded by the slowest single eth_call.
      --
      -- Trust model: balance reads are policy-gated by `Outbound.*`; the
      -- response is render-only data. `via? := none` is intentional —
      -- balance fan-out goes direct RPC to keep latency predictable and
      -- avoid serializing through Colibri's UDS for every token.
      --
      -- Fail-soft: a single token whose `balanceOf` reverts (rare, e.g.
      -- self-destructed contract) is silently dropped from the response,
      -- mirroring the trace tokenMeta prefetch policy. Other tokens still
      -- appear. ETH balance failure causes the whole call to error, since
      -- a valid address should always have a queryable native balance.
      let chainStr := paramStringD req.params "chainId" "mainnet"
      match LeanKohaku.Swap.Tokens.ChainId.fromString? chainStr with
      | none =>
          pure <| .error { code := -32602,
                           message := "unknown chainId for swap.balances",
                           data := some (.str chainStr) }
      | some chainId =>
          match paramString req.params "address" with
          | .error err => pure (.error err)
          | .ok address =>
              match LeanKohaku.Ethereum.Address.fromHex address with
              | none => pure (.error invalidParams)
              | some ownerAddr =>
                  let chainName : String :=
                    match chainId with | .mainnet => "mainnet" | .sepolia => "sepolia"
                  match endpointForChain cfg (some chainName) with
                  | .error err =>
                      pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
                  | .ok ep =>
                      -- 1) Spawn ETH (native) balance task.
                      let ethTask ← IO.asTask <|
                        LeanKohaku.RPC.Outbound.getBalance cfg.policy ep address "latest" none
                      -- 2) Build the per-token task list. Each entry carries
                      --    the (symbol, address, decimals, name) it belongs to
                      --    so we can join task results in order without
                      --    re-walking the registry.
                      let calldata := erc20BalanceOfData ownerAddr
                      -- Why: `balancesCandidates` is the proved-source-of-truth
                      -- for which tokens we fan out to (theorem
                      -- `balancesCandidates_addressOn_some` rules out using a
                      -- mainnet address on sepolia or vice-versa).
                      let candidates :
                          List (LeanKohaku.Swap.Tokens.Token × String) :=
                        LeanKohaku.Invariants.Swap.balancesCandidates chainId
                      let mut tokenTasks :
                          Array (LeanKohaku.Swap.Tokens.Token × String ×
                                 Task (Except IO.Error (Except String Json))) := #[]
                      for (t, addr) in candidates do
                        let task ← IO.asTask <|
                          LeanKohaku.RPC.Outbound.ethCall cfg.policy ep addr calldata "latest" none
                        tokenTasks := tokenTasks.push (t, addr, task)
                      -- 3) Join native first; bail on failure (the address
                      --    itself is unreachable, so per-token results are
                      --    moot).
                      match ← IO.wait ethTask with
                      | .error e =>
                          pure <| .error { code := -32020,
                                           message := "chain RPC failed (eth balance)",
                                           data := some (.str e.toString) }
                      | .ok (.error err) =>
                          pure <| .error { code := -32020,
                                           message := "chain RPC failed (eth balance)",
                                           data := some (.str err) }
                      | .ok (.ok ethBal) =>
                          let mut entries : Array Json := #[
                            .obj #[
                              ("symbol",   .str "ETH"),
                              ("name",     .str "Ether"),
                              ("address",  .null),
                              ("decimals", .num 18),
                              ("balance",  ethBal)
                            ]
                          ]
                          for (t, addr, task) in tokenTasks do
                            match ← IO.wait task with
                            | .ok (.ok bal) =>
                                entries := entries.push <| .obj #[
                                  ("symbol",   .str t.symbol),
                                  ("name",     .str t.name),
                                  ("address",  .str addr),
                                  ("decimals", .num (Int.ofNat t.decimals)),
                                  ("balance",  bal)
                                ]
                            -- Fail-soft per token: drop on RPC error or
                            -- task exception.
                            | _ => pure ()
                          pure <| .ok <| .obj #[
                            ("chain",    .str chainName),
                            ("chainId",  .num (Int.ofNat chainId.toNat)),
                            ("address",  .str address),
                            ("balances", .arr entries)
                          ]
  | "swap.uniV3.quote" =>
      -- Why: try fee tiers [500, 3000, 10000] via QuoterV2.quoteExactInputSingle
      -- and return the first (and largest amountOut) that doesn't revert.
      let chainStr := paramStringD req.params "chainId" "mainnet"
      match LeanKohaku.Swap.Tokens.ChainId.fromString? chainStr with
      | none => pure <| .error { code := -32602, message := "unknown chainId for swap.uniV3.quote", data := some (.str chainStr) }
      | some chainId =>
          let chainName : String :=
            match chainId with | .mainnet => "mainnet" | .sepolia => "sepolia"
          match endpointForChain cfg (some chainName) with
          | .error err => pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              match paramString req.params "tokenIn", paramString req.params "tokenOut", getField "amountIn" req.params >>= asNat with
              | .ok tinRaw, .ok toutRaw, some amountIn =>
                  match LeanKohaku.Swap.Tokens.resolve tinRaw chainId, LeanKohaku.Swap.Tokens.resolve toutRaw chainId with
                  | some (_, tinAddr), some (_, toutAddr) =>
                      let quoter := LeanKohaku.Swap.UniV3.quoterFor chainId
                      let router := LeanKohaku.Swap.UniV3.routerFor chainId
                      let fees : List Nat := [500, 3000, 10000]
                      let via? ← colibriVia state chainId.toNat
                      let mut best : Option (Nat × Nat) := none
                      for fee in fees do
                        let data := LeanKohaku.Swap.UniV3.encodeQuoteExactInputSingle
                          { tokenIn := tinAddr, tokenOut := toutAddr,
                            amountIn := amountIn, fee := fee }
                        match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep quoter data "latest" via? with
                        | .ok ret =>
                            match asString ret with
                            | some hex =>
                                match LeanKohaku.Swap.UniV3.decodeQuoteAmountOut hex with
                                | some amt =>
                                    match best with
                                    | none => best := some (amt, fee)
                                    | some (b, _) =>
                                        if amt > b then best := some (amt, fee)
                                | none => pure ()
                            | none => pure ()
                        | .error _ => pure ()
                      match best with
                      | none =>
                          pure <| .error { code := -32020, message := "no Uniswap V3 pool returned a quote (all fee tiers reverted)", data := none }
                      | some (amt, fee) =>
                          pure <| .ok <| .obj #[
                            ("amountOut", .num (Int.ofNat amt)),
                            ("fee", .num (Int.ofNat fee)),
                            ("quoter", .str quoter),
                            ("router", .str router),
                            ("tokenIn", .str tinAddr),
                            ("tokenOut", .str toutAddr),
                            ("chainId", .num (Int.ofNat chainId.toNat))
                          ]
                  | _, _ =>
                      pure <| .error { code := -32602, message := "could not resolve tokenIn/tokenOut for chain", data := none }
              | _, _, _ => pure (.error invalidParams)
  | "swap.uniV3.build" =>
      let chainStr := paramStringD req.params "chainId" "mainnet"
      match LeanKohaku.Swap.Tokens.ChainId.fromString? chainStr with
      | none => pure <| .error { code := -32602, message := "unknown chainId for swap.uniV3.build", data := some (.str chainStr) }
      | some chainId =>
          let chainName : String :=
            match chainId with | .mainnet => "mainnet" | .sepolia => "sepolia"
          match endpointForChain cfg (some chainName) with
          | .error err => pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              match paramString req.params "fromAddress",
                    paramString req.params "tokenIn",
                    paramString req.params "tokenOut",
                    getField "amountIn" req.params >>= asNat,
                    getField "amountOutMin" req.params >>= asNat,
                    getField "fee" req.params >>= asNat with
              | .ok fromAddr, .ok tinRaw, .ok toutRaw, some amountIn, some amountOutMin, some fee =>
                  let recipient := paramStringD req.params "recipient" fromAddr
                  let isEthIn :=
                    let s := tinRaw.trimAscii.toString.toLower
                    s = "eth"
                  let isEthOut :=
                    let s := toutRaw.trimAscii.toString.toLower
                    s = "eth"
                  if isEthIn && isEthOut then
                    pure <| .error { code := -32602, message := "ETH→ETH is not a swap", data := none }
                  else
                    -- `resolve` maps "ETH" → WETH on the selected chain, so
                    -- both legs land on the actual pool token regardless of
                    -- direction. The branch below decides how to wrap
                    -- (deposit ETH up front) or unwrap (multicall ending in
                    -- unwrapWETH9) at the router boundary.
                    match LeanKohaku.Swap.Tokens.resolve tinRaw chainId,
                          LeanKohaku.Swap.Tokens.resolve toutRaw chainId with
                    | some (_, tinAddr), some (_, toutAddr) =>
                        let router := LeanKohaku.Swap.UniV3.routerFor chainId
                        if isEthIn then
                          -- ETH→token: multicall([exactInputSingle, refundETH]).
                          -- tokenIn for the swap is WETH (already resolved).
                          let exactCall :=
                            LeanKohaku.Swap.UniV3.encodeExactInputSingle
                              { tokenIn := tinAddr, tokenOut := toutAddr,
                                fee := fee, recipient := recipient,
                                amountIn := amountIn,
                                amountOutMinimum := amountOutMin }
                          let refund := LeanKohaku.Swap.UniV3.encodeRefundETH
                          let mc := LeanKohaku.Swap.UniV3.encodeMulticall [exactCall, refund]
                          pure <| .ok <| .obj #[
                            ("kind", .str "ethToToken"),
                            ("tx", .obj #[
                              ("to", .str router),
                              ("value", .num (Int.ofNat amountIn)),
                              ("data", .str mc)
                            ]),
                            ("router", .str router),
                            ("tokenIn", .str tinAddr),
                            ("tokenOut", .str toutAddr),
                            ("approval", .null)
                          ]
                        else if isEthOut then
                          -- token→ETH: multicall([exactInputSingle(recipient=ADDRESS_THIS),
                          --                       unwrapWETH9(amountOutMin, userRecipient)]).
                          -- WETH stays in the router after the swap leg, then
                          -- unwrapWETH9 withdraws it to native ETH for the user.
                          -- Approval against `tinAddr` is still required (same
                          -- as token→token); the unwrap leg costs no allowance.
                          let exactCall :=
                            LeanKohaku.Swap.UniV3.encodeExactInputSingle
                              { tokenIn := tinAddr, tokenOut := toutAddr,
                                fee := fee,
                                recipient := LeanKohaku.Swap.UniV3.addressThis,
                                amountIn := amountIn,
                                amountOutMinimum := amountOutMin }
                          let unwrapCall :=
                            LeanKohaku.Swap.UniV3.encodeUnwrapWETH9 amountOutMin recipient
                          let mc :=
                            LeanKohaku.Swap.UniV3.encodeMulticall [exactCall, unwrapCall]
                          let allowanceData :=
                            LeanKohaku.Swap.UniV3.encodeAllowance fromAddr router
                          let via? ← colibriVia state chainId.toNat
                          let approval ←
                            (do
                              match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep tinAddr allowanceData "latest" via? with
                              | .ok ret =>
                                  match asString ret with
                                  | some hex =>
                                      match LeanKohaku.Swap.UniV3.decodeWordAt hex 0 with
                                      | some current =>
                                          if current ≥ amountIn then pure Json.null
                                          else
                                            let approveData :=
                                              LeanKohaku.Swap.UniV3.encodeApprove
                                                router LeanKohaku.Swap.UniV3.maxUint256
                                            pure <| Json.obj #[
                                              ("to", .str tinAddr),
                                              ("value", .num 0),
                                              ("data", .str approveData),
                                              ("currentAllowance", .num (Int.ofNat current))
                                            ]
                                      | none => pure Json.null
                                  | none => pure Json.null
                              | .error _ =>
                                  let approveData :=
                                    LeanKohaku.Swap.UniV3.encodeApprove
                                      router LeanKohaku.Swap.UniV3.maxUint256
                                  pure <| Json.obj #[
                                    ("to", .str tinAddr),
                                    ("value", .num 0),
                                    ("data", .str approveData),
                                    ("currentAllowance", .null)
                                  ])
                          pure <| .ok <| .obj #[
                            ("kind", .str "tokenToEth"),
                            ("tx", .obj #[
                              ("to", .str router),
                              ("value", .num 0),
                              ("data", .str mc)
                            ]),
                            ("router", .str router),
                            ("tokenIn", .str tinAddr),
                            ("tokenOut", .str toutAddr),
                            ("approval", approval)
                          ]
                        else
                          -- token→token: plain exactInputSingle, no value.
                          let data :=
                            LeanKohaku.Swap.UniV3.encodeExactInputSingle
                              { tokenIn := tinAddr, tokenOut := toutAddr,
                                fee := fee, recipient := recipient,
                                amountIn := amountIn,
                                amountOutMinimum := amountOutMin }
                          -- Allowance check: read allowance(fromAddr, router).
                          let allowanceData :=
                            LeanKohaku.Swap.UniV3.encodeAllowance fromAddr router
                          let via? ← colibriVia state chainId.toNat
                          let approval ←
                            (do
                              match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep tinAddr allowanceData "latest" via? with
                              | .ok ret =>
                                  match asString ret with
                                  | some hex =>
                                      match LeanKohaku.Swap.UniV3.decodeWordAt hex 0 with
                                      | some current =>
                                          if current ≥ amountIn then pure Json.null
                                          else
                                            let approveData :=
                                              LeanKohaku.Swap.UniV3.encodeApprove
                                                router LeanKohaku.Swap.UniV3.maxUint256
                                            pure <| Json.obj #[
                                              ("to", .str tinAddr),
                                              ("value", .num 0),
                                              ("data", .str approveData),
                                              ("currentAllowance", .num (Int.ofNat current))
                                            ]
                                      | none => pure Json.null
                                  | none => pure Json.null
                              | .error _ =>
                                  -- best-effort: assume approval may be needed
                                  let approveData :=
                                    LeanKohaku.Swap.UniV3.encodeApprove
                                      router LeanKohaku.Swap.UniV3.maxUint256
                                  pure <| Json.obj #[
                                    ("to", .str tinAddr),
                                    ("value", .num 0),
                                    ("data", .str approveData),
                                    ("currentAllowance", .null)
                                  ])
                          pure <| .ok <| .obj #[
                            ("kind", .str "tokenToToken"),
                            ("tx", .obj #[
                              ("to", .str router),
                              ("value", .num 0),
                              ("data", .str data)
                            ]),
                            ("router", .str router),
                            ("tokenIn", .str tinAddr),
                            ("tokenOut", .str toutAddr),
                            ("approval", approval)
                          ]
                    | _, _ =>
                        pure <| .error { code := -32602, message := "could not resolve tokenIn/tokenOut for chain", data := none }
              | _, _, _, _, _, _ => pure (.error invalidParams)
  | "swap.prepareUniswapV3" =>
      -- Why: single-call replacement for the agent's old multi-step
      -- "read allowance → quote → multiply → encode → maybe approve"
      -- prose-orchestrated workflow. Reads pass through `Outbound.ethCall`
      -- (same policy gate as `chain.ethCall`), and the resulting calldata
      -- still flows through `decodeIntent → simulate → ConfirmGate` before
      -- any signature. No new trust surface.
      let chainIdParam :=
        ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
      match paramString req.params "sender",
            paramString req.params "tokenIn",
            paramString req.params "tokenOut",
            getField "amountIn" req.params >>= asNat with
      | .ok sender, .ok tokenIn, .ok tokenOut, some amountIn =>
          let recipient := paramStringD req.params "recipient" sender
          let fee := paramNatD req.params "fee" 3000
          -- `slippageWasDefault` is sticky metadata for the summary
          -- string: only `false` when the JSON-RPC caller supplied an
          -- explicit `slippageBps`.
          let slippageProvided := (getField "slippageBps" req.params >>= asNat).isSome
          let slippageBps := paramNatD req.params "slippageBps" 50
          let deadlineSeconds := paramNatD req.params "deadlineSeconds" 1200
          -- Pre-resolve the endpoint so the closure does not re-walk
          -- the chain-name guess on every read.
          let chainName : Option String :=
            if chainIdParam = 1 then some "mainnet"
            else if chainIdParam = 11155111 then some "sepolia"
            else getField "chain" req.params >>= asString
          match endpointForChain cfg chainName with
          | .error err =>
              pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              let shim : LeanKohaku.Swap.Prepare.ChainEthCallShim :=
                fun to data chainIdForCall => do
                  let via? ← colibriVia state chainIdForCall
                  match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep to data "latest" via? with
                  | .ok ret =>
                      match asString ret with
                      | some hex => pure (.ok hex)
                      | none => pure (.error "non-string return from eth_call")
                  | .error e => pure (.error e)
              let request : LeanKohaku.Swap.Prepare.SwapRequest :=
                { chainId := chainIdParam,
                  sender := sender,
                  recipient := recipient,
                  tokenIn := tokenIn,
                  tokenOut := tokenOut,
                  amountIn := amountIn,
                  fee := fee,
                  slippageBps := slippageBps,
                  slippageWasDefault := !slippageProvided,
                  deadlineSeconds := deadlineSeconds }
              let result ← LeanKohaku.Swap.Prepare.prepareUniswapV3Swap request shim
              pure <| .ok (LeanKohaku.Swap.Prepare.PrepareResult.toJson result)
      | _, _, _, _ => pure (.error invalidParams)
  | "aave.prepare" =>
      -- Why: one daemon RPC for all five Aave V3 Pool user-facing
      -- actions. The agent exposes five typed tools (one per action)
      -- that each call this method with the appropriate `action` tag.
      -- All chain reads go through `Outbound.ethCall` (policy-gated);
      -- the resulting calldata flows through `decodeIntent → simulate
      -- → ConfirmGate` before signing, identical to every other
      -- calldata-producing surface.
      let chainIdParam :=
        ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
      -- Optional `accountKind` hint. When "r1Smart" / "sphincsHybrid"
      -- the daemon collapses a `needs_approval` two-leg result into a
      -- single `executeBatch` call against the sender (the smart wallet
      -- itself). If absent, fall back to `discoverAccountKind` which
      -- scans the local R1 + sphincsHybrid stores by address — that
      -- way the LLM doesn't have to know its own account kind. Both
      -- explicit kind and the discovered kind quietly fall through to
      -- `.eoa` when nothing matches, so external callers and plain
      -- EOAs still get the sequential two-leg shape.
      match paramString req.params "action",
            paramString req.params "sender",
            paramString req.params "asset" with
      | .ok action, .ok sender, .ok asset =>
          let accountKind : LeanKohaku.Wallet.ExecuteBatch.AccountKindHint ←
            match getField "accountKind" req.params >>= asString with
            | some s =>
                pure <|
                  (LeanKohaku.Wallet.ExecuteBatch.AccountKindHint.parse? s).getD
                    LeanKohaku.Wallet.ExecuteBatch.AccountKindHint.eoa
            | none => discoverAccountKind sender
          let chainName : Option String :=
            if chainIdParam = 1 then some "mainnet"
            else if chainIdParam = 11155111 then some "sepolia"
            else getField "chain" req.params >>= asString
          match endpointForChain cfg chainName with
          | .error err =>
              pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              let shim : LeanKohaku.Aave.Prepare.ChainEthCallShim :=
                fun to data chainIdForCall => do
                  let via? ← colibriVia state chainIdForCall
                  match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep to data "latest" via? with
                  | .ok ret =>
                      match asString ret with
                      | some hex => pure (.ok hex)
                      | none => pure (.error "non-string return from eth_call")
                  | .error e => pure (.error e)
              let result ←
                match action with
                | "supply" =>
                    let onBehalfOf := paramStringD req.params "onBehalfOf" sender
                    match getField "amount" req.params >>= asNat with
                    | some amount =>
                        LeanKohaku.Aave.Prepare.prepareSupply
                          chainIdParam sender onBehalfOf asset amount shim
                    | none =>
                        pure (.err "bad_request" "aave.prepare supply: missing or non-numeric 'amount'")
                | "withdraw" =>
                    let recipient := paramStringD req.params "recipient" sender
                    match getField "amount" req.params >>= asNat with
                    | some amount =>
                        LeanKohaku.Aave.Prepare.prepareWithdraw
                          chainIdParam sender recipient asset amount shim
                    | none =>
                        pure (.err "bad_request" "aave.prepare withdraw: missing or non-numeric 'amount'")
                | "borrow" =>
                    let onBehalfOf := paramStringD req.params "onBehalfOf" sender
                    let rateModeStr := paramStringD req.params "rateMode" "variable"
                    match getField "amount" req.params >>= asNat,
                          LeanKohaku.Aave.V3Pool.InterestRateMode.parse? rateModeStr with
                    | some amount, some rateMode =>
                        LeanKohaku.Aave.Prepare.prepareBorrow
                          chainIdParam sender onBehalfOf asset amount rateMode shim
                    | none, _ =>
                        pure (.err "bad_request" "aave.prepare borrow: missing or non-numeric 'amount'")
                    | _, none =>
                        pure (.err "invalid_rate_mode"
                          s!"aave.prepare borrow: 'rateMode' must be 'stable' or 'variable', got: {rateModeStr}")
                | "repay" =>
                    let onBehalfOf := paramStringD req.params "onBehalfOf" sender
                    let rateModeStr := paramStringD req.params "rateMode" "variable"
                    match getField "amount" req.params >>= asNat,
                          LeanKohaku.Aave.V3Pool.InterestRateMode.parse? rateModeStr with
                    | some amount, some rateMode =>
                        LeanKohaku.Aave.Prepare.prepareRepay
                          chainIdParam sender onBehalfOf asset amount rateMode shim
                    | none, _ =>
                        pure (.err "bad_request" "aave.prepare repay: missing or non-numeric 'amount'")
                    | _, none =>
                        pure (.err "invalid_rate_mode"
                          s!"aave.prepare repay: 'rateMode' must be 'stable' or 'variable', got: {rateModeStr}")
                | "setCollateral" =>
                    let useAsCollateral :=
                      match getField "useAsCollateral" req.params with
                      | some (.bool b) => b
                      | _ => true
                    LeanKohaku.Aave.Prepare.prepareSetCollateral
                      chainIdParam sender asset useAsCollateral shim
                | other =>
                    pure (.err "unknown_action"
                      s!"aave.prepare: 'action' must be supply|withdraw|borrow|repay|setCollateral, got: {other}")
              let finalResult :=
                LeanKohaku.Aave.Prepare.maybeBatch sender chainIdParam accountKind result
              pure <| .ok (LeanKohaku.Aave.Prepare.PrepareResult.toJson finalResult)
      | _, _, _ => pure (.error invalidParams)
  | "chain.sendRawTransaction" =>
      match paramString req.params "raw" with
      | .error err => pure (.error err)
      | .ok raw =>
          match LeanKohaku.Crypto.Hex.decode raw with
          | none => pure (.error invalidParams)
          | some bytes =>
              if bytes.isEmpty then
                pure (.error invalidParams)
              else
                match ← LeanKohaku.RPC.Outbound.sendRawTransaction cfg.policy cfg.rpcEndpoint raw with
                | .ok txHash =>
                    pure <| .ok <| .obj #[
                      ("raw", .str raw),
                      ("txHash", txHash)
                    ]
                | .error err =>
                    pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | "chain.resolveName" =>
      match paramString req.params "name" with
      | .error err => pure (.error err)
      | .ok name =>
          -- Why: ENS names are canonical on mainnet; the wallet's operating
          -- chainId is irrelevant for resolution. Always query mainnet (chainId 1)
          -- against the user-configured ENS RPC; no fallback to cfg.rpcEndpoint.
          match cfg.ensRpcEndpoint with
          | none =>
              pure <| .error {
                code := -32030,
                message :=
                  "no ENS RPC configured: set LEANKOHAKU_ENS_RPC_URL or 'ens_rpc_url' in daemon.json (mainnet RPC required for ENS resolution)",
                data := none }
          | some ensEndpoint =>
              -- ENS is mainnet (chainId 1), independent of cfg.chainId.
              let viaEns? ← colibriVia state 1
              match ← LeanKohaku.Ethereum.Ens.resolveIO cfg.policy ensEndpoint 1 name viaEns? with
              | .ok r =>
                  pure <| .ok <| .obj #[
                    ("name", .str r.name),
                    ("address", .str r.address),
                    ("chainId", .num (Int.ofNat r.chainId)),
                    ("resolver", .str r.resolver)
                  ]
              | .error (code, msg) =>
                  pure <| .error { code := code, message := msg, data := none }
  | "eoa.list" =>
      let names ← LeanKohaku.Wallet.EoaStore.list
      let records ← names.foldlM
        (fun acc name => do
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .ok record => pure (acc.push (← slotMetadataJson state record))
          | .error _ => pure acc)
        #[]
      pure (.ok (.arr records))
  | "account.list" =>
      -- Why: unified replacement for the CLI's three combined-list helpers
      -- (`printAccountListNames`, `printAccountListTypedNames`,
      -- `printAccountListIndices`). Each returns a different projection of
      -- the same data; consolidating to one daemon RPC removes ~80 LoC of
      -- near-duplicate CLI code.
      let eoaNames ← LeanKohaku.Wallet.EoaStore.list
      let mut entries : Array Json := #[]
      for name in eoaNames do
        match ← LeanKohaku.Wallet.EoaStore.load name with
        | .ok record =>
            let indices : Array Json :=
              (recordAccounts record).map (fun a => .num (Int.ofNat a.index))
            entries := entries.push <| .obj #[
              ("type",    .str "eoa"),
              ("name",    .str record.name),
              ("address", .str record.address),
              ("indices", .arr indices)
            ]
        | .error _ => pure ()
      let tpmNames ← listSepoliaKeys
      let stateDir : System.FilePath := ".leankohaku/keystore/tpm2"
      for name in tpmNames do
        let addrFile := stateDir / name / "r1-account-address.txt"
        let address ←
          if ← addrFile.pathExists then
            let raw ← IO.FS.readFile addrFile
            pure raw.trimAscii.toString
          else pure ""
        entries := entries.push <| .obj #[
          ("type",    .str "tpm"),
          ("name",    .str name),
          ("address", .str address)
        ]
      -- SPHINCS- hybrid smart accounts. Each slot's identity is its
      -- CREATE2 smart-account address; we surface it as `address` so
      -- the TUI / CLI can treat it uniformly with EOA / TPM rows. When
      -- the counterfactual hasn't been computed yet the field stays
      -- empty — the SphincsAccountsHub detail view exposes "Compute
      -- counterfactual address" to populate it.
      try
        let sphincsNames ← LeanKohaku.Wallet.SphincsHybridStore.listSlotNames
        for name in sphincsNames do
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .ok rec =>
              entries := entries.push <| .obj #[
                ("type",     .str "sphincs"),
                ("name",     .str rec.name),
                ("address",  .str (rec.smartAccountAddress.getD "")),
                ("paramSet", .str rec.paramSet.toString),
                ("chainId",  .num (Int.ofNat rec.chainId)),
                ("owner",    .str rec.ownerAddress)
              ]
          | .error _ => pure ()
      catch _ => pure ()
      pure (.ok (.obj #[("accounts", .arr entries)]))
  | "eoa.show" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .ok record => pure (.ok (← slotMetadataJson state record))
          | .error err =>
              pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
  | "eoa.address" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .ok record => pure (.ok (.str record.address))
          | .error err =>
              pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
  | "eoa.import" =>
      match ← saveMnemonicSlot state req.params none with
      | .error err => pure (.error err)
      | .ok (record, _) => pure (.ok (← importResultJson state record))
  | "eoa.create" =>
      try
        let wordCount := paramNatD req.params "wordCount" 12
        let mnemonic ← LeanKohaku.Wallet.Entropy.generateMnemonic wordCount
        match ← saveMnemonicSlot state req.params (some mnemonic) with
        | .error err => pure (.error err)
        | .ok (record, mnemonic?) => pure (.ok (← importResultJson state record mnemonic?))
      catch e =>
        pure <| .error { invalidParams with data := some (.str e.toString) }
  | "sphincs.account.create" =>
      -- Create a hybrid ECDSA + SPHINCS- ERC-4337 account record. The
      -- SPHINCS sk is generated locally by the shim from a fresh
      -- 48-/32-byte random seed (per `ParamSet.expectedSeedBytes`),
      -- sealed under the per-slot passphrase, and additionally wrapped
      -- under the daemon's master KEK if one is loaded. The ECDSA half
      -- references an existing wallet account or a freshly-derived
      -- sub-path under the wallet's BIP-39 seed.
      --
      -- Params:
      --   name           : slot name (unique in sphincs-hybrid namespace)
      --   paramSet       : "SLH-DSA-SHA2-128-24" | "JARDIN-Keccak-128-24" | "C9"
      --   chainId        : optional (defaults to daemon's primary chainId)
      --   walletName     : EOA wallet supplying the ECDSA half
      --   ecdsaKind      : "existing" | "derived"   (default "existing")
      --   accountIndex   : (existing only) index in wallet's accounts; default 0
      --   path           : (derived only) BIP-44 path; default = wallet's path
      --   walletPassphrase : passphrase to unlock the wallet for `derived` ECDSA
      --   passphrase     : per-slot passphrase used to seal the SPHINCS- sk
      match paramName req.params,
            paramString req.params "paramSet",
            paramString req.params "walletName" with
      | .ok name, .ok psStr, .ok walletName =>
          let chainId := paramNatD req.params "chainId" cfg.chainId
          let ecdsaKind := paramStringD req.params "ecdsaKind" "existing"
          -- Passphrase is optional when the master KEK is in memory
          -- (same pattern as `eoa.create` / `saveMnemonicSlot`). If
          -- empty/missing AND KEK is loaded, we mint a 32-byte ephemeral
          -- passphrase that only ever exists in this process; the slot
          -- becomes master-unlockable on next call thanks to the
          -- best-effort `masterWrap` write below. The ephemeral isn't
          -- returned to the client and isn't a recovery factor.
          let userSuppliedPassphrase : Bool :=
            match paramString req.params "passphrase" with
            | .ok p => p.length > 0
            | .error _ => false
          let masterSlot? ← LeanKohaku.Daemon.State.getMasterKek? state
          let passphraseExcept : Except String String := do
            match paramString req.params "passphrase" with
            | .ok p =>
                if p.length > 0 then .ok p
                else if masterSlot?.isSome then .ok ""  -- placeholder, replaced below
                else .error "missing passphrase (no master KEK loaded — set one with `wallet master init` or pick a per-slot passphrase)"
            | .error _ =>
                if masterSlot?.isSome then .ok ""
                else .error "missing passphrase (no master KEK loaded — set one with `wallet master init` or pick a per-slot passphrase)"
          match passphraseExcept with
          | .error e =>
              pure <| .error { invalidParams with data := some (.str e) }
          | .ok rawPp =>
          let slotPassphrase ←
            if rawPp.length > 0 then pure rawPp
            else do
              let bytes ← LeanKohaku.Crypto.Random.getRandomBytes 32
              pure (LeanKohaku.Crypto.Hex.encode bytes)
          match LeanKohaku.Sphincs.ParamSet.parse? psStr with
          | none =>
              pure <| .error
                { invalidParams with data := some (.str s!"unknown paramSet: {psStr}") }
          | some ps =>
              match ← LeanKohaku.Wallet.EoaStore.load walletName with
              | .error err =>
                  pure <| .error
                    { code := -32010, message := "wallet not found",
                      data := some (.str err) }
              | .ok walletRec =>
                  -- Resolve ECDSA owner address + attachment record.
                  let resolved : IO
                      (Except String (String × LeanKohaku.Wallet.Account.EcdsaAttachment)) :=
                    match ecdsaKind with
                    | "existing" =>
                        let idx := paramNatD req.params "accountIndex" 0
                        match walletRec.accounts.find? (fun a => a.index == idx) with
                        | none =>
                            pure (.error s!"wallet '{walletName}' has no account at index {idx}")
                        | some acct =>
                            pure (.ok (acct.address,
                                        .existing walletName idx))
                    | "derived" =>
                        let pathStr :=
                          paramStringD req.params "path" walletRec.derivationPath
                        match paramString req.params "walletPassphrase" with
                        | .error _ =>
                            pure (.error "ecdsaKind='derived' requires walletPassphrase")
                        | .ok walletPp => do
                            match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO
                                walletRec walletPp with
                            | .error err => pure (.error s!"wallet unlock: {err}")
                            | .ok seed => do
                                match ← deriveAddressFromSeed seed pathStr with
                                | .error err => pure (.error err)
                                | .ok addr =>
                                    match LeanKohaku.Wallet.SphincsHybridStore.derivationPathFromString
                                          pathStr with
                                    | .error err => pure (.error err)
                                    | .ok dpath =>
                                        pure (.ok (addr, .derived walletName dpath))
                    | other =>
                        pure (.error s!"unknown ecdsaKind '{other}' (use 'existing' or 'derived')")
                  match ← resolved with
                  | .error err =>
                      pure <| .error
                        { invalidParams with data := some (.str err) }
                  | .ok (ownerAddress, attachment) =>
                      -- Generate fresh SPHINCS- seed + spawn shim keygen.
                      let seedBytes ← LeanKohaku.Crypto.Random.getRandomBytes
                        ps.expectedSeedBytes
                      let seedHex := LeanKohaku.Crypto.Hex.encode seedBytes
                      match ← LeanKohaku.Sphincs.keygen ps seedHex with
                      | Except.error e =>
                          pure <| Except.error
                            { code := -32040,
                              message := "sphincs keygen failed",
                              data := some (.str (reprStr e)) }
                      | Except.ok km =>
                          let kdfSalt ← LeanKohaku.Crypto.Random.getRandomBytes 16
                          let iters := LeanKohaku.Wallet.SphincsHybridStore.defaultKdfIters
                          match ← LeanKohaku.Wallet.SphincsHybridStore.sealSk
                              name ps ownerAddress slotPassphrase km.sk
                              kdfSalt iters with
                          | .error err =>
                              pure <| .error
                                { code := -32041,
                                  message := "sphincs sk seal failed",
                                  data := some (.str err) }
                          | .ok passphraseCt =>
                              -- Best-effort master-KEK wrap. Failure here
                              -- is non-fatal — the slot still works
                              -- through `passphraseCiphertext`. Reuses
                              -- `masterSlot?` captured above so we don't
                              -- race with a TTL-driven re-lock.
                              let masterWrap? : Option ByteArray ←
                                match masterSlot? with
                                | none => pure none
                                | some mslot =>
                                    match ← LeanKohaku.Wallet.SphincsHybridStore.sealUnderMaster
                                        mslot.kek name ps ownerAddress km.sk with
                                    | .error _ => pure none
                                    | .ok w => pure (some w)
                              let now ← IO.monoMsNow
                              let baseRecord : LeanKohaku.Wallet.SphincsHybridStore.Record := {
                                version := LeanKohaku.Wallet.SphincsHybridStore.currentVersion,
                                name := name,
                                paramSet := ps,
                                chainId := chainId,
                                ecdsaAttachment := attachment,
                                ownerAddress := ownerAddress,
                                pkSeed := km.pkSeed,
                                pkRoot := km.pkRoot,
                                kdfSalt := kdfSalt,
                                kdfIters := iters,
                                passphraseCiphertext := passphraseCt,
                                masterWrap := masterWrap?,
                                smartAccountAddress := none,
                                customPassphrase := userSuppliedPassphrase,
                                createdAt := now / 1000
                              }
                              -- Auto-compute the counterfactual address when a
                              -- factory is configured for (chain, paramSet).
                              -- The helper swallows errors so the create RPC
                              -- still succeeds even if the factory is
                              -- unreachable or not yet deployed.
                              let saa? ← tryComputeSmartAccountAddress cfg baseRecord
                              let slotRecord := { baseRecord with smartAccountAddress := saa? }
                              try
                                LeanKohaku.Wallet.SphincsHybridStore.writeRecord slotRecord
                                pure <| .ok <| .obj #[
                                  ("name",         .str name),
                                  ("paramSet",     .str ps.toString),
                                  ("chainId",      .num (Int.ofNat chainId)),
                                  ("ownerAddress", .str ownerAddress),
                                  ("pkSeed",       .str km.pkSeed),
                                  ("pkRoot",       .str km.pkRoot),
                                  ("masterEnrolled", .bool masterWrap?.isSome),
                                  ("smartAccountAddress",
                                    match saa? with | some a => .str a | none => .null)
                                ]
                              catch e =>
                                pure <| .error
                                  { code := -32042,
                                    message := "sphincs slot write failed",
                                    data := some (.str e.toString) }
      | _, _, _ => pure (.error invalidParams)
  | "sphincs.account.list" =>
      -- Enumerate hybrid slots on disk. Returns a JSON array of
      -- `{name, paramSet, chainId, ownerAddress, pkSeed, pkRoot,
      --   masterEnrolled, smartAccountAddress?, customPassphrase, createdAt}`
      -- per slot. Best-effort: parse failures on individual files are
      -- swallowed (the slot is omitted from the result) so a single
      -- corrupt file doesn't poison the whole list.
      try
        let names ← LeanKohaku.Wallet.SphincsHybridStore.listSlotNames
        let mut entries : Array Json := #[]
        for n in names do
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord n with
          | .error _ => pure ()
          | .ok r =>
              let attachJson : Json :=
                LeanKohaku.Wallet.SphincsHybridStore.ecdsaAttachmentToJson r.ecdsaAttachment
              let smart : Json :=
                match r.smartAccountAddress with
                | some a => .str a
                | none => .null
              entries := entries.push <| .obj #[
                ("name",                .str r.name),
                ("paramSet",            .str r.paramSet.toString),
                ("chainId",             .num (Int.ofNat r.chainId)),
                ("ownerAddress",        .str r.ownerAddress),
                ("ecdsaAttachment",     attachJson),
                ("pkSeed",              .str r.pkSeed),
                ("pkRoot",              .str r.pkRoot),
                ("masterEnrolled",      .bool r.masterWrap.isSome),
                ("smartAccountAddress", smart),
                ("customPassphrase",    .bool r.customPassphrase),
                ("createdAt",           .num (Int.ofNat r.createdAt))
              ]
        pure <| .ok <| .obj #[("accounts", .arr entries)]
      catch e =>
        pure <| .error
          { code := -32043,
            message := "sphincs.account.list failed",
            data := some (.str e.toString) }
  | "sphincs.account.show" =>
      -- Render a single hybrid slot's public state. Mirrors the per-row
      -- shape from `sphincs.account.list`. The sk is never returned.
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error err =>
              pure <| .error
                { code := -32010, message := "sphincs slot not found",
                  data := some (.str err) }
          | .ok r =>
              let attachJson : Json :=
                LeanKohaku.Wallet.SphincsHybridStore.ecdsaAttachmentToJson r.ecdsaAttachment
              let smart : Json :=
                match r.smartAccountAddress with
                | some a => .str a
                | none => .null
              pure <| .ok <| .obj #[
                ("name",                .str r.name),
                ("paramSet",            .str r.paramSet.toString),
                ("chainId",             .num (Int.ofNat r.chainId)),
                ("ownerAddress",        .str r.ownerAddress),
                ("ecdsaAttachment",     attachJson),
                ("pkSeed",              .str r.pkSeed),
                ("pkRoot",              .str r.pkRoot),
                ("masterEnrolled",      .bool r.masterWrap.isSome),
                ("smartAccountAddress", smart),
                ("customPassphrase",    .bool r.customPassphrase),
                ("createdAt",           .num (Int.ofNat r.createdAt))
              ]
  | "sphincs.account.computeAddress" =>
      -- eth_call factory.getAddress(owner, pkSeed, pkRoot) → counterfactual
      -- smart-account address. The factory's own view function does the
      -- CREATE2 math, so Lean only assembles the 100-byte calldata and
      -- slices the returned 32-byte word's last 20 bytes. On success, the
      -- on-disk record's `smartAccountAddress` is updated in place; the
      -- next `sphincs.account.show` reads it back without a fresh RPC.
      -- Fails closed when no factory is configured for (chain, paramSet).
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error err =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str err) }
          | .ok rec =>
              -- Caller passes `chain` (e.g. "sepolia"); the slot's
              -- `chainId` is the source of truth — if `chain` is omitted
              -- we fall back to a name guess via the policy table.
              let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
              match sphincsFactoryFor cfg chainName rec.paramSet,
                    endpointForChain cfg (some chainName) with
              | .error e, _ | _, .error e =>
                  pure <| .error { code := -32030, message := "sphincs factory/endpoint unavailable", data := some (.str e) }
              | .ok factory, .ok ep =>
                  -- selector(getAddress(address,bytes32,bytes32)) + 3 × 32B
                  match ← LeanKohaku.Crypto.Hacl.keccak256EthereumIO
                      (LeanKohaku.Crypto.Hex.encode "getAddress(address,bytes32,bytes32)".toByteArray) with
                  | .error e => pure <| .error { code := -32031, message := "keccak failed", data := some (.str e) }
                  | .ok kh =>
                      -- Concat in ByteArray space then hex-encode once;
                      -- see `tryComputeSmartAccountAddress` for the
                      -- "Hex.encode always prepends 0x" rationale.
                      let selBytes := kh.extract 0 4
                      let ownerBytes : ByteArray :=
                        (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.ownerAddress).getD ByteArray.empty
                      let pkSeedB : ByteArray :=
                        (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.pkSeed).getD ByteArray.empty
                      let pkRootB : ByteArray :=
                        (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.pkRoot).getD ByteArray.empty
                      let dataHex := LeanKohaku.Crypto.Hex.encode
                        (selBytes ++ ownerBytes ++ pkSeedB ++ pkRootB)
                      match ← LeanKohaku.RPC.Outbound.ethCall cfg.policy ep factory dataHex "latest" none with
                      | .error e =>
                          pure <| .error { code := -32020, message := "eth_call failed", data := some (.str e) }
                      | .ok ret =>
                          let retHex := (asString ret).getD ""
                          let cleaned : String :=
                            if retHex.startsWith "0x" then (retHex.drop 2).toString else retHex
                          if cleaned.length < 64 then
                            pure <| .error { code := -32032, message := "unexpected returnData", data := some (.str retHex) }
                          else
                            -- last 20 bytes (40 hex chars) of the 32-byte word
                            let addrHex : String :=
                              "0x" ++ String.ofList (cleaned.toList.drop (cleaned.length - 40))
                            try
                              LeanKohaku.Wallet.SphincsHybridStore.writeRecord
                                { rec with smartAccountAddress := some addrHex }
                            catch _ => pure ()
                            pure <| .ok <| .obj #[
                              ("name", .str name),
                              ("smartAccountAddress", .str addrHex),
                              ("factory", .str factory)
                            ]
  | "sphincs.account.deploy" =>
      -- Build calldata for factory.createAccount(owner, pkSeed, pkRoot)
      -- and submit through the existing EOA pipeline. The deployer EOA
      -- pays gas — picked by the caller via `deployerWallet` + an
      -- optional `deployerAccountIndex` (defaults to 0). On success we
      -- echo the tx hash plus the post-deploy smart-account address
      -- (taken from `rec.smartAccountAddress` if already populated by
      -- `computeAddress`; otherwise the caller should call that first).
      match paramName req.params, paramString req.params "deployerWallet" with
      | .ok name, .ok deployer =>
          let deployerIdx := paramNatD req.params "deployerAccountIndex" 0
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error err =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str err) }
          | .ok rec =>
              -- Caller passes `chain` (e.g. "sepolia"); the slot's
              -- `chainId` is the source of truth — if `chain` is omitted
              -- we fall back to a name guess via the policy table.
              let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
              match sphincsFactoryFor cfg chainName rec.paramSet,
                    endpointForChain cfg (some chainName) with
              | .error e, _ | _, .error e =>
                  pure <| .error { code := -32030, message := "sphincs factory/endpoint unavailable", data := some (.str e) }
              | .ok factory, .ok ep =>
                  match ← unlockedSlot state deployer with
                  | .error e => pure (.error e)
                  | .ok dslot =>
                      let cfgEff : Config :=
                        let cid := (LeanKohaku.RPC.Outbound.chainNameToId chainName).getD cfg.chainId
                        { cfg with rpcEndpoint := ep, chainId := cid }
                      -- Resolve deployer's account index → derivation path & address.
                      match ← LeanKohaku.Wallet.EoaStore.load deployer with
                      | .error e => pure <| .error { code := -32010, message := "deployer wallet not found", data := some (.str e) }
                      | .ok dRec =>
                          match dRec.accounts.find? (fun a => a.index == deployerIdx) with
                          | none => pure <| .error { code := -32011, message := s!"deployer has no account #{deployerIdx}", data := none }
                          | some dAcct =>
                              match ← derivePrivateKeyFromSeed dslot.seed dAcct.path with
                              | .error e => pure <| .error { code := -32012, message := "deployer key derive failed", data := some (.str e) }
                              | .ok privKey =>
                                  match ← LeanKohaku.Crypto.Hacl.keccak256EthereumIO
                                      (LeanKohaku.Crypto.Hex.encode "createAccount(address,bytes32,bytes32)".toByteArray) with
                                  | .error e => pure <| .error { code := -32031, message := "keccak failed", data := some (.str e) }
                                  | .ok kh =>
                                      let sel := LeanKohaku.Crypto.Hex.encode (kh.extract 0 4)
                                      let ownerB := (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.ownerAddress).getD ByteArray.empty
                                      let pkSeedB := (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.pkSeed).getD ByteArray.empty
                                      let pkRootB := (LeanKohaku.Sphincs.UserOp.hexToWord32? rec.pkRoot).getD ByteArray.empty
                                      let selBytes := (LeanKohaku.Crypto.Hex.decode sel).getD ByteArray.empty
                                      let dataBytes := selBytes ++ ownerB ++ pkSeedB ++ pkRootB
                                      let dslot' := { dslot with address := dAcct.address, derivationPath := dAcct.path }
                                      match LeanKohaku.Ethereum.Address.fromHex factory with
                                      | none => pure (.error invalidParams)
                                      | some factoryAddr =>
                                          let via? ← colibriVia state cfgEff.chainId
                                          match ← buildSignBroadcastTx cfgEff dslot' privKey factory factoryAddr 0 dataBytes none none via? with
                                          | .error e => pure (.error e)
                                          | .ok j =>
                                              -- Echo the slot's smart-account address (set by
                                              -- `computeAddress` ahead of time when possible).
                                              let saa : Json :=
                                                match rec.smartAccountAddress with
                                                | some a => .str a
                                                | none => .null
                                              pure <| .ok <| .obj #[
                                                ("name", .str name),
                                                ("factory", .str factory),
                                                ("smartAccountAddress", saa),
                                                ("tx", j)
                                              ]
      | _, _ => pure (.error invalidParams)
  | "sphincs.account.send" =>
      -- Submit a UserOperation from a hybrid SPHINCS- account through the
      -- configured bundler. The signature field is `abi.encode(bytes
      -- ecdsaSig, bytes sphincsSig)` matching the on-chain
      -- `_validateSignature` decoder. The pipeline (sk unlock, ECDSA
      -- derive, gas estimate, dual-sign, submit) lives in
      -- `executeSphincsUserOp`; this RPC only assembles the `execute(...)`
      -- callData from {to, value, data} before delegating.
      --
      -- `valueEth` (decimal ETH, the canonical human-readable form, e.g.
      -- "0.001") is preferred when present; `value` (wei — decimal Nat
      -- or 0x-hex) stays as a fallback for power-users / scripted
      -- callers. Parser conversion lives in `LeanKohaku.Util.Units` so
      -- the TUI stays a thin RPC forwarder.
      match paramName req.params, paramString req.params "to" with
      | .ok name, .ok toStr =>
          let valueWei : Nat :=
            match paramString req.params "valueEth" with
            | .ok ethStr =>
                (LeanKohaku.Util.Units.parseUnits ethStr 18).getD 0
            | .error _ =>
                match paramString req.params "value" with
                | .ok valueStr =>
                    (valueStr.toNat?).getD ((parseHexQuantity valueStr).getD 0)
                | .error _ => 0
          let dataHex := paramStringD req.params "data" "0x"
          let userData : ByteArray :=
            (LeanKohaku.Crypto.Hex.decode dataHex).getD ByteArray.empty
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error e => pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match ← executeSphincsUserOp cfg state notify rec toStr valueWei userData req.params with
              | .error e => pure (.error e)
              | .ok j =>
                  -- Echo the slot name on top of the helper's result.
                  let withName : Json := match j with
                    | .obj fields => .obj (fields.push ("name", .str name))
                    | _ => j
                  pure (.ok withName)
      | _, _ => pure (.error invalidParams)
  | "sphincs.account.rotateOwner" =>
      -- Submit a UserOp that calls `SphincsAccount.rotateOwner(newOwner)`.
      -- The on-chain contract gates this on the EntryPoint OR self-call;
      -- we wrap the rotate calldata in `execute(self, 0, rotateData)` so
      -- the EntryPoint forwards through the account, producing the
      -- `address(this)` self-call branch. The local store is NOT updated
      -- automatically — the caller must reconfigure the slot (or its
      -- `ecdsaAttachment`) after confirming the userOp succeeded on-chain
      -- via `sphincs.account.getUserOp`.
      match paramName req.params, paramString req.params "newOwner" with
      | .ok name, .ok newOwner =>
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error e => pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none => pure <| .error { code := -32033, message := "smartAccountAddress unset", data := none }
              | some sender =>
                  match ← Sphincs.Send.buildRotateOwnerCalldata newOwner with
                  | .error e => pure <| .error { code := -32035, message := "rotateOwner calldata build failed", data := some (.str e) }
                  | .ok rotateData =>
                      match ← executeSphincsUserOp cfg state notify rec sender 0 rotateData req.params with
                      | .error e => pure (.error e)
                      | .ok j =>
                          let withFields : Json := match j with
                            | .obj fs =>
                                .obj (fs.push ("name", .str name)
                                        |>.push ("newOwner", .str newOwner))
                            | _ => j
                          pure (.ok withFields)
      | _, _ => pure (.error invalidParams)
  | "sphincs.account.encodeRotateOwner" =>
      -- Returns the raw rotateOwner(address) ABI calldata plus the
      -- slot's smart-account address. Lets the TUI route rotations
      -- through SendRawFlow's ConfirmGate before broadcast: the gate
      -- needs the to/value/data shape that the simulator can eth_call.
      -- The daemon's sphincs.account.send then wraps this calldata in
      -- execute(self, 0, calldata) at signing time, identical to what
      -- the older sphincs.account.rotateOwner RPC did internally.
      match paramName req.params, paramString req.params "newOwner" with
      | .ok name, .ok newOwner =>
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error e => pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none => pure <| .error { code := -32033, message := "smartAccountAddress unset", data := none }
              | some sender =>
                  match ← Sphincs.Send.buildRotateOwnerCalldata newOwner with
                  | .error e => pure <| .error { code := -32035, message := "rotateOwner calldata build failed", data := some (.str e) }
                  | .ok rotateData =>
                      pure <| .ok <| .obj #[
                        ("name", .str name),
                        ("newOwner", .str newOwner),
                        ("smartAccountAddress", .str sender),
                        ("calldata", .str (LeanKohaku.Crypto.Hex.encode rotateData)) ]
      | _, _ => pure (.error invalidParams)
  | "sphincs.bundler.show" =>
      -- Returns the bundler URL the daemon will use for sphincs userOps,
      -- with the same chain-resolution priority as the poll RPC:
      --   1. explicit `chain` param
      --   2. the slot's chainId (when `name` is supplied)
      --   3. daemon's default chainId
      -- The URL is sourced from `cfg.sphincsBundlers`, which is seeded
      -- from `daemon.json` -> `sphincs_bundlers` (or built-in defaults).
      -- To override at runtime, edit daemon.json and restart.
      let slotChain? : IO (Option String) := do
        match paramName req.params with
        | .error _ => pure none
        | .ok slotName =>
            match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord slotName with
            | .ok rec => pure (some (chainNameGuess rec.chainId))
            | .error _ => pure none
      let chainName ← do
        match paramString req.params "chain" with
        | .ok c => pure c
        | .error _ =>
            match ← slotChain? with
            | some c => pure c
            | none => pure (chainNameGuess cfg.chainId)
      let bundler : Json := match sphincsBundlerFor cfg chainName with
        | .ok url => .str url
        | .error _ => .null
      pure <| .ok <| .obj #[
        ("chain", .str chainName),
        ("bundler", bundler),
        ("source", .str "daemon.json or built-in default; edit daemon.json under sphincs_bundlers to override")
      ]
  | "sphincs.account.commitRotation" =>
      -- Atomically rewrite a sphincs-hybrid slot's `ecdsaAttachment`
      -- and `ownerAddress` to match a NEW owner address. Call this
      -- AFTER `sphincs.account.rotateOwner` succeeded on-chain (i.e.
      -- after `sphincs.account.getUserOp` returned a receipt with
      -- success=true). Verifies the on-chain `owner()` view to refuse
      -- desyncing the slot when the rotation never landed.
      --
      -- Params:
      --   name                 : sphincs slot name
      --   newOwner             : new owner address (must equal on-chain owner())
      --   newWalletName        : EOA wallet that owns newOwner
      --   newAccountIndex      : optional (default 0); wallet's accounts[idx].address
      --                          must equal newOwner
      match paramName req.params,
            paramString req.params "newOwner",
            paramString req.params "newWalletName" with
      | .ok name, .ok newOwner, .ok newWalletName =>
          let newIdx : Nat := (getField "newAccountIndex" req.params >>= asNat).getD 0
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error e =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match ← LeanKohaku.Wallet.EoaStore.load newWalletName with
              | .error e =>
                  pure <| .error { code := -32010, message := "newWalletName not found", data := some (.str e) }
              | .ok wRec =>
                  match wRec.accounts.find? (fun a => a.index == newIdx) with
                  | none =>
                      pure <| .error { code := -32602, message := s!"wallet has no account #{newIdx}", data := none }
                  | some acct =>
                      let walletAddr := acct.address.toLower
                      let claimedAddr := newOwner.toLower
                      if walletAddr ≠ claimedAddr then
                        pure <| .error
                          { code := -32602,
                            message := "newWalletName/newAccountIndex does not own newOwner",
                            data := some (.str s!"wallet[#{newIdx}]={walletAddr} but newOwner={claimedAddr}") }
                      else
                        -- Verify on-chain owner matches.
                        match rec.smartAccountAddress with
                        | none => pure <| .error { code := -32033, message := "smartAccountAddress unset", data := none }
                        | some sender =>
                            let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
                            match endpointForChain cfg (some chainName) with
                            | .error e => pure <| .error { code := -32021, message := "unknown chain", data := some (.str e) }
                            | .ok ep =>
                                -- owner() selector = keccak256("owner()")[:4] = 0x8da5cb5b
                                match ← LeanKohaku.RPC.Outbound.call cfg.policy ep
                                    .call (.arr #[.obj #[("to", .str sender), ("data", .str "0x8da5cb5b")], .str "latest"]) none with
                                | .error e => pure <| .error { code := -32020, message := "owner() call failed", data := some (.str e) }
                                | .ok r =>
                                    let onChainHex := (asString r).getD "0x"
                                    -- Last 20 bytes of the returned 32-byte word.
                                    let stripped := if onChainHex.startsWith "0x" then onChainHex.drop 2 else onChainHex.toSlice
                                    let raw := stripped.toString.toLower
                                    let onChainOwner :=
                                      if raw.length >= 40 then "0x" ++ (raw.drop (raw.length - 40)) else ""
                                    if onChainOwner ≠ claimedAddr then
                                      pure <| .error
                                        { code := -32034,
                                          message := "on-chain owner does not match newOwner; rotation didn't land?",
                                          data := some (.str s!"chain owner={onChainOwner} but newOwner={claimedAddr}") }
                                    else
                                      -- The SPHINCS sk wrap's AAD binds to
                                      -- `(name, paramSet, ownerAddress)` — see
                                      -- `SphincsHybridStore.aad` — so changing
                                      -- ownerAddress without re-wrapping
                                      -- would invalidate every unlock path.
                                      -- Unwrap the sk via master OR
                                      -- per-slot, then re-seal both wraps
                                      -- under the new AAD.
                                      --
                                      -- Recovery mode: an earlier buggy
                                      -- version of this RPC rewrote
                                      -- ownerAddress without re-wrapping.
                                      -- If the caller passes `oldOwner`,
                                      -- we override the AAD on the
                                      -- unwrap side so we can decrypt
                                      -- the original wrap and then
                                      -- re-seal cleanly. Once recovery
                                      -- runs once, the slot's wrap AAD
                                      -- matches rec.ownerAddress again
                                      -- and oldOwner is no longer needed.
                                      let oldOwner? := (paramString req.params "oldOwner").toOption
                                      let unwrapRec : LeanKohaku.Wallet.SphincsHybridStore.Record :=
                                        match oldOwner? with
                                        | some oo => { rec with ownerAddress := oo }
                                        | none => rec
                                      let masterSlot? ← LeanKohaku.Daemon.State.getMasterKek? state
                                      let unlockExc : IO (Except String String) := do
                                        match masterSlot? with
                                        | some mslot =>
                                            match ← LeanKohaku.Wallet.SphincsHybridStore.openWithMaster mslot.kek unwrapRec with
                                            | .ok skHex => pure (.ok skHex)
                                            | .error _ =>
                                                -- Master path failed (e.g.
                                                -- slot pre-dates master
                                                -- enrolment). Fall back to
                                                -- per-slot passphrase if
                                                -- provided.
                                                match paramString req.params "passphrase" with
                                                | .ok pp => LeanKohaku.Wallet.SphincsHybridStore.openSk unwrapRec pp
                                                | _ => pure (.error "master path failed and no per-slot passphrase provided")
                                        | none =>
                                            match paramString req.params "passphrase" with
                                            | .ok pp => LeanKohaku.Wallet.SphincsHybridStore.openSk unwrapRec pp
                                            | _ => pure (.error "no master KEK loaded and no per-slot passphrase provided")
                                      match ← unlockExc with
                                      | .error e =>
                                          pure <| .error
                                            { code := -32011,
                                              message := "sphincs sk unlock failed (needed to re-seal under new owner AAD)",
                                              data := some (.str e) }
                                      | .ok skHex =>
                                          -- Mint a fresh ephemeral
                                          -- passphrase for the new
                                          -- per-slot wrap. Same shape as
                                          -- `sphincs.account.create`'s
                                          -- non-customPassphrase path.
                                          let newPpBytes ← LeanKohaku.Crypto.Random.getRandomBytes 32
                                          let newPp :=
                                            if rec.customPassphrase then
                                              -- Caller must supply passphrase
                                              -- for slots they manage; reuse
                                              -- it for the new wrap.
                                              (paramString req.params "passphrase").toOption.getD
                                                (LeanKohaku.Crypto.Hex.encode newPpBytes)
                                            else LeanKohaku.Crypto.Hex.encode newPpBytes
                                          let newKdfSalt ← LeanKohaku.Crypto.Random.getRandomBytes 16
                                          let newIters := LeanKohaku.Wallet.SphincsHybridStore.defaultKdfIters
                                          match ← LeanKohaku.Wallet.SphincsHybridStore.sealSk
                                              rec.name rec.paramSet newOwner newPp skHex
                                              newKdfSalt newIters with
                                          | .error err =>
                                              pure <| .error
                                                { code := -32041,
                                                  message := "sphincs sk re-seal failed",
                                                  data := some (.str err) }
                                          | .ok newPpCt =>
                                              let newMasterWrap? : Option ByteArray ← match masterSlot? with
                                                | none => pure none
                                                | some mslot =>
                                                    match ← LeanKohaku.Wallet.SphincsHybridStore.sealUnderMaster
                                                        mslot.kek rec.name rec.paramSet newOwner skHex with
                                                    | .ok w => pure (some w)
                                                    | .error _ => pure none
                                              let updated : LeanKohaku.Wallet.SphincsHybridStore.Record :=
                                                { rec with
                                                  ownerAddress := newOwner,
                                                  ecdsaAttachment :=
                                                    LeanKohaku.Wallet.Account.EcdsaAttachment.existing newWalletName newIdx,
                                                  kdfSalt := newKdfSalt,
                                                  kdfIters := newIters,
                                                  passphraseCiphertext := newPpCt,
                                                  masterWrap := newMasterWrap? }
                                              LeanKohaku.Wallet.SphincsHybridStore.writeRecord updated
                                              pure <| .ok <| .obj #[
                                                ("name", .str name),
                                                ("newOwner", .str newOwner),
                                                ("newWalletName", .str newWalletName),
                                                ("newAccountIndex", .num (Int.ofNat newIdx)),
                                                ("onChainOwnerVerified", .bool true),
                                                ("rewrappedMaster", .bool newMasterWrap?.isSome) ]
      | _, _, _ => pure (.error invalidParams)
  | "sphincs.account.resyncOwner" =>
      -- Idempotent owner reconciliation. Reads on-chain `owner()` and
      -- compares to the slot's local `rec.ownerAddress`. If they differ
      -- AND the on-chain owner is one of our local EOA accounts AND
      -- master KEK is loaded, rewraps the SPHINCS sk under the new AAD
      -- and writes the updated slot atomically. Otherwise no-op with a
      -- descriptive status code.
      --
      -- Replaces the brittle TUI-side auto-commit (which only fired when
      -- the user happened to be on the poll-run screen at the moment
      -- the bundler reported inclusion). The TUI now calls this on
      -- every detail-panel entry — if a rotation lands while the user
      -- is anywhere else in the app, the next visit picks it up.
      --
      -- customPassphrase slots return `drift-master-locked` because we
      -- can't open them without the per-slot passphrase; those users
      -- have to call `sphincs.account.commitRotation` manually.
      match paramName req.params with
      | .error e => pure (.error e)
      | .ok name =>
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error e =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none =>
                  pure <| .ok <| .obj #[
                    ("name", .str name),
                    ("status", .str "no-smart-account-address") ]
              | some sender =>
                  let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
                  match endpointForChain cfg (some chainName) with
                  | .error e =>
                      pure <| .error { code := -32021, message := "unknown chain", data := some (.str e) }
                  | .ok ep =>
                      -- owner() selector = keccak256("owner()")[:4] = 0x8da5cb5b
                      match ← LeanKohaku.RPC.Outbound.call cfg.policy ep
                          .call (.arr #[.obj #[("to", .str sender), ("data", .str "0x8da5cb5b")], .str "latest"]) none with
                      | .error e =>
                          pure <| .error { code := -32020, message := "owner() call failed", data := some (.str e) }
                      | .ok r =>
                          let onChainHex := (asString r).getD "0x"
                          let stripped := if onChainHex.startsWith "0x" then onChainHex.drop 2 else onChainHex.toSlice
                          let raw := stripped.toString.toLower
                          let onChainOwner :=
                            if raw.length >= 40 then "0x" ++ (raw.drop (raw.length - 40)) else ""
                          if onChainOwner = "" then
                            pure <| .ok <| .obj #[
                              ("name", .str name),
                              ("status", .str "owner-call-empty") ]
                          else if onChainOwner = rec.ownerAddress.toLower then
                            pure <| .ok <| .obj #[
                              ("name", .str name),
                              ("status", .str "in-sync"),
                              ("owner", .str rec.ownerAddress) ]
                          else
                            -- Drift detected. Look up the on-chain owner in our local EOA slots.
                            let target := onChainOwner
                            let names ← LeanKohaku.Wallet.EoaStore.list
                            let rec scanForOwner : List String → IO (Option (String × Nat))
                              | [] => pure none
                              | n :: rest => do
                                  match ← LeanKohaku.Wallet.EoaStore.load n with
                                  | .error _ => scanForOwner rest
                                  | .ok wr =>
                                      let accts := recordAccounts wr
                                      match accts.find? (fun a => a.address.toLower = target) with
                                      | some a => pure (some (n, a.index))
                                      | none => scanForOwner rest
                            match ← scanForOwner names with
                            | none =>
                                pure <| .ok <| .obj #[
                                  ("name", .str name),
                                  ("status", .str "drift-no-local-key"),
                                  ("onChainOwner", .str onChainOwner),
                                  ("localOwner", .str rec.ownerAddress) ]
                            | some (walletName, idx) =>
                                -- We have a local key for the new on-chain owner. Try to rewrap.
                                let masterSlot? ← LeanKohaku.Daemon.State.getMasterKek? state
                                match masterSlot? with
                                | none =>
                                    pure <| .ok <| .obj #[
                                      ("name", .str name),
                                      ("status", .str "drift-master-locked"),
                                      ("onChainOwner", .str onChainOwner),
                                      ("newWalletName", .str walletName),
                                      ("newAccountIndex", .num (Int.ofNat idx)),
                                      ("hint", .str "unlock master keystore and retry, or call sphincs.account.commitRotation with passphrase") ]
                                | some mslot =>
                                    match ← LeanKohaku.Wallet.SphincsHybridStore.openWithMaster mslot.kek rec with
                                    | .error err =>
                                        pure <| .ok <| .obj #[
                                          ("name", .str name),
                                          ("status", .str "drift-unwrap-failed"),
                                          ("onChainOwner", .str onChainOwner),
                                          ("error", .str err) ]
                                    | .ok skHex =>
                                        let newPpBytes ← LeanKohaku.Crypto.Random.getRandomBytes 32
                                        let newPp := LeanKohaku.Crypto.Hex.encode newPpBytes
                                        let newKdfSalt ← LeanKohaku.Crypto.Random.getRandomBytes 16
                                        let newIters := LeanKohaku.Wallet.SphincsHybridStore.defaultKdfIters
                                        match ← LeanKohaku.Wallet.SphincsHybridStore.sealSk
                                            rec.name rec.paramSet onChainOwner newPp skHex
                                            newKdfSalt newIters with
                                        | .error err =>
                                            pure <| .error { code := -32041, message := "sphincs sk re-seal failed", data := some (.str err) }
                                        | .ok newPpCt =>
                                            match ← LeanKohaku.Wallet.SphincsHybridStore.sealUnderMaster
                                                mslot.kek rec.name rec.paramSet onChainOwner skHex with
                                            | .error err =>
                                                pure <| .error { code := -32041, message := "master re-seal failed", data := some (.str err) }
                                            | .ok newMasterWrap =>
                                                let updated : LeanKohaku.Wallet.SphincsHybridStore.Record :=
                                                  { rec with
                                                      ownerAddress := onChainOwner,
                                                      ecdsaAttachment :=
                                                        LeanKohaku.Wallet.Account.EcdsaAttachment.existing walletName idx,
                                                      kdfSalt := newKdfSalt,
                                                      kdfIters := newIters,
                                                      passphraseCiphertext := newPpCt,
                                                      masterWrap := some newMasterWrap }
                                                LeanKohaku.Wallet.SphincsHybridStore.writeRecord updated
                                                pure <| .ok <| .obj #[
                                                  ("name", .str name),
                                                  ("status", .str "resynced"),
                                                  ("newOwner", .str onChainOwner),
                                                  ("newWalletName", .str walletName),
                                                  ("newAccountIndex", .num (Int.ofNat idx)) ]
  | "sphincs.account.deployStatus" =>
      -- Probe eth_getCode at the slot's smart-account address. Empty
      -- bytecode → not deployed (factory.createAccount hasn't run, or
      -- first-send-also-deploy initCode hasn't been bundled yet). Used
      -- by the TUI to gate the "Deploy" action once the account is
      -- already on chain.
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
          | .error err =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str err) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none =>
                  -- No counterfactual computed yet → certainly not deployed.
                  pure <| .ok <| .obj #[
                    ("name",                .str name),
                    ("smartAccountAddress", .null),
                    ("deployed",            .bool false),
                    ("codeLen",             .num 0)
                  ]
              | some sender =>
                  let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
                  match endpointForChain cfg (some chainName) with
                  | .error e => pure <| .error { code := -32021, message := "unknown chain", data := some (.str e) }
                  | .ok ep =>
                      match ← LeanKohaku.RPC.Outbound.call cfg.policy ep
                          .getCode (.arr #[.str sender, .str "latest"]) none with
                      | .error e => pure <| .error { code := -32020, message := "eth_getCode failed", data := some (.str e) }
                      | .ok r =>
                          let codeHex := (asString r).getD "0x"
                          let stripped := if codeHex.startsWith "0x" then (codeHex.drop 2).toString else codeHex
                          let codeLen := stripped.length / 2
                          pure <| .ok <| .obj #[
                            ("name",                .str name),
                            ("smartAccountAddress", .str sender),
                            ("deployed",            .bool (codeLen > 0)),
                            ("codeLen",             .num (Int.ofNat codeLen))
                          ]
  | "sphincs.factory.deploy" =>
      -- Sepolia-only one-shot factory deploy via the bundled shell.
      -- Params:
      --   paramSet           : "SLH-DSA-SHA2-128-24" | "JARDIN-Keccak-128-24" | "C9"
      --   chain              : must be "sepolia" (mainnet refused — no factory
      --                        has been deployed yet at the time of writing)
      --   deployerWallet     : EOA slot to fund the deploy
      --   deployerPassphrase : (optional if master KEK loaded) passphrase
      --   deployerAccountIndex : optional (default 0)
      match paramString req.params "paramSet",
            paramString req.params "deployerWallet" with
      | .ok psStr, .ok deployer =>
          let chain := paramStringD req.params "chain" "sepolia"
          if chain ≠ "sepolia" then
            pure <| .error
              { code := -32036,
                message := "sphincs factory deploy is Sepolia-only (no mainnet factory yet)",
                data := some (.str s!"got chain={chain}") }
          else match LeanKohaku.Sphincs.ParamSet.parse? psStr with
          | none =>
              pure <| .error { invalidParams with data := some (.str s!"unknown paramSet: {psStr}") }
          | some ps =>
              match sphincsVerifierFor cfg chain ps with
              | .error e =>
                  pure <| .error { code := -32030, message := "verifier unavailable", data := some (.str e) }
              | .ok verifierAddr =>
                  match ← LeanKohaku.Wallet.EoaStore.load deployer with
                  | .error e => pure <| .error { code := -32010, message := "deployer wallet not found", data := some (.str e) }
                  | .ok dRec =>
                      let idx := paramNatD req.params "deployerAccountIndex" 0
                      match dRec.accounts.find? (fun a => a.index == idx) with
                      | none => pure <| .error { code := -32011, message := s!"deployer has no account #{idx}", data := none }
                      | some dAcct =>
                          let seedExc : IO (Except String ByteArray) := do
                            -- Prefer master KEK (slot may have lazy-enrolled);
                            -- fall back to the explicit `deployerPassphrase`.
                            match ← LeanKohaku.Daemon.State.getMasterKek? state with
                            | some mslot =>
                                match ← LeanKohaku.Keystore.MasterPassphrase.unwrapSlot
                                    mslot.kek dRec.name dRec.derivationPath dRec.address
                                    (dRec.masterWrap.getD ByteArray.empty) with
                                | .ok seed => pure (.ok seed)
                                | .error _ =>
                                    match paramString req.params "deployerPassphrase" with
                                    | .error _ => pure (.error "deployerPassphrase required (master path failed)")
                                    | .ok pp =>
                                        match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO dRec pp with
                                        | .ok seed => pure (.ok seed)
                                        | .error e => pure (.error e)
                            | none =>
                                match paramString req.params "deployerPassphrase" with
                                | .error _ => pure (.error "deployerPassphrase required (master KEK not loaded)")
                                | .ok pp =>
                                    match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO dRec pp with
                                    | .ok seed => pure (.ok seed)
                                    | .error e => pure (.error e)
                          match ← seedExc with
                          | .error e => pure <| .error { code := -32011, message := "deployer unlock failed", data := some (.str e) }
                          | .ok seed =>
                              match ← derivePrivateKeyFromSeed seed dAcct.path with
                              | .error e => pure <| .error { code := -32012, message := "deployer key derive failed", data := some (.str e) }
                              | .ok pk =>
                                  -- Hex.encode is `0x`-prefixed; forge expects no extra prefix.
                                  let pkHex := LeanKohaku.Crypto.Hex.encode pk
                                  try
                                    let out ← IO.Process.output {
                                      cmd := "./script/sphincs_sepolia.sh",
                                      args := #["deploy", ps.toString],
                                      env := #[
                                        ("SPHINCS_VERIFIER_ADDR", some verifierAddr),
                                        ("SEPOLIA_DEPLOYER_PRIVATE_KEY", some pkHex),
                                        ("PRIVATE_KEY", some pkHex)
                                      ]
                                    }
                                    -- Best-effort: grep the address out of stdout.
                                    let stdout := out.stdout
                                    let lines := stdout.splitOn "\n"
                                    let factory? : Option String := lines.findSome? fun l =>
                                      let t := l.trimAscii.toString
                                      if t.startsWith "Deployed to:" then
                                        some (((t.drop 12).trimAscii).toString)
                                      else none
                                    pure <| .ok <| .obj #[
                                      ("paramSet", .str ps.toString),
                                      ("chain", .str chain),
                                      ("verifier", .str verifierAddr),
                                      ("factory", match factory? with | some a => .str a | none => .null),
                                      ("exitCode", .num (Int.ofNat out.exitCode.toNat)),
                                      ("stdout", .str stdout),
                                      ("stderr", .str out.stderr)
                                    ]
                                  catch e =>
                                    pure <| .error { code := -32037, message := "deploy script failed to spawn", data := some (.str e.toString) }
      | _, _ => pure (.error invalidParams)
  | "sphincs.bundler.check" =>
      -- Cheap pre-flight: call `eth_supportedEntryPoints` against the
      -- configured bundler and report whether the v0.9 EntryPoint
      -- singleton appears. Useful for catching a bundler that only
      -- speaks v0.6/v0.7 before any signing happens. Does not gate the
      -- send pipeline — different bundlers respond inconsistently (some
      -- return empty arrays) so we leave the policy decision to the
      -- caller, just surface the raw signal.
      let chainName := paramStringD req.params "chain" (chainNameGuess cfg.chainId)
      match sphincsBundlerFor cfg chainName with
      | .error e => pure <| .error { code := -32030, message := "sphincs bundler unavailable", data := some (.str e) }
      | .ok bundlerUrl =>
          match ← Sphincs.Send.bundlerCall bundlerUrl "eth_supportedEntryPoints" (.arr #[]) with
          | .error e => pure <| .error { code := -32021, message := "bundler error", data := some (.str e) }
          | .ok r =>
              let lowered (s : String) : String := s.toLower
              let v09 : String := lowered Sphincs.Send.entryPointV09Address
              let supports : Bool :=
                match r with
                | .arr xs => xs.any (fun j =>
                    match asString j with
                    | some s => lowered s = v09
                    | none => false)
                | _ => false
              pure <| .ok <| .obj #[
                ("bundler", .str bundlerUrl),
                ("v09EntryPoint", .str Sphincs.Send.entryPointV09Address),
                ("supported", .bool supports),
                ("raw", r)
              ]
  | "sphincs.account.getUserOp" =>
      -- Read-through to the bundler's `eth_getUserOperationReceipt`,
      -- which is the spec-authoritative "is this userOp mined" query
      -- (returns null until included, then a receipt with
      -- transactionHash + success). We also try
      -- `eth_getUserOperationByHash` as a side-channel; some bundlers
      -- (notably Candide) return the userOp+blockHash from that method
      -- even before the receipt is fully populated. Either non-null
      -- result is surfaced to the TUI as "included".
      match paramString req.params "userOpHash" with
      | .error e => pure (.error e)
      | .ok userOpHash =>
          -- Chain resolution priority:
          --   1. explicit `chain` param from the caller (TUI)
          --   2. the slot's stored chainId (when `name` is supplied)
          --   3. the daemon's default cfg.chainId
          -- (3) is the wrong default for sphincs slots because the
          -- daemon may default to mainnet while every sphincs slot
          -- right now lives on Sepolia — surfacing as
          -- "no sphincs bundler configured for chain 'mainnet'".
          let slotChain? : IO (Option String) := do
            match paramName req.params with
            | .error _ => pure none
            | .ok slotName =>
                match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord slotName with
                | .ok rec => pure (some (chainNameGuess rec.chainId))
                | .error _ => pure none
          let chainName ← do
            match paramString req.params "chain" with
            | .ok c => pure c
            | .error _ =>
                match ← slotChain? with
                | some c => pure c
                | none => pure (chainNameGuess cfg.chainId)
          match sphincsBundlerFor cfg chainName with
          | .error e =>
              pure <| .error { code := -32030, message := "sphincs bundler unavailable", data := some (.str e) }
          | .ok bundlerUrl =>
              -- Primary query: receipt (authoritative).
              let receiptR ← Sphincs.Send.bundlerCall bundlerUrl
                  "eth_getUserOperationReceipt" (.arr #[.str userOpHash])
              -- Secondary query: byHash. Some bundlers populate this
              -- before the receipt; useful for fast-path inclusion.
              let byHashR ← Sphincs.Send.bundlerCall bundlerUrl
                  "eth_getUserOperationByHash" (.arr #[.str userOpHash])
              let receipt : Json := match receiptR with
                | .ok r => r
                | .error _ => .null
              let byHash : Json := match byHashR with
                | .ok r => r
                | .error _ => .null
              let isNull (j : Json) : Bool := match j with | .null => true | _ => false
              let included := ! (isNull receipt && isNull byHash)
              -- Bubble bundler error only if BOTH queries failed AND
              -- neither returned a parseable null.
              match receiptR, byHashR with
              | .error e1, .error e2 =>
                  pure <| .error { code := -32021, message := "bundler error",
                                   data := some (.str s!"receipt: {e1}; byHash: {e2}") }
              | _, _ =>
                  -- If included AND the caller passed a slot name, persist
                  -- the userOpHash → L1 txHash mapping to the journal so
                  -- the next `chain.history` call surfaces the L1 hash in
                  -- the UI. Idempotent: writing the same inclusion twice
                  -- is harmless (overlay logic just picks the latest).
                  let inclusionTxHash? : Option String :=
                    (getField "receipt" receipt >>= getField "transactionHash" |>.bind asString)
                    <|> (getField "transactionHash" byHash >>= asString)
                  let blockNumber? : Option String :=
                    (getField "receipt" receipt >>= getField "blockNumber" |>.bind asString)
                    <|> (getField "blockNumber" byHash >>= asString)
                  let success? : Option Bool := match getField "success" receipt with
                    | some (.bool b) => some b
                    | _ => none
                  match paramString req.params "name", inclusionTxHash? with
                  | .ok slotName, some itx =>
                      LeanKohaku.Daemon.TxJournal.appendInclusion
                        slotName userOpHash itx blockNumber? success?
                  | _, _ => pure ()
                  pure <| .ok <| .obj #[
                    ("userOpHash", .str userOpHash),
                    ("included", .bool included),
                    ("receipt", receipt),
                    ("info", byHash) ]
  | "eoa.revealMnemonic" =>
      -- Why: passphrase-gated recovery of the BIP-39 words for slots
      -- created with mnemonic retention. Slots that predate the on-disk
      -- format change (`mnemonicWrap` absent) return -32030 with a
      -- pointer to the underlying constraint (BIP-39 seed → words is
      -- one-way). The plaintext is returned exactly once per call; we do
      -- not journal, log, or notify.
      match paramName req.params, paramString req.params "passphrase" with
      | .ok name, .ok passphrase =>
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .error err =>
              pure <| .error
                { code := -32010,
                  message := "EOA slot not found",
                  data := some (.str err) }
          | .ok record =>
              match ← LeanKohaku.Wallet.EoaStore.unwrapMnemonic record passphrase with
              | .error err =>
                  -- Distinguish "no stored mnemonic" from "wrong passphrase"
                  -- via prefix-match on the EoaStore error message — both
                  -- are surfaced with -32030 but with different data so the
                  -- TUI/CLI can render an appropriate message.
                  pure <| .error
                    { code := -32030,
                      message := "could not reveal mnemonic",
                      data := some (.str err) }
              | .ok phrase =>
                  let words := (phrase.splitOn " ").filter (· ≠ "")
                  let arr : Array Json := words.foldl
                    (fun acc w => acc.push (.str w)) (#[] : Array Json)
                  pure <| .ok <| .obj #[
                    ("name", .str name),
                    ("address", .str record.address),
                    ("derivationPath", .str record.derivationPath),
                    ("wordCount", .num (Int.ofNat words.length)),
                    ("mnemonic", .arr arr)
                  ]
      | _, _ => pure (.error invalidParams)
  | "eoa.unlock" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match ← LeanKohaku.Wallet.EoaStore.load name with
              | .error err =>
                  pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
              | .ok record =>
                  -- Master-KEK fast path: when the caller passes an empty
                  -- passphrase, the slot is enrolled under master (has a
                  -- `masterWrap` and is not `customPassphrase`), and the
                  -- master KEK is currently loaded, unwrap via master
                  -- instead of running the per-slot KDF. This lets the TUI
                  -- skip the passphrase prompt entirely for master-enrolled
                  -- slots without leaking which slots are enrolled (the
                  -- gating check happens entirely server-side; an empty
                  -- passphrase on a non-enrolled slot falls through to the
                  -- regular KDF path below, which fails with the usual
                  -- -32011). Additive: callers that supply a real
                  -- passphrase keep the prior behaviour byte-for-byte.
                  let masterFastPath? ← do
                    if passphrase.length == 0 && !record.customPassphrase then
                      match record.masterWrap with
                      | none => pure none
                      | some w =>
                          match ← LeanKohaku.Daemon.State.getMasterKek? state with
                          | none => pure none
                          | some slot =>
                              match ← LeanKohaku.Keystore.MasterPassphrase.unwrapSlot
                                  slot.kek record.name record.derivationPath record.address w with
                              | .error _ => pure none
                              | .ok seed => pure (some seed)
                    else pure none
                  match masterFastPath? with
                  | some seed =>
                      LeanKohaku.Daemon.State.unlock state {
                        name := record.name,
                        seed := seed,
                        address := record.address,
                        derivationPath := record.derivationPath,
                        unlockedAtMs := ← IO.monoMsNow,
                        ttlMs := 300000
                      }
                      pure (.ok (← slotMetadataJson state record))
                  | none =>
                  match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
                  | .error err =>
                      pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                  | .ok seed =>
                      LeanKohaku.Daemon.State.unlock state {
                        name := record.name,
                        seed := seed,
                        address := record.address,
                        derivationPath := record.derivationPath,
                        unlockedAtMs := ← IO.monoMsNow,
                        ttlMs := 300000
                      }
                      -- Lazy enrolment / self-heal: whenever the wallet
                      -- master is currently loaded and this slot is not
                      -- opted out, rewrap the seed under the current KEK.
                      -- Idempotent — covers three cases in one pass:
                      --   (a) first enrolment (`masterWrap.isNone`),
                      --   (b) stale wrap from a rotated/re-init'd master
                      --       (still `some _`, but ciphertext opens under
                      --       a KEK we no longer hold — surfaces as
                      --       `stale-wrap` from `wallet.unlock`),
                      --   (c) routine re-unlock under the same KEK
                      --       (semantically a no-op, costs one AEAD seal
                      --       + write — negligible).
                      -- Best-effort: rewrap errors are swallowed so the
                      -- per-slot unlock still succeeds.
                      if !record.customPassphrase then
                        match ← LeanKohaku.Daemon.State.getMasterKek? state with
                        | none => pure ()
                        | some slot =>
                            match ← LeanKohaku.Keystore.MasterPassphrase.wrapSlot
                                slot.kek record.name record.derivationPath record.address seed with
                            | .error _ => pure ()
                            | .ok wrap =>
                                let updated := { record with masterWrap := some wrap }
                                try LeanKohaku.Wallet.EoaStore.save updated
                                catch _ => pure ()
                      pure (.ok (← slotMetadataJson state record))
  | "eoa.lock" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          LeanKohaku.Daemon.State.lock state name
          pure (.ok (.obj #[("ok", .bool true)]))
  | "eoa.derive" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              let path := paramStringD req.params "path" slot.derivationPath
              match ← deriveAddressFromSeed slot.seed path with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok address =>
                  pure <| .ok <| .obj #[
                    ("name", .str name),
                    ("path", .str path),
                    ("address", .str address)
                  ]
  | "eoa.signDigest" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "digest" req.params >>= asBytes with
              | none => pure (.error invalidParams)
              | some digest =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanKohaku.Wallet.EOA.signDigestIO privateKey digest with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok sig => pure (.ok (signatureJson sig))
  | "eoa.signMessage" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "message" req.params >>= asBytes with
              | none => pure (.error invalidParams)
              | some msg =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanKohaku.Wallet.EOA.signPersonalMessageIO msg privateKey with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok sig => pure (.ok (signatureJson sig))
  | "eoa.signTx" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match paramTx req.params with
              | .error err => pure (.error err)
              | .ok tx =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanKohaku.Wallet.EOA.signEip1559IO tx privateKey with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok signed =>
                          pure <| .ok <| .obj #[
                            ("raw", .str (LeanKohaku.Crypto.Hex.encode signed.encode)),
                            ("signature", signatureJson signed.sig)
                          ]
  | "eoa.signTypedData" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "typedData" req.params with
              | none => pure (.error invalidParams)
              | some typedData =>
                  match ← LeanKohaku.Ethereum.Eip712.computeDigestIO typedData with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok d =>
                      match ← resolveSigningTarget name slot req.params with
                      | .error err => pure (.error err)
                      | .ok (path, addr) =>
                      match ← derivePrivateKeyFromSeed slot.seed path with
                      | .error err =>
                          pure <| .error { invalidParams with data := some (.str err) }
                      | .ok privateKey =>
                          match ← LeanKohaku.Wallet.EOA.signDigestIO privateKey d.digest with
                          | .error err =>
                              pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                          | .ok sig =>
                              -- Why: pack r||s||v into a 65-byte 0x... compact signature
                              let r := LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 sig.r
                              let s := LeanKohaku.Wallet.HDKey.Nat.toFixedBytes 32 sig.s
                              let v := ByteArray.empty.push sig.v
                              let compactSig := r ++ s ++ v
                              pure <| .ok <| .obj #[
                                ("signature", .str (LeanKohaku.Crypto.Hex.encode compactSig)),
                                ("digest", .str (LeanKohaku.Crypto.Hex.encode d.digest)),
                                ("domainSeparator", .str (LeanKohaku.Crypto.Hex.encode d.domainSeparator)),
                                ("messageHash", .str (LeanKohaku.Crypto.Hex.encode d.messageHash)),
                                ("primaryType", .str d.primaryType),
                                ("recoveredAddress", .str addr),
                                ("rsv", signatureJson sig)
                              ]
  | "eoa.send" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match paramString req.params "to", paramNat req.params "value" with
              | .ok to, .ok value =>
                  match LeanKohaku.Ethereum.Address.fromHex to with
                  | none => pure (.error invalidParams)
                  | some toAddress =>
                      match txBytesFieldD req.params "data" with
                      | .error err => pure (.error err)
                      | .ok data =>
                          match ← resolveSigningTarget name slot req.params with
                          | .error err => pure (.error err)
                          | .ok (path, fromAddr) =>
                          match ← derivePrivateKeyFromSeed slot.seed path with
                          | .error err =>
                              pure <| .error { invalidParams with data := some (.str err) }
                          | .ok privateKey =>
                              -- Why: re-target slot at the resolved account so nonce/from come from the right address.
                              let slot' := { slot with address := fromAddr, derivationPath := path }
                              -- Per-call chain override. Honors `params.chain`
                              -- when present: pick the per-chain endpoint
                              -- from cfg.chainEndpoints + the corresponding
                              -- chainId so the broadcast goes to the right
                              -- network. Without this, the chat path's
                              -- chainId=11155111 prompt broadcasted on the
                              -- daemon's default chain (mainnet) and tripped
                              -- the mainnet policy.
                              let chainName? := getField "chain" req.params >>= asString
                              let cfgEff : Config :=
                                match chainName? with
                                | none => cfg
                                | some name =>
                                    match endpointForChain cfg (some name) with
                                    | .error _ => cfg
                                    | .ok ep =>
                                        let cid := (LeanKohaku.RPC.Outbound.chainNameToId name).getD cfg.chainId
                                        { cfg with rpcEndpoint := ep, chainId := cid }
                              let via? ← colibriVia state cfgEff.chainId
                              let r ← buildSignBroadcastTx cfgEff slot' privateKey to toAddress value data none (some notify) via?
                              -- Why: best-effort journal write; never fails the tx.
                              match r with
                              | .ok j =>
                                  let getStr (k : String) : String :=
                                    (getField k j >>= asString).getD ""
                                  let txHash := getStr "txHash"
                                  let nonceN := (parseHexQuantity (getStr "nonce")).getD 0
                                  let dataHex := LeanKohaku.Crypto.Hex.encode data
                                  let acc? := getField "account" req.params >>= asNat
                                  let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                                  let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                                  let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                                  if !txHash.isEmpty then
                                    journalRecord slot.name fromAddr to txHash dataHex "eoa.send"
                                      value nonceN cfgEff.chainId acc? status? block? gas?
                              | .error _ => pure ()
                              pure r
              | _, _ => pure (.error invalidParams)
  | "eoa.dropNonce" =>
      -- Replace a stuck pending nonce with a 0-value self-transfer at a
      -- forced priority tip. Frees the mempool slot so downstream nonces
      -- can land. Params:
      --   name            : EOA slot
      --   nonce           : the exact nonce to drop (no auto-pick — caller
      --                     must read it from `eth_getTransactionCount` first)
      --   account         : optional sub-account index (defaults to primary)
      --   priorityFeeGwei : optional tip in gwei (default 3 — enough to
      --                     outbid the typical Sepolia `eth_maxPriorityFeePerGas`
      --                     report of 0x15f900 ≈ 0.00144 gwei)
      --   chain           : optional chain override; honors `cfg.chainEndpoints`
      match paramName req.params, paramNat req.params "nonce" with
      | .ok name, .ok nonce =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match ← resolveSigningTarget name slot req.params with
              | .error err => pure (.error err)
              | .ok (path, fromAddr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      let slot' := { slot with address := fromAddr, derivationPath := path }
                      let chainName? := getField "chain" req.params >>= asString
                      let cfgEff : Config :=
                        match chainName? with
                        | none => cfg
                        | some name =>
                            match endpointForChain cfg (some name) with
                            | .error _ => cfg
                            | .ok ep =>
                                let cid := (LeanKohaku.RPC.Outbound.chainNameToId name).getD cfg.chainId
                                { cfg with rpcEndpoint := ep, chainId := cid }
                      let tipGwei := paramNatD req.params "priorityFeeGwei" 3
                      let tipWei := tipGwei * 1_000_000_000
                      match LeanKohaku.Ethereum.Address.fromHex fromAddr with
                      | none => pure (.error invalidParams)
                      | some selfAddr =>
                          let via? ← colibriVia state cfgEff.chainId
                          let r ← buildSignBroadcastTx cfgEff slot' privateKey fromAddr selfAddr 0
                            ByteArray.empty (some nonce) (some notify) via? (some tipWei)
                          match r with
                          | .ok j =>
                              let getStr (k : String) : String :=
                                (getField k j >>= asString).getD ""
                              let txHash := getStr "txHash"
                              let acc? := getField "account" req.params >>= asNat
                              let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                              let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                              let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                              if !txHash.isEmpty then
                                journalRecord slot.name fromAddr fromAddr txHash "" "eoa.dropNonce"
                                  0 nonce cfgEff.chainId acc? status? block? gas?
                          | .error _ => pure ()
                          pure r
      | _, _ => pure (.error invalidParams)
  | "eoa.delete" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match ← LeanKohaku.Wallet.EoaStore.load name with
              | .error err =>
                  pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
              | .ok record =>
                  match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
                  | .error err =>
                      pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                  | .ok _ =>
                      LeanKohaku.Daemon.State.lock state name
                      LeanKohaku.Wallet.EoaStore.delete name
                      pure (.ok (.obj #[("ok", .bool true)]))
  | "eoa.account.list" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← loadRecord name with
          | .error err => pure (.error err)
          | .ok record =>
              let arr := (recordAccounts record).map accountToJson
              pure <| .ok <| .obj #[("accounts", .arr arr)]
  | "eoa.account.findByAddress" =>
      -- Scan every EOA slot's `accounts[]` looking for one whose
      -- `.address` matches the queried address (case-insensitive). When
      -- found, return `{ found: true, walletName, accountIndex,
      -- derivationPath }` — enough info for the sphincs commitRotation
      -- flow to point a slot at the new key without asking the user to
      -- remember which wallet they picked. Returns `{ found: false }`
      -- when the address isn't derivable from any local seed (e.g. a
      -- bare external key the user pasted).
      match paramString req.params "address" with
      | .error e => pure (.error e)
      | .ok rawAddr =>
          let target := rawAddr.toLower
          let names ← LeanKohaku.Wallet.EoaStore.list
          let rec scan : List String → IO (Option (String × Nat × String))
            | [] => pure none
            | n :: rest => do
                match ← LeanKohaku.Wallet.EoaStore.load n with
                | .error _ => scan rest
                | .ok r =>
                    let accts := recordAccounts r
                    match accts.find? (fun a => a.address.toLower = target) with
                    | some a => pure (some (n, a.index, a.path))
                    | none => scan rest
          match ← scan names with
          | none =>
              pure <| .ok <| .obj #[("found", .bool false), ("address", .str rawAddr)]
          | some (walletName, idx, path) =>
              pure <| .ok <| .obj #[
                ("found", .bool true),
                ("address", .str rawAddr),
                ("walletName", .str walletName),
                ("accountIndex", .num (Int.ofNat idx)),
                ("derivationPath", .str path) ]
  | "eoa.account.add" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match ← loadRecord name with
              | .error err => pure (.error err)
              | .ok record =>
                  let existing := recordAccounts record
                  let idx := nextAccountIndex record
                  -- Why: caller may pass an explicit BIP-44 path; otherwise auto-pick m/44'/60'/0'/0/<idx>.
                  let pathE : Except String String :=
                    match getField "path" req.params >>= asString with
                    | some p => .ok p
                    | none => LeanKohaku.Wallet.Bip44.canonicalEthereumPath 0 0 idx
                  match pathE with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok path =>
                      -- Reject duplicate path (would create two accounts at the same address).
                      if existing.any (fun a => a.path = path) then
                        pure <| .error { code := -32015, message := "account path already exists",
                                         data := some (.str s!"path {path} already present") }
                      else
                        match ← deriveAddressFromSeed slot.seed path with
                        | .error err =>
                            pure <| .error { invalidParams with data := some (.str err) }
                        | .ok address =>
                            let label : Option String := getField "label" req.params >>= asString
                            let newAcc : LeanKohaku.Wallet.EoaStore.Account :=
                              { index := idx, path := path, address := address, label := label }
                            let updated : LeanKohaku.Wallet.EoaStore.Record :=
                              { record with accounts := existing.push newAcc }
                            LeanKohaku.Wallet.EoaStore.save updated
                            pure <| .ok (accountToJson newAcc)
  | "eoa.account.rm" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match paramNat req.params "index" with
              | .error err => pure (.error err)
              | .ok idx =>
                  if idx = 0 then
                    pure <| .error { code := -32016,
                                     message := "cannot remove account index 0 (primary)",
                                     data := none }
                  else
                    match ← loadRecord name with
                    | .error err => pure (.error err)
                    | .ok record =>
                        match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
                        | .error err =>
                            pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                        | .ok _ =>
                            let existing := recordAccounts record
                            match existing.find? (fun a => a.index = idx) with
                            | none =>
                                pure <| .error { code := -32014,
                                                 message := s!"account index {idx} not found in slot",
                                                 data := none }
                            | some removed =>
                                let kept := existing.filter (fun a => a.index != idx)
                                let updated : LeanKohaku.Wallet.EoaStore.Record :=
                                  { record with accounts := kept }
                                LeanKohaku.Wallet.EoaStore.save updated
                                pure <| .ok <| .obj #[
                                  ("ok", .bool true),
                                  ("removed", accountToJson removed)
                                ]
  | "shielded.ping" =>
      let resp ← LeanKohaku.Privacy.Bridge.ping
      pure <| .ok <| LeanKohaku.Privacy.Bridge.responseToJson resp
  | "clearsign.ping" =>
      let resp ← LeanKohaku.Clearsign.Bridge.call
        { method := "ping", params := .obj #[], id := 0 }
      pure <| .ok <| LeanKohaku.Clearsign.Bridge.responseToJson resp
  | "llm.ping" =>
      let resp ← LeanKohaku.LlmAgent.Bridge.call
        { method := "ping", params := .obj #[], id := 0 }
      pure <| .ok <| LeanKohaku.LlmAgent.Bridge.responseToJson resp
  | "book.list" =>
      match ← LeanKohaku.Daemon.AddressBook.loadIO with
      | .error e => pure <| .error { code := -32020, message := e, data := none }
      | .ok entries =>
          let arr : Array Json := (entries.map (fun e =>
            .obj <| #[
              ("label",   .str e.label),
              ("address", .str e.address),
              ("source",  .str e.source),
              ("addedAt", .num (Int.ofNat e.addedAt))
            ]
            ++ (match e.ensName with | some n => #[("ensName", .str n)] | none => #[])
            ++ (match e.tag     with | some t => #[("tag",     .str t)] | none => #[])
          )).toArray
          pure <| .ok <| .obj #[("entries", .arr arr)]
  | "book.add" =>
      -- params: { label, address, source?, ensName?, tag? }. If address
      -- ends in .eth, daemon resolves it first via the same path
      -- chain.resolveName uses, and stores the resolved 0x address with
      -- ensName populated and source="ens".
      match paramString req.params "label",
            paramString req.params "address" with
      | .ok label, .ok addrOrEns =>
          let isEns := addrOrEns.endsWith ".eth"
          let now ← IO.monoMsNow
          let buildAndSave (resolvedAddr : String) (src : String) (ens? : Option String) : IO (Except String Unit) := do
            match ← LeanKohaku.Daemon.AddressBook.addIO {
              label := label,
              address := resolvedAddr,
              source := src,
              ensName := ens?,
              tag := getField "tag" req.params >>= asString,
              addedAt := now / 1000
            } with
            | .ok _ => pure (.ok ())
            | .error e => pure (.error e)
          if isEns then
            match cfg.ensRpcEndpoint with
            | none =>
                pure <| .error { code := -32030, message := "no ENS RPC configured; cannot resolve before adding", data := none }
            | some ensEp =>
                let viaEns? ← colibriVia state 1
                match ← LeanKohaku.Ethereum.Ens.resolveIO cfg.policy ensEp 1 addrOrEns viaEns? with
                | .error (code, msg) =>
                    pure <| .error { code := code, message := msg, data := none }
                | .ok r =>
                    match ← buildAndSave r.address "ens" (some addrOrEns) with
                    | .ok () =>
                        pure <| .ok <| .obj #[
                          ("ok", .bool true),
                          ("label", .str label),
                          ("address", .str r.address),
                          ("source", .str "ens"),
                          ("ensName", .str addrOrEns)
                        ]
                    | .error e => pure <| .error { code := -32603, message := e, data := none }
          else
            let src := (paramString req.params "source").toOption.getD "manual"
            match ← buildAndSave addrOrEns src none with
            | .ok () =>
                pure <| .ok <| .obj #[
                  ("ok", .bool true),
                  ("label", .str label),
                  ("address", .str addrOrEns),
                  ("source", .str src)
                ]
            | .error e => pure <| .error { code := -32603, message := e, data := none }
      | .error err, _ => pure (.error err)
      | _, .error err => pure (.error err)
  | "book.remove" =>
      match paramString req.params "label" with
      | .error err => pure (.error err)
      | .ok label =>
          match ← LeanKohaku.Daemon.AddressBook.removeIO label with
          | .error e => pure <| .error { code := -32603, message := e, data := none }
          | .ok (removed, _) =>
              pure <| .ok <| .obj #[("removed", .bool removed)]
  | "book.lookup" =>
      match paramString req.params "needle" with
      | .error err => pure (.error err)
      | .ok needle =>
          match ← LeanKohaku.Daemon.AddressBook.lookupIO needle with
          | .error e => pure <| .error { code := -32603, message := e, data := none }
          | .ok none => pure <| .ok <| .obj #[("entry", .null)]
          | .ok (some e) =>
              pure <| .ok <| .obj #[
                ("entry", .obj <| #[
                  ("label",   .str e.label),
                  ("address", .str e.address),
                  ("source",  .str e.source),
                  ("addedAt", .num (Int.ofNat e.addedAt))
                ] ++ (match e.ensName with | some n => #[("ensName", .str n)] | none => #[])
                  ++ (match e.tag     with | some t => #[("tag",     .str t)] | none => #[]))
              ]
  | "skills.list" =>
      let metas ← LeanKohaku.Daemon.SkillsStore.listAll
      let arr : Array Json := (metas.map (fun m =>
        Json.obj #[
          ("name",        .str m.name),
          ("description", .str m.description),
          ("category",    .str m.category),
          ("risk",        .str m.risk),
          ("path",        .str m.path)
        ]
      )).toArray
      pure <| .ok <| .obj #[("skills", .arr arr)]
  | "skills.get" =>
      match paramString req.params "name" with
      | .error err => pure (.error err)
      | .ok name =>
          if name = "" || name = "_root" then
            match ← LeanKohaku.Daemon.SkillsStore.readRootManifest with
            | some body => pure <| .ok <| .obj #[("name", .str "_root"), ("body", .str body)]
            | none      => pure <| .error { code := -32024, message := "no root manifest at skills/SKILL.md", data := none }
          else
            match ← LeanKohaku.Daemon.SkillsStore.readBody name with
            | some body => pure <| .ok <| .obj #[("name", .str name), ("body", .str body)]
            | none      => pure <| .error { code := -32024, message := s!"no skill named {name}", data := none }
  | "llm.ensureUp" =>
      -- TUI's chat flow calls this on entry. Idempotent: probes
      -- LLM_BASE_URL; if down and LLM_AUTO_SPAWN/LLM_SERVER_BINARY are
      -- configured, spawns llama-server and waits for /v1/models to go
      -- 200 OK. Reports outcome verbatim for UX surfacing.
      let outcome ← LeanKohaku.Daemon.LlmServer.ensureUp
      -- Best-effort probe of the served model name. The chat UI shows
      -- this so users know what's running (and how to swap by changing
      -- LOCAL_LLM_MODEL or restarting llama-server with a different
      -- model file).
      let baseUrl := ((← IO.getEnv "LLM_BASE_URL").getD "http://127.0.0.1:8080/v1")
      let modelName ← try
        let out ← IO.Process.output {
          cmd := "/usr/bin/env",
          args := #["curl", "-fsS", "-m", "2", s!"{baseUrl}/models"]
        }
        if out.exitCode == 0 then
          match LeanKohaku.Encoding.Json.parse out.stdout with
          | .ok j =>
              -- Try OpenAI shape `data[0].id` first, then llama.cpp's `models[0].model`.
              let viaData : Option String :=
                ((getField "data" j >>= asArray).bind (·[0]?))
                  >>= (getField "id" ·) >>= asString
              let viaModels : Option String :=
                ((getField "models" j >>= asArray).bind (·[0]?))
                  >>= (getField "model" ·) >>= asString
              pure (viaData <|> viaModels)
          | _ => pure none
        else pure none
      catch _ => pure none
      let modelField : Array (String × Json) := match modelName with
        | some s => #[("model", .str s)]
        | none   => #[]
      pure <| .ok <| .obj <| #[
        ("outcome", .str outcome.toString),
        ("baseUrl", .str baseUrl)
      ] ++ modelField
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
          let regex0 := LeanKohaku.LlmAgent.RuleParser.parse prompt
          -- 1a. ENS pre-resolution. The model has no network egress; the
          -- daemon does. Resolving `.eth` names here removes the most
          -- common ask-loop ("can't resolve ENS, please paste 0x..."),
          -- and the model's prompt context gets the canonical 0x in the
          -- seed. Walks the conventionally-named recipient fields the
          -- RuleParser produces.
          let resolveEnsField : String → LeanKohaku.Ethereum.Intent.RegexDraft → IO LeanKohaku.Ethereum.Intent.RegexDraft :=
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
                        match ← LeanKohaku.Ethereum.Ens.resolveIO cfg.policy ensEp 1 s viaEns? with
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
          let eoaNames ← LeanKohaku.Wallet.EoaStore.list
          let mut walletEntries : List (String × String × Option (String × String)) := []
          for name in eoaNames do
            match ← LeanKohaku.Wallet.EoaStore.load name with
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
          let tpmStateDir : System.FilePath := ".leankohaku/keystore/tpm2"
          for name in tpmNames do
            let addrFile := tpmStateDir / name / "r1-account-address.txt"
            if ← addrFile.pathExists then
              let raw ← IO.FS.readFile addrFile
              let addr := raw.trimAscii.toString
              if !addr.isEmpty then
                walletEntries := walletEntries ++ [(name, addr, none)]
          let bookEntries ← LeanKohaku.Daemon.AddressBook.loadIO
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
              IO LeanKohaku.Ethereum.Ownership.Status :=
            fun addr deriv? => do
              match deriv? with
              | none => pure .hardware
              | some (slotName, path) =>
                  match ← LeanKohaku.Daemon.State.getUnlocked? state slotName with
                  | none => pure .locked
                  | some slot =>
                      match ← deriveAddressFromSeed slot.seed path with
                      | .ok derived =>
                          if derived.toLower = addr.toLower then
                            pure (.verified path)
                          else
                            pure (.mismatch derived)
                      | .error _ => pure .locked
          let resolveLocal (key : String) (d : LeanKohaku.Ethereum.Intent.RegexDraft) :
              IO (LeanKohaku.Ethereum.Intent.RegexDraft ×
                  Option LeanKohaku.Ethereum.Ownership.Witness) := do
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
          let ownerships : List LeanKohaku.Ethereum.Ownership.Witness :=
            [w_to, w_spender, w_from].filterMap id
          -- 1a-ter. Deterministic amount conversion. Models are
          -- documented unreliable at unit conversion (we caught gpt-oss
          -- emit `1e15` for "0.01 ETH" instead of `1e16`). The daemon
          -- already has the decimals via Swap.Tokens; parse here and
          -- inject `amountBase` so the model only has to copy.
          let chainEnumOpt0 : Option LeanKohaku.Swap.Tokens.ChainId :=
            match chainId with
            | 1 => some .mainnet
            | 11155111 => some .sepolia
            | _ => none
          let decimalsForAsset (asset : String) : Option Nat :=
            let a := asset.toLower
            if a = "eth" || a = "wei" || a = "ether" then some 18
            else match LeanKohaku.Swap.Tokens.findBySymbol asset with
                 | some t => some t.decimals
                 | none => none
          let regex := match regex5.field? "amount", regex5.field? "asset" with
            | some amt, some asset =>
                match decimalsForAsset asset with
                | none => regex5
                | some d =>
                    match LeanKohaku.Util.Units.parseUnits amt d with
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
              LeanKohaku.Ethereum.Ownership.Witness → Json :=
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
              ("action",     .str (LeanKohaku.Ethereum.Intent.Action.toString regex.action)),
              ("fields",     .arr (regex.fields.map (fun kv =>
                                Json.obj #[("k", .str kv.fst), ("v", .str kv.snd)])
                              |>.toArray)),
              ("unresolved", .arr (regex.unresolved.map Json.str |>.toArray)),
              ("confidence", .str (LeanKohaku.Ethereum.Intent.Confidence.toString regex.confidence)),
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
          let actionTag := LeanKohaku.Ethereum.Intent.Action.toString regex.action
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
            else LeanKohaku.Daemon.SkillsStore.readBody skillName
          -- 1c. Build a small chainContext object the model can read
          -- to resolve token symbols. The daemon already knows the
          -- addresses for chains we support; passing them removes the
          -- "I don't know the USDC contract" ask-loop. We only include
          -- tokens for the request's chain to keep context small.
          let chainEnumOpt : Option LeanKohaku.Swap.Tokens.ChainId :=
            match chainId with
            | 1 => some .mainnet
            | 11155111 => some .sepolia
            | _ => none
          let knownTokensJson : Json := match chainEnumOpt with
            | none => .arr #[]
            | some ce =>
                let tokens := LeanKohaku.Swap.Tokens.registry.filterMap (fun t =>
                  match LeanKohaku.Swap.Tokens.addressOn t ce with
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
                    LeanKohaku.Registry.KnownProtocols.aaveV3PoolFor ce),
                  ("Morpho Blue",  "morpho",
                    LeanKohaku.Registry.KnownProtocols.morphoBlueFor ce)
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
            match LeanKohaku.LlmAgent.DirectSynth.synth regex chainId effectiveSenderAddr? with
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
            (regex.action == LeanKohaku.Ethereum.Intent.Action.unknown)
              && (regex.confidence == LeanKohaku.Ethereum.Intent.Confidence.rejected)
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
          let llmResp ← LeanKohaku.LlmAgent.Bridge.call
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
              -- informational. See `LeanKohaku/Agent/Trace.lean`.
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
                            ("value",   .num (Int.ofNat ps.value)),
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
                  ("llmRaw", .str (LeanKohaku.Encoding.Json.compact llmResult)),
                  ("validateError", .str "llm.parseIntent returned no `raw` field (full sidecar response shown above)")
                ] ++ traceField
              else
                -- 3. Parse + validate via Lean's IntentParser. Three outcomes:
                --    .error msg          — malformed JSON / hard-reject
                --    .ok (.ask err q)    — model legitimately asked for clarification
                --    .ok (.intent i)     — ready to encode
                match LeanKohaku.LlmAgent.IntentParser.parseIntent rawStr chainId with
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
          let resp ← LeanKohaku.LlmAgent.Bridge.rolloverChatSession chainId sessionKey
          pure <| .ok <| LeanKohaku.LlmAgent.Bridge.responseToJson resp
  | "chat.listSessions" =>
      -- Read-only enumeration of the agentd's SQLite session store.
      -- Pure proxy — the agentd applies the `chainId` / `sessionKey`
      -- filters and the incognito mask; this RPC adds no business
      -- logic. Trust: produces no calldata, never gates a signing
      -- decision.
      let limit?   : Option Nat    := getField "limit" req.params >>= asNat
      let chainId? : Option Nat    := getField "chainId" req.params >>= asNat
      let key?     : Option String := getField "sessionKey" req.params >>= asString
      let resp ← LeanKohaku.LlmAgent.Bridge.listSessions limit? chainId? key?
      pure <| .ok <| LeanKohaku.LlmAgent.Bridge.responseToJson resp
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
          let resp ← LeanKohaku.LlmAgent.Bridge.getSession sid
          pure <| .ok <| LeanKohaku.LlmAgent.Bridge.responseToJson resp
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
      let resp ← LeanKohaku.LlmAgent.Bridge.listProposedTxs limit? chainId?
      pure <| .ok <| LeanKohaku.LlmAgent.Bridge.responseToJson resp
  | "llm.parseIntent" =>
      -- Forward the prompt + regex seed + chainId to the LLM sidecar,
      -- which returns the raw model output (a JSON string) unchanged.
      -- The Lean daemon — not this RPC — parses + validates via
      -- LlmAgent.IntentParser before anything reaches tx.encodeIntent
      -- and the simulate/ConfirmGate gate. This handler is intentionally
      -- a transparent proxy; the trust boundary is the Lean parser.
      let resp ← LeanKohaku.LlmAgent.Bridge.call
        { method := "llm.parseIntent", params := req.params, id := 0 }
      pure <| .ok <| LeanKohaku.LlmAgent.Bridge.responseToJson resp
  | "tx.encodeIntent" =>
      -- Pure Lean encoder for the leaf intent variants
      -- (nativeTransfer / erc20Transfer / erc20Approve / rawCall). The
      -- multi-step actions (swap, aave*) stay on their per-action RPCs
      -- because they need chain-aware preflight reads. Both UX surfaces
      -- (trusted hard-wired path + future LLM chat path) converge here:
      -- one encoder, one place to audit, deterministic on inputs. No
      -- IO, no signing — encoder output still has to traverse simulate
      -- + ConfirmGate before any key touches it.
      match LeanKohaku.Ethereum.IntentJson.parseIntent req.params with
      | .error msg =>
          pure <| .error { code := -32602, message := s!"invalid intent: {msg}", data := none }
      | .ok intent =>
          match LeanKohaku.Ethereum.IntentEncode.encode intent with
          | .error msg =>
              pure <| .error { code := -32602, message := msg, data := none }
          | .ok enc =>
              pure <| .ok <| .obj #[
                ("to",       .str enc.to),
                ("value",    .num (Int.ofNat enc.valueWei)),
                ("data",     .str enc.data),
                ("chainId",  .num (Int.ofNat (LeanKohaku.Ethereum.Intent.Intent.chainId intent))),
                ("canonical", .str (LeanKohaku.Ethereum.IntentCanonical.toCanonicalString intent)),
                ("actionTag", .str (LeanKohaku.Ethereum.IntentCanonical.actionTag intent))
              ]
  | "tx.simulate" =>
      -- Why: dry-run a transaction against the RPC node before signing.
      -- Combines eth_call (catches revert + returns return-data) and
      -- eth_estimateGas (gas estimate). Both are policy-gated through
      -- Outbound. The output is the load-bearing piece of Phase 2 clear-
      -- signing: every signed tx must be simulated and the user must
      -- confirm the simulated effect, not the LLM/dApp's prose summary.
      --
      -- Backend selection (kohaku-provider style): callers can pass
      -- `params.backend = "rpc" | "colibri" | "helios"` to pick which
      -- backend executes this single simulation. Absent → the daemon-wide
      -- `daemon.readBackend` default (also `rpc` until set otherwise). The
      -- dedicated `tx.simulate{Colibri,Helios}` methods stay as explicit
      -- aliases and are unaffected.
      match paramString req.params "to" with
      | .error err => pure (.error err)
      | .ok to =>
          let data := paramStringD req.params "data" "0x"
          let from? := getField "from" req.params >>= asString
          let value := paramStringD req.params "value" "0x0"
          let block := paramStringD req.params "block" "latest"
          let chain? := getField "chain" req.params >>= asString
          let backendParam : Option LeanKohaku.Daemon.State.ReadBackend :=
            (getField "backend" req.params >>= asString) >>= LeanKohaku.Daemon.State.ReadBackend.parse?
          let backend ← match backendParam with
            | some b => pure b
            | none => LeanKohaku.Daemon.State.getReadBackend state
          match endpointForChain cfg chain? with
          | .error err =>
              pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok endpoint =>
              match backend with
              | .colibri =>
                  -- Route to the persistent Colibri client if running;
                  -- fall back to the one-shot sidecar otherwise. Same
                  -- shape as the dedicated `tx.simulateColibri` handler.
                  let cParams := mergeHeliosDefaults req.params endpoint cfg.chainId
                  -- mergeHeliosDefaults also injects executionRpc which
                  -- Colibri ignores — harmless. chainId injection is the
                  -- piece both backends need.
                  match ← LeanKohaku.Daemon.State.colibriClient? state with
                  | some c =>
                      let resp ← LeanKohaku.Colibri.Persistent.call c "tx.simulate" cParams
                      pure <| .ok <| LeanKohaku.Colibri.Persistent.responseToJson resp
                  | none =>
                      let resp ← LeanKohaku.Colibri.Bridge.call
                        { method := "tx.simulate", params := cParams, id := 0 }
                      pure <| .ok <| LeanKohaku.Colibri.Bridge.responseToJson resp
              | .helios =>
                  let hParams := mergeHeliosDefaults req.params endpoint cfg.chainId
                  match ← LeanKohaku.Daemon.State.heliosClient? state with
                  | some c =>
                      let resp ← LeanKohaku.Helios.Persistent.call c "tx.simulate" hParams
                      pure <| .ok <| LeanKohaku.Helios.Persistent.responseToJson resp
                  | none =>
                      let resp ← LeanKohaku.Helios.Bridge.call
                        { method := "tx.simulate", params := hParams, id := 0 }
                      pure <| .ok <| LeanKohaku.Helios.Bridge.responseToJson resp
              | .rpc =>
                -- Build the call object once; eth_call and eth_estimateGas
                -- accept the same shape.
                let txObj : Json := .obj <|
                  (match from? with | some f => #[("from", .str f)] | none => #[])
                  ++ #[("to", .str to), ("value", .str value), ("data", .str data)]
                -- Why: tx.simulate must run against a full execution node.
                -- Colibri's stateless light-client model verifies state reads
                -- but cannot faithfully replay arbitrary contract execution
                -- (multicall, router calls, etc.) — light-client validation
                -- of a multicall eth_call surfaces as a spurious revert.
                -- The opt-in tx.simulateColibri method covers the verified
                -- case explicitly. Keep this path on direct RPC.
                let via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none
                let callRes ← LeanKohaku.RPC.Outbound.call cfg.policy endpoint
                  .call (.arr #[txObj, .str block]) via?
                let gasRes ← LeanKohaku.RPC.Outbound.estimateGas
                  cfg.policy endpoint txObj block via?
                -- Opt-in `debug_traceCall` with the callTracer + log capture.
                -- Many public RPCs don't expose `debug_*` namespaces; we
                -- surface the failure as `traceUnavailable` so callers can
                -- gracefully degrade to the eth_call-only output. The trace
                -- itself is returned raw — TUI consumers parse Transfer events
                -- (topic[0] = 0xddf252ad...) downstream to render which
                -- tokens move pre-sign.
                let traceFlag := ((getField "trace" req.params) >>= asBool).getD false
                let chainIdForMeta :=
                  ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
                -- traceField holds either `[("trace", ...)]`, `[("trace",...),
                -- ("tokenMetadata", ...)]`, or `[("traceUnavailable", ...)]`.
                let traceField : Array (String × Json) ←
                  if traceFlag then
                    let traceCfg : Json := .obj #[
                      ("tracer", .str "callTracer"),
                      ("tracerConfig", .obj #[("withLog", .bool true)])
                    ]
                    let traceParams : Json := .arr #[txObj, .str block, traceCfg]
                    match ← LeanKohaku.RPC.Outbound.call cfg.policy endpoint
                        .debugTraceCall traceParams with
                    | .ok traceJson =>
                        -- Prefetch metadata for every token that emits a
                        -- Transfer log inside the trace. Dedup by lowercased
                        -- address so we make one eth_call per token, not per
                        -- transfer event. Failures are silent — TransfersBlock
                        -- gracefully falls back to raw uint256 + short addr.
                        let allTokens := collectTransferTokens traceJson
                        let mut seen : Array String := #[]
                        let mut tmObj : Array (String × Json) := #[]
                        for raw in allTokens do
                          let lo := raw.toLower
                          if seen.contains lo then continue
                          seen := seen.push lo
                          match ← LeanKohaku.Daemon.TokenMeta.lookupOrFetch
                              state cfg.policy endpoint chainIdForMeta raw with
                          | some m =>
                              tmObj := tmObj.push (lo,
                                LeanKohaku.Daemon.TokenMeta.toJson m)
                          | none => pure ()
                        pure #[("trace", traceJson),
                               ("tokenMetadata", .obj tmObj)]
                    | .error e => pure #[("traceUnavailable", Json.str e)]
                  else
                    pure #[]
                let okBool := match callRes with | .ok _ => true | .error _ => false
                let returnField : Array (String × Json) := match callRes with
                  | .ok j => #[("returnData", j)]
                  | .error _ => #[]
                let revertField : Array (String × Json) := match callRes with
                  | .error e => #[("revertReason", Json.str e)]
                  | .ok _ => #[]
                let gasField : Array (String × Json) := match gasRes with
                  | .ok j => #[("gasEstimate", j)]
                  | .error e =>
                      #[("gasEstimateError", Json.str e)]
                pure <| .ok <| .obj <| #[
                  ("ok", .bool okBool),
                  ("block", .str block),
                  ("tx", txObj)
                ] ++ returnField ++ revertField ++ gasField ++ traceField
  | "tx.preflightContext" =>
      -- Why: surface "what does the chain currently say?" alongside the
      -- deterministic simulate output. For approves we read the current
      -- allowance(owner, spender); for transfers we read balanceOf /
      -- eth_getBalance and flag insufficient funds; for both, we count
      -- prior Transfer/Approval events between the parties within a
      -- bounded recent window. Display-only — the signer never sees this
      -- data; tx.simulate + canonical render + decode still guard the
      -- signature. See LeanKohaku/Daemon/Preflight.lean for the per-kind
      -- logic and lookback window.
      match paramString req.params "to" with
      | .error err => pure (.error err)
      | .ok to =>
          let data := paramStringD req.params "data" "0x"
          let valueHex := paramStringD req.params "value" "0x0"
          let fromAddr := (getField "from" req.params >>= asString).getD ""
          let chain? := getField "chain" req.params >>= asString
          match endpointForChain cfg chain? with
          | .error err =>
              pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok endpoint =>
              let chainIdForProbe :=
                ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
              let lookback :=
                ((getField "lookback" req.params) >>= asNat).getD
                  LeanKohaku.Daemon.Preflight.defaultLookback
              if fromAddr.isEmpty then
                pure <| .error {
                  code := -32602
                  message := "tx.preflightContext: `from` (string) required"
                  data := none
                }
              else
                let result ← LeanKohaku.Daemon.Preflight.run
                  state cfg.policy endpoint chainIdForProbe
                  fromAddr to valueHex data lookback
                pure (.ok result)
  | "tx.simulateColibri" =>
      -- Why: same role as `tx.simulate` (pre-sign dry run) but executed
      -- inside the Colibri stateless light client. EVM runs locally in
      -- WASM; missing state is pulled via committee-signed Merkle proofs.
      -- Prefers the persistent client when one is running (no cold start);
      -- falls back to a fresh one-shot spawn otherwise. Output is UNTRUSTED
      -- for signing decisions — the ConfirmGate uses it as confirmation
      -- copy only; the signed tx is re-decoded in Lean before broadcast.
      match ← LeanKohaku.Daemon.State.colibriClient? state with
      | some c =>
          let resp ← LeanKohaku.Colibri.Persistent.call c "tx.simulate" req.params
          pure <| .ok <| LeanKohaku.Colibri.Persistent.responseToJson resp
      | none =>
          let resp ← LeanKohaku.Colibri.Bridge.call
            { method := "tx.simulate", params := req.params, id := 0 }
          pure <| .ok <| LeanKohaku.Colibri.Bridge.responseToJson resp
  | "eth.proxyVerified" =>
      -- Why: generic verified-read surface. Forwards { chainId, method,
      -- params } through the persistent Colibri client so callers (TUI,
      -- agents) can fetch eth_getBalance / eth_call / eth_getLogs / etc.
      -- with consensus-verified results. Only available while the
      -- persistent client is running; returns a clear error otherwise so
      -- callers can fall back to the untrusted-RPC path.
      match ← LeanKohaku.Daemon.State.colibriClient? state with
      | some c =>
          let resp ← LeanKohaku.Colibri.Persistent.call c "eth.proxy" req.params
          pure <| .ok <| LeanKohaku.Colibri.Persistent.responseToJson resp
      | none =>
          pure <| .error {
            code := -32099,
            message := "colibri client not running",
            data := some (.str "call daemon.colibri.toggle { enable: true } first")
          }
  | "daemon.colibri.toggle" =>
      -- Why: spawn or tear down the persistent Colibri client at runtime.
      -- Toggling is idempotent. The cost is paid here (sync-committee
      -- bootstrap on the first request after spawn) rather than on every
      -- read call. Falls back to the legacy one-shot path when off.
      let enable := ((getField "enable" req.params) >>= asBool).getD true
      if enable then
        -- Mirror Daemon.Config.runtimeDir; we can't import Config here
        -- (Config depends on Server, would cycle). Same XDG_RUNTIME_DIR
        -- → TMPDIR (macOS launchd per-user dir) → /tmp fallback chain.
        let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
          | some d => pure d
          | none =>
              match ← IO.getEnv "TMPDIR" with
              | some d => pure d
              | none => pure "/tmp"
        let socketPath := s!"{runtimeRoot}/leankohaku/colibri.sock"
        try
          let _ ← LeanKohaku.Daemon.State.colibriEnable state socketPath
          pure <| .ok <| .obj #[
            ("ok", .bool true),
            ("running", .bool true),
            ("socket", .str socketPath)
          ]
        catch e =>
          pure <| .error {
            code := -32099,
            message := s!"failed to start colibri: {e}",
            data := none
          }
      else
        LeanKohaku.Daemon.State.colibriDisable state
        pure <| .ok <| .obj #[("ok", .bool true), ("running", .bool false)]
  | "daemon.colibri.status" =>
      match ← LeanKohaku.Daemon.State.colibriClient? state with
      | some c =>
          pure <| .ok <| .obj #[
            ("running", .bool true),
            ("socket", .str c.socket)
          ]
      | none =>
          pure <| .ok <| .obj #[("running", .bool false)]
  | "tx.simulateHelios" =>
      -- Why: opt-in REVM-backed simulation. Same role as `tx.simulate`
      -- (pre-sign dry run) but executed inside @a16z/helios — a Rust
      -- trustless light client that verifies execution state against
      -- sync-committee proofs and runs eth_call / eth_estimateGas in an
      -- embedded REVM. Prefers the persistent client when running; falls
      -- back to a fresh one-shot spawn otherwise. UNTRUSTED for signing
      -- decisions — ConfirmGate uses output as confirmation copy; the
      -- signed tx is re-decoded in Lean before broadcast.
      --
      -- executionRpc and chainId are injected from the daemon's configured
      -- endpoint (cfg.rpcEndpoint via endpointForChain) when the caller
      -- omits them; explicit params win so a caller can target a specific
      -- network or RPC without reconfiguring the daemon. consensusRpc is
      -- helios-specific (beacon API) and stays caller-supplied with the
      -- mainnet built-in default.
      let chain? := getField "chain" req.params >>= asString
      match endpointForChain cfg chain? with
      | .error e =>
          pure <| .error { code := -32021, message := "unknown chain", data := some (.str e) }
      | .ok endpoint =>
          let injected := mergeHeliosDefaults req.params endpoint cfg.chainId
          match ← LeanKohaku.Daemon.State.heliosClient? state with
          | some c =>
              let resp ← LeanKohaku.Helios.Persistent.call c "tx.simulate" injected
              pure <| .ok <| LeanKohaku.Helios.Persistent.responseToJson resp
          | none =>
              let resp ← LeanKohaku.Helios.Bridge.call
                { method := "tx.simulate", params := injected, id := 0 }
              pure <| .ok <| LeanKohaku.Helios.Bridge.responseToJson resp
  | "eth.proxyHelios" =>
      -- Why: generic helios-backed read surface. Same shape as
      -- `eth.proxyVerified` (Colibri) but routes through the helios
      -- sidecar. Available only when the persistent helios client is
      -- running; returns a clear error otherwise so callers can fall
      -- back to the configured RPC or to the colibri-verified path.
      -- executionRpc and chainId default to the configured endpoint
      -- (see `tx.simulateHelios` for rationale).
      let chain? := getField "chain" req.params >>= asString
      match endpointForChain cfg chain? with
      | .error e =>
          pure <| .error { code := -32021, message := "unknown chain", data := some (.str e) }
      | .ok endpoint =>
          let injected := mergeHeliosDefaults req.params endpoint cfg.chainId
          match ← LeanKohaku.Daemon.State.heliosClient? state with
          | some c =>
              let resp ← LeanKohaku.Helios.Persistent.call c "eth.proxy" injected
              pure <| .ok <| LeanKohaku.Helios.Persistent.responseToJson resp
          | none =>
              pure <| .error {
                code := -32099,
                message := "helios client not running",
                data := some (.str "call daemon.helios.toggle { enable: true } first")
              }
  | "daemon.helios.toggle" =>
      -- Why: spawn or tear down the persistent helios client at runtime.
      -- Idempotent. Spawning is cheap (consensus sync deferred until the
      -- first proofable request); falling back to the legacy one-shot
      -- path when off pays the sync per call.
      let enable := ((getField "enable" req.params) >>= asBool).getD true
      if enable then
        let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
          | some d => pure d
          | none =>
              match ← IO.getEnv "TMPDIR" with
              | some d => pure d
              | none => pure "/tmp"
        let socketPath := s!"{runtimeRoot}/leankohaku/helios.sock"
        try
          let _ ← LeanKohaku.Daemon.State.heliosEnable state socketPath
          pure <| .ok <| .obj #[
            ("ok", .bool true),
            ("running", .bool true),
            ("socket", .str socketPath)
          ]
        catch e =>
          pure <| .error {
            code := -32099,
            message := s!"failed to start helios: {e}",
            data := none
          }
      else
        LeanKohaku.Daemon.State.heliosDisable state
        pure <| .ok <| .obj #[("ok", .bool true), ("running", .bool false)]
  | "daemon.helios.status" =>
      match ← LeanKohaku.Daemon.State.heliosClient? state with
      | some c =>
          pure <| .ok <| .obj #[
            ("running", .bool true),
            ("socket", .str c.socket)
          ]
      | none =>
          pure <| .ok <| .obj #[("running", .bool false)]
  | "daemon.readBackend.set" =>
      -- Pick the daemon's default read/simulate backend (kohaku-provider
      -- style toggle). Honored by `tx.simulate` when its `backend` field
      -- is absent. `tx.simulate{Colibri,Helios}` dedicated aliases ignore
      -- this; pass `backend` explicitly per call to override.
      match (getField "backend" req.params >>= asString)
            >>= LeanKohaku.Daemon.State.ReadBackend.parse? with
      | none =>
          pure <| .error {
            code := -32602,
            message := "params.backend must be one of: rpc | colibri | helios",
            data := none
          }
      | some b =>
          LeanKohaku.Daemon.State.setReadBackend state b
          pure <| .ok <| .obj #[
            ("ok", .bool true),
            ("backend", .str b.asString)
          ]
  | "daemon.readBackend.status" =>
      let b ← LeanKohaku.Daemon.State.getReadBackend state
      pure <| .ok <| .obj #[("backend", .str b.asString)]
  | "daemon.approvals.list" =>
      -- Read-only listing of outgoing ERC-20 allowances for a wallet
      -- on a chain. Spec (per D3 / audit-approvals SKILL.md): walk
      -- `chain.scanTransfers` for `Approval` events from `wallet`
      -- over a configurable block window and return unique
      -- `[{token, spender, amount, lastSeenBlock}]` records, cached
      -- daemon-side, refresh on demand.
      --
      -- This is a wire-level stub: the response shape is real so the
      -- TUI's audit screen can integrate against it; the actual scan
      -- + cache logic lands in a follow-up. Today it returns an empty
      -- list with `implemented: false`, which the TUI surfaces as "no
      -- approvals scanned yet (scan not implemented)".
      let walletStr? : Option String :=
        getField "wallet" req.params >>= asString
      let chainIdParam : Nat :=
        ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
      let walletEntry : Array (String × Json) :=
        match walletStr? with
        | some w => #[("wallet", .str w)]
        | none   => #[]
      pure <| .ok <| .obj <| #[
        ("chainId",     .num (Int.ofNat chainIdParam)),
        ("approvals",   .arr #[]),
        ("implemented", .bool false),
        ("note",        .str "approval scan not yet wired; see daemon.approvals.list TODO")
      ] ++ walletEntry
  | "tx.decodeIntent" =>
      -- Why: forwards { chainId, to, value, data, from? } to the clearsign
      -- sidecar. Before forwarding, prefetch ERC-20 metadata for `to` AND
      -- for any address-shaped 32-byte word found in the calldata so the
      -- sidecar's tokenAmount formatter can render real decimals + ticker
      -- on inner-call fields too (e.g. tokenIn/tokenOut inside a
      -- multicall-wrapped Uniswap V3 swap). For non-ERC-20 contracts the
      -- eth_calls revert and the cache stays empty — formatters fall back
      -- to the address tag.
      let chainIdParam :=
        ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
      let toParam :=
        ((getField "to" req.params) >>= asString).getD ""
      let dataParam :=
        ((getField "data" req.params) >>= asString).getD ""
      let mut tokenMetaPairs : Array (String × Json) := #[]
      let ep := chainEndpointFor cfg req.params chainIdParam
      if !toParam.isEmpty then
        match ← LeanKohaku.Daemon.TokenMeta.lookupOrFetch
            state cfg.policy ep chainIdParam toParam with
        | some m =>
            tokenMetaPairs := tokenMetaPairs.push (toParam.toLower,
              LeanKohaku.Daemon.TokenMeta.toJson m)
        | none => pure ()
      -- Walk calldata for embedded address-shaped words (12 zero bytes +
      -- 20 nonzero bytes) and prefetch metadata for each. False positives
      -- (small uint256 values that fit in 160 bits) are harmless: the
      -- eth_call reverts and the cache absorbs the miss.
      let embeddedAddrs := scanCalldataAddresses dataParam
      for addr in embeddedAddrs do
        let lower := addr.toLower
        let alreadyHave := tokenMetaPairs.any (fun p => p.1 == lower)
        if alreadyHave then
          pure ()
        else
          match ← LeanKohaku.Daemon.TokenMeta.lookupOrFetch
              state cfg.policy ep chainIdParam addr with
          | some m =>
              tokenMetaPairs := tokenMetaPairs.push (lower,
                LeanKohaku.Daemon.TokenMeta.toJson m)
          | none => pure ()
      let tokenMeta : Json := .obj tokenMetaPairs
      -- ENS namehash → name session cache. Empty in the MVP — the
      -- shape is in place so the sidecar's `ensName` formatter has
      -- something to consult; population from observed register/renew
      -- calls + chain.ensReverseLookup is a follow-up.
      let ensNamesJson : Json :=
        LeanKohaku.Daemon.EnsNames.forDecodeRequest
          LeanKohaku.Daemon.EnsNames.emptyCache chainIdParam toParam dataParam
      let augmented : Json :=
        match req.params with
        | .obj fields =>
            .obj (fields.filter (fun (k, _) =>
                k != "tokenMetadata" ∧ k != "ensNames")
              ++ #[("tokenMetadata", tokenMeta), ("ensNames", ensNamesJson)])
        | other => other
      let resp ← LeanKohaku.Clearsign.Bridge.call
        { method := "tx.decodeIntent", params := augmented, id := 0 }
      pure <| .ok <| LeanKohaku.Clearsign.Bridge.responseToJson resp
  | "eip712.decodeIntent" =>
      -- Why: same architecture as tx.decodeIntent — daemon prefetches token
      -- metadata for any addresses we can identify cheaply (sellToken/
      -- buyToken in CowSwap-style orders, token in Permit2 EIP-712), then
      -- forwards to the clearsign sidecar with a `tokenMetadata` map. The
      -- sidecar walks the descriptor against `message`.
      let chainIdParam :=
        ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
      let messageObj := (getField "message" req.params).getD (.obj #[])
      -- Pull every address-shaped string out of the (top-level) message
      -- and prefetch metadata for it. This is cheap and covers the common
      -- token-bearing fields without descriptor-aware path resolution.
      let addrs : Array String :=
        match messageObj with
        | .obj fields =>
            fields.filterMap (fun (_, v) =>
              match v with
              | .str s =>
                  if s.startsWith "0x" && s.length = 42 then some s else none
              | _ => none)
        | _ => #[]
      let mut tmObj : Array (String × Json) := #[]
      let ep := chainEndpointFor cfg req.params chainIdParam
      for addr in addrs do
        match ← LeanKohaku.Daemon.TokenMeta.lookupOrFetch
            state cfg.policy ep chainIdParam addr with
        | some m =>
            tmObj := tmObj.push (addr.toLower,
              LeanKohaku.Daemon.TokenMeta.toJson m)
        | none => pure ()
      let augmented : Json :=
        match req.params with
        | .obj fields =>
            .obj (fields.filter (fun (k, _) => k != "tokenMetadata")
              ++ #[("tokenMetadata", .obj tmObj)])
        | other => other
      let resp ← LeanKohaku.Clearsign.Bridge.call
        { method := "eip712.decodeIntent", params := augmented, id := 0 }
      pure <| .ok <| LeanKohaku.Clearsign.Bridge.responseToJson resp
  | "shielded.balance" =>
      let passphrase? : Option String := getField "passphrase" req.params >>= asString
      match ← unlockPpSecretSmart state passphrase? with
      | .error err => pure (.error err)
      | .ok mnemonic =>
          shieldedBridgeCall cfg "shielded.balance" (.obj #[]) (some mnemonic) req
  | "shielded.railgun.balance" =>
      -- Read-only Railgun balance. Railgun keystore is rooted at the
      -- default EOA's BIP-39 seed (Railgun derives at its own BIP-32
      -- paths — disjoint from BIP-44 Ethereum — so the same seed root
      -- yields independent Railgun keys with no separate mnemonic on
      -- disk). The default wallet must currently be unlocked (master
      -- KEK / TPM / recent per-slot unlock). First call is slow
      -- (Subsquid sync + POI artifact fetch); cached runs are fast.
      -- Optional `name` param overrides the default wallet.
      let nameOverride? := getField "name" req.params >>= asString
      let seedHexE ← do
        match nameOverride? with
        | some n =>
            match ← unlockedSlot state n with
            | .error err => pure (Except.error err)
            | .ok slot => pure (Except.ok (rgSeedHexFromSlot slot))
        | none => rgSeedHexFromDefault state
      match seedHexE with
      | .error err => pure (.error err)
      | .ok seedHex =>
          shieldedBridgeCall cfg "shielded.railgun.balance" (.obj #[]) none req
            (rgSeedHex? := some seedHex)
  | "shielded.railgun.prepareShield" =>
      -- Preview: build unsigned shield txns. tokenAddress optional;
      -- absence ⇒ native ETH (plugin wraps to WETH internally). Same
      -- EOA-seed keystore source as balance.
      match paramString req.params "amountEth" with
      | .error err => pure (.error err)
      | .ok amountEth =>
          let tokenAddress? := getField "tokenAddress" req.params >>= asString
          let nameOverride? := getField "name" req.params >>= asString
          let seedHexE ← do
            match nameOverride? with
            | some n =>
                match ← unlockedSlot state n with
                | .error err => pure (Except.error err)
                | .ok slot => pure (Except.ok (rgSeedHexFromSlot slot))
            | none => rgSeedHexFromDefault state
          match seedHexE with
          | .error err => pure (.error err)
          | .ok seedHex =>
              let bridgeParams : Json := .obj <|
                #[("amountEth", .str amountEth)] ++
                (match tokenAddress? with
                  | some a => #[("tokenAddress", .str a)]
                  | none   => #[])
              shieldedBridgeCall cfg "shielded.railgun.prepareShield" bridgeParams none req
                (rgSeedHex? := some seedHex)
  | "shielded.railgun.shield" =>
      -- Composed: prepare + EOA-sign + broadcast. Mirrors shielded.deposit
      -- but uses the EOA's BIP-39 seed as the Railgun keystore root.
      -- Railgun derives at its own BIP-32 paths (disjoint from
      -- BIP-44 Ethereum), so the same seed root yields independent
      -- Railgun keys. One mnemonic on disk, one unlock surface — the
      -- EOA unlock already done by the caller (UnlockEoaStep in the
      -- TUI) is the *only* unlock this handler needs.
      match paramName req.params, paramString req.params "amountEth" with
      | .ok name, .ok amountEth =>
          let tokenAddress? := getField "tokenAddress" req.params >>= asString
          IO.eprintln s!"[shield-rg] shield: wallet={name} amountEth={amountEth}"
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              IO.eprintln s!"[shield-rg] unlocked slot {name} address={slot.address}"
              match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok privateKey =>
                  let seedHex := rgSeedHexFromSlot slot
                  let bridgeParams : Json := .obj <|
                    #[("amountEth", .str amountEth)] ++
                    (match tokenAddress? with
                      | some a => #[("tokenAddress", .str a)]
                      | none   => #[])
                  IO.eprintln "[shield-rg] calling bridge shielded.railgun.prepareShield (loads SDK, syncs from Subsquid; may take 30-60s on first run)"
                  match ← shieldedBridgeCall cfg "shielded.railgun.prepareShield"
                            bridgeParams none req
                            (rgSeedHex? := some seedHex) with
                      | .error err =>
                          IO.eprintln s!"[shield-rg] bridge prepare failed: {err.message}"
                          pure (.error err)
                      | .ok prepared =>
                          IO.eprintln "[shield-rg] bridge returned prepared shield; decoding txns"
                          let resultField :=
                            match getField "result" prepared with
                            | some r => r
                            | none => prepared
                          let txnsArr := getField "txns" resultField >>= asArray
                          match txnsArr with
                          | none =>
                              IO.eprintln "[shield-rg] bridge returned no txns array"
                              pure <| .error
                                { code := -32020,
                                  message := "bridge returned no txns",
                                  data := some prepared }
                          | some txns =>
                              IO.eprintln s!"[shield-rg] signing and broadcasting {txns.size} tx(s)"
                              -- Same Sepolia pinning rationale as shielded.deposit
                              -- (see comment there): without this, txns prepared
                              -- for chain 11155111 would be signed with
                              -- cfg.chainId if the daemon defaults to mainnet.
                              let cfgShield : Config :=
                                let sepEp := match endpointForChain cfg (some "sepolia") with
                                  | .ok ep => ep
                                  | .error _ => cfg.rpcEndpoint
                                { cfg with rpcEndpoint := sepEp, chainId := 11155111 }
                              match ← signAndBroadcastBridgeTxns cfgShield slot privateKey txns
                                       (some notify) (actionTag := "shielded.railgun.shield") with
                              | .error err =>
                                  IO.eprintln s!"[shield-rg] broadcast failed: {err.message}"
                                  pure (.error err)
                              | .ok sent =>
                                  IO.eprintln s!"[shield-rg] broadcast complete: {sent.size} tx(s) sent"
                                  pure <| .ok <| .obj #[
                                    ("prepared", prepared),
                                    ("sent", .arr sent)
                                  ]
      | _, _ => pure (.error invalidParams)
  | "shielded.railgun.unshield" =>
      -- Builds + relays the private op via an ERC-4337 bundler using an
      -- EIP-7702 delegated EOA. Native ETH is supported in alpha-21
      -- (unshield-as-WETH + withdraw tail call). The Railgun secret only
      -- is unlocked here; the delegating EOA private key is derived from
      -- the named slot.
      --
      -- 7702 detail: Railgun's paymaster only sponsors UserOps whose
      -- 7702 Authorization delegates to its hardcoded IMPL contract
      -- (0x304a…4b4c). The SDK signs and embeds this authorization
      -- inside every broadcast UserOp; no separate setup tx is needed.
      --
      -- Trust note: the EOA private key is passed to the sidecar via
      -- env for the duration of this call. Mitigation: short-lived
      -- sidecar process; user has already gone through ConfirmGate
      -- before this RPC is invoked.
      --
      -- Bundler URL resolution:
      --   1. LEANKOHAKU_RG_BUNDLER_URL (explicit override) — wins.
      --   2. CANDIDE_API_KEY in env → construct
      --      https://api.candide.dev/bundler/v3/sepolia/<key>.
      --      (Sepolia-pinned; mainnet would be /ethereum/.)
      -- Must serve EntryPoint 0.8 (railgun-rs target). Candide's
      -- multi-version endpoint serves 0.6/0.7/0.8/0.9 from the same URL.
      match paramName req.params, paramString req.params "recipient",
            paramString req.params "amountEth" with
      | .ok name, .ok recipient, .ok amountEth =>
          let tokenAddress? := getField "tokenAddress" req.params >>= asString
          let resolveBundlerUrl : IO (Option String) := do
            match ← IO.getEnv "LEANKOHAKU_RG_BUNDLER_URL" with
            | some u => pure (some u)
            | none =>
                match ← IO.getEnv "CANDIDE_API_KEY" with
                | some k => pure (some s!"https://api.candide.dev/bundler/v3/sepolia/{k}")
                | none   => pure none
          match ← resolveBundlerUrl with
          | none =>
              pure <| .error
                { code := -32024,
                  message := "no 4337 bundler configured — set LEANKOHAKU_RG_BUNDLER_URL or CANDIDE_API_KEY in daemon env (.env auto-loaded)",
                  data := none }
          | some bundlerUrl =>
              -- TEMP-TEST env override: if both LEANKOHAKU_RG_DELEGATING_KEY
              -- and LEANKOHAKU_RG_SEED_HEX are set, skip wallet-slot
              -- derivation entirely (test setup that uses an EOA outside
              -- the daemon's wallet store). The `name` param is still
              -- required by the call signature but ignored. REMOVE this
              -- branch before production.
              let envDelegatingKey? ← IO.getEnv "LEANKOHAKU_RG_DELEGATING_KEY"
              let envSeed? ← IO.getEnv "LEANKOHAKU_RG_SEED_HEX"
              match envDelegatingKey?, envSeed? with
              | some envKey, some envSeed =>
                  IO.eprintln s!"[shield-rg] TEMP-TEST: using LEANKOHAKU_RG_DELEGATING_KEY + LEANKOHAKU_RG_SEED_HEX from daemon env (wallet '{name}' ignored)"
                  let bridgeParams : Json := .obj <|
                    #[("recipient", .str recipient),
                      ("amountEth", .str amountEth)] ++
                    (match tokenAddress? with
                      | some a => #[("tokenAddress", .str a)]
                      | none   => #[])
                  shieldedBridgeCall cfg "shielded.railgun.unshield"
                    bridgeParams none req
                    (rgBundlerUrl? := some bundlerUrl)
                    (rgDelegatingKeyHex? := some envKey)
                    (rgSeedHex? := some envSeed)
              | _, _ =>
                  match ← unlockedSlot state name with
                  | .error err => pure (.error err)
                  | .ok slot =>
                      match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
                      | .error err =>
                          pure <| .error { invalidParams with data := some (.str err) }
                      | .ok privateKey =>
                          -- Hex.encode emits its own `0x` prefix.
                          let delegatingKeyHex := LeanKohaku.Crypto.Hex.encode privateKey
                          let seedHex := rgSeedHexFromSlot slot
                          let bridgeParams : Json := .obj <|
                            #[("recipient", .str recipient),
                              ("amountEth", .str amountEth)] ++
                            (match tokenAddress? with
                              | some a => #[("tokenAddress", .str a)]
                              | none   => #[])
                          shieldedBridgeCall cfg "shielded.railgun.unshield"
                            bridgeParams none req
                            (rgBundlerUrl? := some bundlerUrl)
                            (rgDelegatingKeyHex? := some delegatingKeyHex)
                            (rgSeedHex? := some seedHex)
      | _, _, _ => pure (.error invalidParams)
  | "shielded.railgun.transfer" =>
      -- Railgun-internal transfer (0zk → 0zk). ERC20-only at SDK level
      -- (tokenGuard). Bundler + 7702 details: see shielded.railgun.unshield.
      match paramName req.params, paramString req.params "recipient",
            paramString req.params "amountEth",
            paramString req.params "tokenAddress" with
      | .ok name, .ok recipient, .ok amountEth, .ok tokenAddress =>
          let resolveBundlerUrl : IO (Option String) := do
            match ← IO.getEnv "LEANKOHAKU_RG_BUNDLER_URL" with
            | some u => pure (some u)
            | none =>
                match ← IO.getEnv "CANDIDE_API_KEY" with
                | some k => pure (some s!"https://api.candide.dev/bundler/v3/sepolia/{k}")
                | none   => pure none
          match ← resolveBundlerUrl with
          | none =>
              pure <| .error
                { code := -32024,
                  message := "no 4337 bundler configured — set LEANKOHAKU_RG_BUNDLER_URL or CANDIDE_API_KEY in daemon env",
                  data := none }
          | some bundlerUrl =>
              match ← unlockedSlot state name with
              | .error err => pure (.error err)
              | .ok slot =>
                  match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      -- Hex.encode emits its own `0x` prefix.
                      let delegatingKeyHex := LeanKohaku.Crypto.Hex.encode privateKey
                      let seedHex := rgSeedHexFromSlot slot
                      shieldedBridgeCall cfg "shielded.railgun.transfer"
                        (.obj #[
                          ("recipient", .str recipient),
                          ("amountEth", .str amountEth),
                          ("tokenAddress", .str tokenAddress)
                        ]) none req
                        (rgBundlerUrl? := some bundlerUrl)
                        (rgDelegatingKeyHex? := some delegatingKeyHex)
                        (rgSeedHex? := some seedHex)
      | _, _, _, _ => pure (.error invalidParams)
  | "shielded.tornado.prepareDeposit" =>
      -- Tornado Cash deposit drafting (PR 2). The bridge sidecar
      -- generates the user's spending note + Pedersen-hashed
      -- commitment and returns `deposit(commitment)` calldata for
      -- the pool contract that matches `amountEth`. Fixed-denomination
      -- enforcement happens both here (sidecar validates) and at the
      -- Intent layer (`IntentParser.tornadoDeposit`). PR 2 ships a
      -- bridge stub that returns a structured "SDK not yet wired"
      -- error until the snarkjs + Baby Jubjub Pedersen layer lands.
      match paramString req.params "amountEth" with
      | .error err => pure (.error err)
      | .ok amountEth =>
          shieldedBridgeCall cfg "shielded.tornado.prepareDeposit"
            (.obj #[("amountEth", .str amountEth)]) none req
  | "shielded.tornado.prepareWithdraw" =>
      -- Tornado Cash withdraw drafting. Bridge sidecar consumes the
      -- user's saved deposit note + current pool merkle state and
      -- emits `withdraw(proof, root, nullifierHash, recipient,
      -- relayer, fee, refund)` calldata. Note + recipient are
      -- required; the bridge stub returns the same "not yet wired"
      -- error pending sidecar implementation.
      match paramString req.params "amountEth",
            paramString req.params "recipient",
            paramString req.params "note" with
      | .ok amountEth, .ok recipient, .ok note =>
          shieldedBridgeCall cfg "shielded.tornado.prepareWithdraw"
            (.obj #[
              ("amountEth", .str amountEth),
              ("recipient", .str recipient),
              ("note",      .str note)
            ]) none req
      | _, _, _ => pure (.error invalidParams)
  | "shielded.prepareDeposit" =>
      match paramString req.params "amountEth" with
      | .error err => pure (.error err)
      | .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          match ← unlockPpSecretSmart state passphrase? with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.prepareDeposit"
                (.obj #[("amountEth", .str amountEth)]) (some mnemonic) req
  | "shielded.deposit" =>
      match paramName req.params, paramString req.params "amountEth" with
      | .ok name, .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          IO.eprintln s!"[shield] deposit: wallet={name} amountEth={amountEth}"
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              IO.eprintln s!"[shield] unlocked slot {name} address={slot.address}"
              match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok privateKey =>
                  let mnemonicE ← do
                    if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
                      -- First-time PP setup. Per kohaku SDK convention the
                      -- mnemonic is freshly generated locally. Save path
                      -- still wants a passphrase for the per-PP record; if
                      -- the user didn't supply one, fall back to a
                      -- one-time random throwaway and rely on `attachMasterWrap`
                      -- (called below) so unlock UX still routes through
                      -- the master KEK.
                      IO.eprintln "[shield] no PP secret on disk; generating fresh 12-word mnemonic"
                      try
                        let m ← LeanKohaku.Wallet.Entropy.generateMnemonic 12
                        let phrase := LeanKohaku.Wallet.Mnemonic.phrase m
                        let pass ← match passphrase? with
                          | some p => pure p
                          | none =>
                              -- 32-byte random hex. Never returned to the
                              -- user; the master-wrap attachment immediately
                              -- after `save` is the only durable unlock path.
                              let r ← LeanKohaku.Crypto.Random.getRandomBytes 32
                              pure (LeanKohaku.Crypto.Hex.encode r)
                        match ← LeanKohaku.Wallet.PpSecretStore.save pass phrase with
                        | .error err =>
                            pure (.error
                              ({ code := -32022,
                                 message := "failed to persist generated PP secret",
                                 data := some (.str err) } : RpcError))
                        | .ok _ =>
                            -- Best-effort enrol into the wallet master so
                            -- the throwaway passphrase (if used) is not
                            -- the only key in play.
                            (do
                              match ← LeanKohaku.Daemon.State.getMasterKek? state with
                              | none => pure ()
                              | some s =>
                                  let _ ← LeanKohaku.Wallet.PpSecretStore.attachMasterWrap s.kek phrase
                                  pure ())
                            IO.eprintln "[shield] PP secret generated and persisted"
                            pure (.ok phrase)
                      catch e =>
                        pure (.error
                          ({ code := -32022,
                             message := "failed to generate PP secret",
                             data := some (.str e.toString) } : RpcError))
                    else
                      IO.eprintln "[shield] decrypting stored PP secret"
                      unlockPpSecretSmart state passphrase?
                  match mnemonicE with
                  | .error err => pure (.error err)
                  | .ok mnemonic =>
                      IO.eprintln "[shield] calling bridge shielded.prepareDeposit (this loads the SDK and syncs PP state from chain; may take 30-60s on first run)"
                      match ← shieldedBridgeCall cfg "shielded.prepareDeposit"
                                (.obj #[("amountEth", .str amountEth)]) (some mnemonic) req with
                      | .error err =>
                          IO.eprintln s!"[shield] bridge prepare failed: {err.message}"
                          pure (.error err)
                      | .ok prepared =>
                          IO.eprintln "[shield] bridge returned prepared deposit; decoding txns"
                          let resultField :=
                            match getField "result" prepared with
                            | some r => r
                            | none => prepared
                          let txnsArr := getField "txns" resultField >>= asArray
                          match txnsArr with
                          | none =>
                              IO.eprintln "[shield] bridge returned no txns array"
                              pure <| .error
                                { code := -32020,
                                  message := "bridge returned no txns",
                                  data := some prepared }
                          | some txns =>
                              IO.eprintln s!"[shield] signing and broadcasting {txns.size} tx(s)"
                              -- Privacy Pools v1 is Sepolia-only. Pin
                              -- the broadcast cfg to the sepolia
                              -- endpoint + chainId regardless of the
                              -- daemon's default. Same reasoning as
                              -- shieldedBridgeCall (slice 31) — without
                              -- this, txns prepared for chain 11155111
                              -- got signed with cfg.chainId (mainnet)
                              -- and the broadcast surfaced as the
                              -- vague "chain RPC failed".
                              let cfgShield : Config :=
                                let sepEp := match endpointForChain cfg (some "sepolia") with
                                  | .ok ep => ep
                                  | .error _ => cfg.rpcEndpoint
                                { cfg with rpcEndpoint := sepEp, chainId := 11155111 }
                              match ← signAndBroadcastBridgeTxns cfgShield slot privateKey txns (some notify) with
                              | .error err =>
                                  IO.eprintln s!"[shield] broadcast failed: {err.message}"
                                  pure (.error err)
                              | .ok sent =>
                                  IO.eprintln s!"[shield] broadcast complete: {sent.size} tx(s) sent"
                                  pure <| .ok <| .obj #[
                                    ("prepared", prepared),
                                    ("sent", .arr sent)
                                  ]
      | _, _ => pure (.error invalidParams)
  | "shielded.prepareWithdraw" =>
      match paramString req.params "recipient", paramString req.params "amountEth" with
      | .ok recipient, .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          match ← unlockPpSecretSmart state passphrase? with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.prepareWithdraw"
                (.obj #[("recipient", .str recipient), ("amountEth", .str amountEth)]) (some mnemonic) req
      | _, _ => pure (.error invalidParams)
  | "shielded.unshieldDrain" =>
      match paramString req.params "recipient", paramString req.params "amountEth" with
      | .ok recipient, .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          match ← unlockPpSecretSmart state passphrase? with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              match ← shieldedBridgeCall cfg "shielded.unshieldDrain"
                (.obj #[("recipient", .str recipient), ("amountEth", .str amountEth)])
                (some mnemonic) req with
              | .error err => pure (.error err)
              | .ok j =>
                  -- Record the recipient locally so the wallets-hub 0-link
                  -- check still passes after we credit the address with a
                  -- PP withdrawal. PP v1 is Sepolia-only today; chainId is
                  -- pinned in `shieldedBridgeCall`. Best-effort: a failed
                  -- log write never overrides the bridge response. Bridge
                  -- errors (e.g. RelayFeeGreaterThanMax) now arrive via
                  -- `.error` above, so the `.ok` arm is the actual relay
                  -- success path.
                  LeanKohaku.Daemon.PpDestinations.append recipient 11155111 "shielded.unshieldDrain"
                  pure (.ok j)
      | _, _ => pure (.error invalidParams)
  | "daemon.ppDestinations.add" =>
      -- Why: the auto-record hook in `shielded.unshieldDrain` only
      -- catches unshields THIS daemon executed after the hook
      -- existed. For older unshields, or unshields done out-of-band,
      -- the user can attest manually so the wallets-hub still treats
      -- the resulting address as PP-funded. Semantics: caller is
      -- saying "I unshielded to this; trust me." We do not try to
      -- verify against on-chain state.
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanKohaku.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let chainId := (getField "chainId" req.params >>= asNat).getD 11155111
              LeanKohaku.Daemon.PpDestinations.append address chainId "manual"
              pure <| .ok <| .obj #[
                ("ok", .bool true),
                ("address", .str address),
                ("chainId", .num (Int.ofNat chainId))
              ]
  | "daemon.ppDestinations.list" =>
      let entries ← LeanKohaku.Daemon.PpDestinations.list
      pure <| .ok <| .obj #[("entries", .arr entries)]
  | "shielded.reveal" =>
      let passphrase? : Option String := getField "passphrase" req.params >>= asString
      match ← unlockPpSecretSmart state passphrase? with
      | .error err => pure (.error err)
      | .ok mnemonic =>
          pure <| .ok <| .obj #[("mnemonic", .str mnemonic)]
  | "shielded.import" =>
      match paramString req.params "passphrase", paramString req.params "mnemonic" with
      | .ok passphrase, .ok mnemonic =>
          if (← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
            pure <| .error
              { code := -32023,
                message := "PP secret already stored — run 'kohaku shield delete' first",
                data := none }
          else
            match ← LeanKohaku.Wallet.PpSecretStore.save passphrase mnemonic with
            | .error err =>
                pure <| .error
                  { code := -32022, message := "failed to persist PP secret",
                    data := some (.str err) }
            | .ok _ =>
                pure <| .ok <| .obj #[("ok", .bool true)]
      | _, _ => pure (.error invalidParams)
  | "chain.history" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          let limit? : Option Nat := getField "limit" req.params >>= asNat
          let raw ← LeanKohaku.Daemon.TxJournal.read name limit?
          -- Overlay sphincs.inclusion records onto matching sphincs.userOp
          -- entries (by userOpHash) so the UI can show the L1 tx hash
          -- instead of the bundler's userOpHash. The inclusion record is
          -- a separate "kind"=sphincs.inclusion entry written by the poll
          -- RPC once the bundler returns a receipt.
          let isInclusion (j : Json) : Bool :=
            (getField "kind" j >>= asString) = some "sphincs.inclusion"
          -- Build a lookup userOpHash → (inclusionTxHash, blockNumber?, success?)
          -- as an Array (linear scan; lists here are bounded by the
          -- page limit, so O(n²) merge is fine). Later inclusion
          -- records override earlier ones for the same userOp because
          -- `find?` returns the LAST inserted match — we walk back to
          -- front below.
          let inclusionList : Array (String × String × Option String × Option Bool) :=
            raw.filterMap fun j =>
              if isInclusion j then
                match getField "userOpHash" j >>= asString,
                      getField "inclusionTxHash" j >>= asString with
                | some uoh, some itx =>
                    let blk := getField "blockNumber" j >>= asString
                    let succ : Option Bool := match getField "success" j with
                      | some (.bool b) => some b
                      | _ => none
                    some (uoh, itx, blk, succ)
                | _, _ => none
              else none
          let lookupInclusion (uoh : String) :
              Option (String × Option String × Option Bool) :=
            -- Reverse scan so the latest inclusion record wins.
            let rec go (i : Nat) : Option (String × Option String × Option Bool) :=
              if i = 0 then none
              else
                let j := i - 1
                if h : j < inclusionList.size then
                  let (k, itx, blk, succ) := inclusionList[j]
                  if k = uoh then some (itx, blk, succ) else go j
                else go j
            go inclusionList.size
          -- Walk entries; drop the bare inclusion records (they were
          -- consumed into the map) and decorate entries whose
          -- userOpHash matches.
          let decorated : Array Json := raw.filterMap fun j =>
            if isInclusion j then none
            else
              match getField "userOpHash" j >>= asString with
              | none => some j
              | some uoh =>
                  match lookupInclusion uoh with
                  | none => some j
                  | some (itx, blk?, succ?) =>
                      let base : Array (String × Json) := match j with
                        | .obj kvs => kvs
                        | _ => #[]
                      let withItx := base.push ("inclusionTxHash", .str itx)
                      let withBlk := match blk? with
                        | none => withItx
                        | some b => withItx.push ("inclusionBlockNumber", .str b)
                      let withSucc := match succ? with
                        | none => withBlk
                        | some s => withBlk.push ("inclusionSuccess", .bool s)
                      some (.obj withSucc)
          pure (.ok (.arr decorated))
  | "chain.scanTransfers" =>
      -- Why: chunked eth_getLogs. The 32-byte-padded address goes in topic1
      -- (out) and topic2 (in); two queries per chunk merged & deduped.
      match getField "addresses" req.params >>= asArray with
      | none => pure (.error invalidParams)
      | some arr =>
          -- Why: pick endpoint at call time so users can scan history on a
          -- chain other than the one the daemon's default RPC points at.
          -- Fail closed when the requested chain has no configured endpoint.
          let chain? := getField "chain" req.params >>= asString
          match endpointForChain cfg chain? with
          | .error msg =>
              pure (.error { code := -32602, message := msg, data := none })
          | .ok scanEndpoint =>
              let addresses := arr.filterMap asString
              let chunkSize ← do
                match getField "chunkSize" req.params >>= asNat with
                | some n => pure n
                | none =>
                    match ← IO.getEnv "KOHAKU_GETLOGS_MAX_BLOCK_SPAN" with
                    | some s => pure (s.toNat?.getD 5000)
                    | none => pure 5000
              let chainIdForScan :=
                ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
              let viaScan? ← colibriVia state chainIdForScan
              -- Resolve fromBlock/toBlock.
              let fromBlock ← do
                match getField "fromBlock" req.params >>= asNat with
                | some n => pure n
                | none => pure 0
              let toBlock ← do
                match getField "toBlock" req.params >>= asNat with
                | some n => pure n
                | none =>
                    match ← LeanKohaku.RPC.Outbound.blockNumber cfg.policy scanEndpoint viaScan? with
                    | .ok j =>
                        pure ((asString j >>= parseHexQuantity).getD 0)
                    | .error _ => pure 0
              let topic0 := "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
              let padAddr (a : String) : String :=
                let raw := stripHexPrefix a |>.toLower
                "0x" ++ String.ofList (List.replicate (64 - raw.length) '0') ++ raw
              -- Reset cancellation flag for this scan. Why: `chain.cancel`
              -- sets it to `true`; if a previous run set it and was never
              -- consumed, we'd abort before doing any work.
              LeanKohaku.Daemon.State.beginScan state
              -- Wall-clock cap: timeout is orthogonal to user-initiated cancel.
              -- Default 5 min; overridable via env or per-call `maxMs` param.
              -- Reject 0/negative — fall back to default to avoid an instantly
              -- expiring scan or a non-terminating loop on a parse error.
              let defaultMaxMs : Nat := 300000
              let envMaxMs : Nat ← do
                match ← IO.getEnv "KOHAKU_SCAN_MAX_MS" with
                | some s =>
                    match s.toNat? with
                    | some n => if n = 0 then pure defaultMaxMs else pure n
                    | none => pure defaultMaxMs
                | none => pure defaultMaxMs
              let maxMs : Nat :=
                match getField "maxMs" req.params >>= asNat with
                | some n => if n = 0 then envMaxMs else n
                | none => envMaxMs
              let started ← IO.monoMsNow
              let mut events : Array Json := #[]
              let mut seen : Array String := #[]
              let mut errAcc : Option String := none
              let mut cancelled : Bool := false
              let mut timedOut : Bool := false
              let mut lastScanned : Nat := fromBlock
              for addr in addresses do
                if cancelled || timedOut then pure ()
                else
                  let topicAddr := padAddr addr
                  let mut cur := fromBlock
                  -- Bound the chunk loop; chunkSize=0 would loop forever.
                  let span := if chunkSize = 0 then 5000 else chunkSize
                  let mut fuel := 5000
                  while cur ≤ toBlock && fuel > 0 && !cancelled && !timedOut do
                    let chunkTo := if cur + span > toBlock then toBlock else cur + span
                    let fromHex := natQuantityHex cur
                    let toHex := natQuantityHex chunkTo
                    -- Outbound (from = topic1)
                    let topicsOut : Array Json :=
                      #[.str topic0, .str topicAddr, .null]
                    -- Inbound (to = topic2)
                    let topicsIn : Array Json :=
                      #[.str topic0, .null, .str topicAddr]
                    for topicsArr in [topicsOut, topicsIn] do
                      if cancelled || timedOut then pure ()
                      else
                        -- Check cancel flag before each outbound call so the
                        -- second of the two queries can be skipped too.
                        if (← LeanKohaku.Daemon.State.isScanCancelled state) then
                          cancelled := true
                        else
                          match ← LeanKohaku.RPC.Outbound.call cfg.policy scanEndpoint
                              .getLogs (.arr #[.obj #[
                                ("fromBlock", .str fromHex),
                                ("toBlock", .str toHex),
                                ("topics", .arr topicsArr)
                              ]]) viaScan? with
                          | .error e => errAcc := some e
                          | .ok logsJson =>
                              match asArray logsJson with
                              | none => pure ()
                              | some logs =>
                                  for log in logs do
                                    let txHash := (getField "transactionHash" log >>= asString).getD ""
                                    let logIdx := (getField "logIndex" log >>= asString).getD ""
                                    let key := txHash ++ "#" ++ logIdx
                                    if seen.contains key then pure ()
                                    else
                                      seen := seen.push key
                                      events := events.push log
                    lastScanned := chunkTo
                    cur := chunkTo + 1
                    fuel := fuel - 1
                    -- Re-check after the chunk so the next chunk is skipped
                    -- promptly when cancellation arrives.
                    if !cancelled && (← LeanKohaku.Daemon.State.isScanCancelled state) then
                      cancelled := true
                    -- Wall-clock check: orthogonal to cancel; surfaces as
                    -- `timedOut` in the result so the CLI can prompt resume.
                    if !timedOut then
                      let nowMs ← IO.monoMsNow
                      if nowMs - started ≥ maxMs then
                        timedOut := true
              -- Persist last-scanned-block for at least one address (the first).
              -- If we cancelled mid-scan, persist the last fully-attempted
              -- chunk boundary so the next run can resume.
              let persistedTo :=
                if cancelled || timedOut then lastScanned else toBlock
              if let some firstSlot := getField "slotName" req.params >>= asString then
                LeanKohaku.Daemon.TxJournal.writeScanState firstSlot persistedTo
              let resultJson : Json := .obj #[
                ("events", .arr events),
                ("fromBlock", .num (Int.ofNat fromBlock)),
                ("toBlock", .num (Int.ofNat toBlock)),
                ("cancelled", .bool cancelled),
                ("timedOut", .bool timedOut),
                ("maxMs", .num (Int.ofNat maxMs)),
                ("lastScannedBlock", .num (Int.ofNat persistedTo))
              ]
              match errAcc with
              | none => pure (.ok resultJson)
              | some _ => pure (.ok resultJson)
  | "chain.cancel" =>
      -- Idempotent: signal any in-flight `chain.scanTransfers` to abort at
      -- the next chunk boundary. Safe to call when no scan is running.
      LeanKohaku.Daemon.State.cancelScan state
      pure <| .ok <| .obj #[("ok", .bool true)]
  | "chain.indexerHistory" =>
      -- Why: opt-in third-party history lookup. The daemon refuses unless
      -- the indexer is allow-listed in daemon.json, *and* the network
      -- policy permits indexerLookup. Strict mode rejects.
      match paramString req.params "address", paramString req.params "indexer" with
      | .ok address, .ok indexerName =>
          match cfg.indexers.find? (fun e => e.name = indexerName) with
          | none =>
              pure <| .error
                { code := -32030,
                  message := s!"indexer '{indexerName}' not enabled — run 'kohaku network allow-indexer {indexerName}'",
                  data := none }
          | some entry =>
              let polReq : NetworkRequest :=
                { peer := .thirdPartyApi, purpose := .indexerLookup,
                  transport := .direct }
              if !(cfg.policy polReq) then
                pure <| .error
                  { code := -32031,
                    message := "network policy denies indexer lookup (strict mode)",
                    data := none }
              else
                let envKey := "LEANKOHAKU_" ++ indexerName.toUpper ++ "_KEY"
                let apiKey ← IO.getEnv envKey
                let key := apiKey.getD ""
                let url1 := s!"{entry.url}?chainid={cfg.chainId}&module=account&action=txlist&address={address}&apikey={key}"
                let url2 := s!"{entry.url}?chainid={cfg.chainId}&module=account&action=tokentx&address={address}&apikey={key}"
                let fetch (u : String) : IO Json := do
                  try
                    let out ← IO.Process.output
                      { cmd := "curl", args := #["-sS", u] }
                    if out.exitCode != 0 then pure .null
                    else
                      match parse out.stdout with
                      | .ok j => pure j
                      | .error _ => pure .null
                  catch _ => pure .null
                let txList ← fetch url1
                let tokenTx ← fetch url2
                pure <| .ok <| .obj #[
                  ("indexer", .str indexerName),
                  ("address", .str address),
                  ("txlist", txList),
                  ("tokentx", tokenTx)
                ]
      | _, _ => pure (.error invalidParams)
  | "shielded.delete" =>
      match paramString req.params "passphrase" with
      | .error err => pure (.error err)
      | .ok passphrase =>
          if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
            pure (.error ppSecretMissing)
          else
            match ← LeanKohaku.Wallet.PpSecretStore.unlock passphrase with
            | .error err =>
                pure <| .error
                  { code := -32011, message := "PP secret unlock failed",
                    data := some (.str err) }
            | .ok _ =>
                LeanKohaku.Wallet.PpSecretStore.delete
                pure <| .ok <| .obj #[("ok", .bool true)]
  | "eoa.attestation.status" =>
      let initialized ← LeanKohaku.Keystore.MasterKey.existsOnDisk
      let names ← LeanKohaku.Wallet.EoaStore.list
      let entries ← names.foldlM
        (fun acc name => do
          match ← LeanKohaku.Wallet.EoaStore.load name with
          | .ok r =>
              pure <| acc.push <| .obj #[
                ("name", .str r.name),
                ("attestationWrapped", .bool r.attestationWrap.isSome)
              ]
          | .error _ => pure acc)
        (#[] : Array Json)
      pure <| .ok <| .obj #[
        ("initialized", .bool initialized),
        ("slots", .arr entries)
      ]
  | "eoa.attestation.bootstrap" =>
      match getField "slots" req.params >>= asArray,
            paramString req.params "masterPin" with
      | none, _ => pure (.error invalidParams)
      | _, .error err => pure (.error err)
      | some slotsArr, .ok masterPin =>
          -- Why: get/derive the master key once. If absent, bootstrap a new
          -- one (PIN-bound seal). Both paths verify the PIN through the TPM.
          let masterRes ← do
            if ← LeanKohaku.Keystore.MasterKey.existsOnDisk then
              LeanKohaku.Keystore.MasterKey.unsealMaster masterPin notify
            else
              match ← LeanKohaku.Keystore.MasterKey.bootstrap masterPin notify with
              | .error err => pure (.error err)
              | .ok _ => LeanKohaku.Keystore.MasterKey.unsealMaster masterPin notify
          match masterRes with
          | .error err =>
              pure <| .error
                { code := -32020, message := "master attestation key unavailable",
                  data := some (.str err) }
          | .ok masterKey =>
              let mut results : Array Json := #[]
              for entry in slotsArr do
                let nameOpt := getField "name" entry >>= asString
                let passOpt := getField "passphrase" entry >>= asString
                match nameOpt, passOpt with
                | some name, some passphrase =>
                    match ← LeanKohaku.Wallet.EoaStore.load name with
                    | .error err =>
                        results := results.push <| .obj #[
                          ("name", .str name), ("ok", .bool false),
                          ("error", .str err)]
                    | .ok record =>
                        match ← LeanKohaku.Wallet.EoaStore.unlockSeedIO record passphrase with
                        | .error err =>
                            results := results.push <| .obj #[
                              ("name", .str name), ("ok", .bool false),
                              ("error", .str s!"unlock failed: {err}")]
                        | .ok seed =>
                            match ← LeanKohaku.Wallet.EoaStore.wrapWithMaster masterKey name seed with
                            | .error err =>
                                results := results.push <| .obj #[
                                  ("name", .str name), ("ok", .bool false),
                                  ("error", .str s!"wrap failed: {err}")]
                            | .ok wrap =>
                                let updated := { record with attestationWrap := some wrap }
                                LeanKohaku.Wallet.EoaStore.save updated
                                results := results.push <| .obj #[
                                  ("name", .str name), ("ok", .bool true)]
                | _, _ =>
                    results := results.push <| .obj #[
                      ("name", .str (nameOpt.getD "")), ("ok", .bool false),
                      ("error", .str "missing name or passphrase")]
              pure <| .ok <| .obj #[("results", .arr results)]
  | "eoa.attestation.unlockAll" =>
      match paramString req.params "masterPin" with
      | .error err => pure (.error err)
      | .ok masterPin =>
      match ← LeanKohaku.Keystore.MasterKey.unsealMaster masterPin notify with
      | .error err =>
          pure <| .error
            { code := -32020, message := "master attestation key unavailable",
              data := some (.str err) }
      | .ok masterKey =>
          let names ← LeanKohaku.Wallet.EoaStore.list
          let mut unlocked : Array Json := #[]
          let mut skipped : Array Json := #[]
          for name in names do
            match ← LeanKohaku.Wallet.EoaStore.load name with
            | .error err =>
                skipped := skipped.push <| .obj #[
                  ("name", .str name), ("reason", .str err)]
            | .ok record =>
                match record.attestationWrap with
                | none =>
                    skipped := skipped.push <| .obj #[
                      ("name", .str name), ("reason", .str "no-wrap")]
                | some wrap =>
                    match ← LeanKohaku.Wallet.EoaStore.unwrapWithMaster masterKey name wrap with
                    | .error err =>
                        skipped := skipped.push <| .obj #[
                          ("name", .str name), ("reason", .str err)]
                    | .ok seed =>
                        LeanKohaku.Daemon.State.unlock state {
                          name := record.name,
                          seed := seed,
                          address := record.address,
                          derivationPath := record.derivationPath,
                          unlockedAtMs := ← IO.monoMsNow,
                          ttlMs := 300000
                        }
                        unlocked := unlocked.push (.str name)
          pure <| .ok <| .obj #[
            ("unlocked", .arr unlocked),
            ("skipped", .arr skipped)
          ]
  | "wallet.master.status" =>
      -- Why: lightweight status probe used by CLI / TUI to decide whether
      -- to prompt for the master passphrase vs. fall back to per-slot
      -- unlock. Reads the manifest if present; lists EOAs by enrolment
      -- bucket so the front-end can surface "X slots not yet enrolled".
      let initialized ← LeanKohaku.Keystore.MasterPassphrase.existsOnDisk
      let tpmEnrolled ← LeanKohaku.Keystore.MasterKey.existsOnDisk
      let tpmHardwareReady ← LeanKohaku.Keystore.MasterKey.hardwareReady
      let manifest? ←
        if initialized then
          (do
            match ← LeanKohaku.Keystore.MasterPassphrase.loadManifest with
            | .ok m => pure (some m)
            | .error _ => pure none)
        else pure none
      let withTpm := match manifest? with
        | some m => m.tpmWrap.isSome
        | none => false
      let masterUnlocked := (← LeanKohaku.Daemon.State.getMasterKek? state).isSome
      let names ← LeanKohaku.Wallet.EoaStore.list
      let mut enrolled : Array Json := #[]
      let mut unenrolled : Array Json := #[]
      let mut custom : Array Json := #[]
      for name in names do
        match ← LeanKohaku.Wallet.EoaStore.load name with
        | .error _ => pure ()
        | .ok rec =>
            if rec.customPassphrase then
              custom := custom.push (.str name)
            else if rec.masterWrap.isSome then
              enrolled := enrolled.push (.str name)
            else
              unenrolled := unenrolled.push (.str name)
      let ttlMs : Nat := match manifest? with
        | some m => m.ttlMs
        | none => 0
      pure <| .ok <| .obj #[
        ("initialized", .bool initialized),
        ("withTpm", .bool withTpm),
        -- Why: split TPM state into "hardware reachable" vs "master key
        -- already bootstrapped". The CLI cares about hardware-ready at
        -- init time (offer PIN prompt) and enrolment at unlock time
        -- (route through the TPM path). `tpmAvailable` keeps the old
        -- name for back-compat with clients written against the
        -- previous schema.
        ("tpmHardwareReady", .bool tpmHardwareReady),
        ("tpmAvailable", .bool tpmEnrolled),
        ("masterUnlocked", .bool masterUnlocked),
        ("ttlMs", .num (Int.ofNat ttlMs)),
        ("enrolledEoas", .arr enrolled),
        ("unenrolledEoas", .arr unenrolled),
        ("customEoas", .arr custom)
      ]
  | "wallet.master.init" =>
      -- Why: bootstrap the master KEK manifest. Single-credential UX —
      -- callers always supply `passphrase` (the recovery / no-TPM fallback)
      -- and OPTIONALLY supply `masterPin`. Presence of a non-empty
      -- `masterPin` plus a usable TPM triggers a TPM envelope on the same
      -- KEK; absence is fine and yields a passphrase-only manifest. TPM
      -- failures during init are logged and reported but DO NOT fail the
      -- init — the passphrase wrap is always written.
      match paramString req.params "passphrase" with
      | .error err => pure (.error err)
      | .ok passphrase =>
          if (← LeanKohaku.Keystore.MasterPassphrase.existsOnDisk) then
            pure <| .error { code := -32030, message := "wallet master already initialized", data := none }
          else
            let timeoutMins : Nat := (getField "timeoutMins" req.params >>= asNat).getD 5
            let ttlMs : Nat := if timeoutMins == 0 then 0 else timeoutMins * 60000
            let masterPin? : Option String := getField "masterPin" req.params >>= asString
            let pinPresent : Bool := match masterPin? with
              | some p => !p.isEmpty
              | none => false
            -- Resolve a TPM key only when (a) caller supplied a PIN, AND
            -- (b) hardware looks usable. Both gates avoid running tpm2
            -- tools on hosts without /dev/tpm or tpm2-tools installed.
            let mut tpmKey? : Option ByteArray := none
            let mut tpmNote : Option String := none
            if pinPresent then
              if !(← LeanKohaku.Keystore.MasterKey.hardwareReady) then
                tpmNote := some "TPM hardware not available; falling back to passphrase-only"
              else
                let pin := masterPin?.getD ""
                let res ←
                  if ← LeanKohaku.Keystore.MasterKey.existsOnDisk then
                    LeanKohaku.Keystore.MasterKey.unsealMaster pin notify
                  else
                    match ← LeanKohaku.Keystore.MasterKey.bootstrap pin notify with
                    | .error e => pure (.error e)
                    | .ok _ => LeanKohaku.Keystore.MasterKey.unsealMaster pin notify
                match res with
                | .ok k => tpmKey? := some k
                | .error e => tpmNote := some s!"TPM bind failed: {e}"
            match ← LeanKohaku.Keystore.MasterPassphrase.buildManifest passphrase tpmKey? ttlMs (← IO.monoMsNow) with
            | .error err =>
                pure <| .error { code := -32031, message := "failed to build master manifest", data := some (.str err) }
            | .ok (manifest, kek) =>
                LeanKohaku.Keystore.MasterPassphrase.saveManifest manifest
                LeanKohaku.Daemon.State.unlockMaster state {
                  kek := kek,
                  unlockedAtMs := ← IO.monoMsNow,
                  ttlMs := manifest.ttlMs
                }
                let base : Array (String × Json) := #[
                  ("initialized", .bool true),
                  ("withTpm", .bool manifest.tpmWrap.isSome),
                  ("masterUnlocked", .bool true),
                  ("ttlMs", .num (Int.ofNat manifest.ttlMs))
                ]
                let fields : Array (String × Json) :=
                  match tpmNote with
                  | none => base
                  | some n => base.push ("note", .str n)
                pure <| .ok <| .obj fields
  | "wallet.unlock" =>
      -- Why: master-passphrase or TPM-PIN path. Either credential decrypts
      -- the wallet KEK; the KEK then unwraps every enrolled EOA slot in
      -- one shot. Slots with no `masterWrap` (legacy or custom) are
      -- reported as `skipped` so the front-end can re-prompt per-slot.
      if !(← LeanKohaku.Keystore.MasterPassphrase.existsOnDisk) then
        pure <| .error { code := -32032, message := "wallet master not initialized — run `wallet.master.init` first", data := none }
      else
        match ← LeanKohaku.Keystore.MasterPassphrase.loadManifest with
        | .error err =>
            pure <| .error { code := -32033, message := "master manifest is corrupt", data := some (.str err) }
        | .ok manifest =>
            let passphrase? : Option String := getField "passphrase" req.params >>= asString
            let masterPin? : Option String := getField "masterPin" req.params >>= asString
            let kekRes ←
              match passphrase?, masterPin? with
              | some p, _ =>
                  LeanKohaku.Keystore.MasterPassphrase.unlockWithPassphrase manifest p
              | none, some pin =>
                  if !manifest.tpmWrap.isSome then
                    pure (.error "this wallet manifest has no tpmWrap; use `passphrase` instead")
                  else
                    match ← LeanKohaku.Keystore.MasterKey.unsealMaster pin notify with
                    | .error e => pure (.error e)
                    | .ok tpmKey =>
                        LeanKohaku.Keystore.MasterPassphrase.unlockWithTpmKey manifest tpmKey
              | none, none =>
                  pure (.error "supply either `passphrase` or `masterPin`")
            match kekRes with
            | .error err =>
                pure <| .error { code := -32034, message := "wallet unlock failed", data := some (.str err) }
            | .ok kek =>
                let ttlMs := manifest.ttlMs
                LeanKohaku.Daemon.State.unlockMaster state {
                  kek := kek,
                  unlockedAtMs := ← IO.monoMsNow,
                  ttlMs := ttlMs
                }
                -- Iterate enrolled EOA slots; populate per-slot unlock state.
                let names ← LeanKohaku.Wallet.EoaStore.list
                let mut enrolled : Array Json := #[]
                let mut skipped : Array Json := #[]
                for name in names do
                  match ← LeanKohaku.Wallet.EoaStore.load name with
                  | .error e =>
                      skipped := skipped.push <| .obj #[
                        ("name", .str name), ("reason", .str e)]
                  | .ok rec =>
                      if rec.customPassphrase then
                        skipped := skipped.push <| .obj #[
                          ("name", .str name), ("reason", .str "custom-passphrase")]
                      else
                        match rec.masterWrap with
                        | none =>
                            skipped := skipped.push <| .obj #[
                              ("name", .str name), ("reason", .str "not-enrolled")]
                        | some w =>
                            match ← LeanKohaku.Keystore.MasterPassphrase.unwrapSlot
                                kek rec.name rec.derivationPath rec.address w with
                            | .error _ =>
                                -- Why: the verifier above already proved
                                -- the typed credential matches the manifest.
                                -- If `unwrapSlot` still fails, the slot's
                                -- `masterWrap` was made under a different
                                -- (now-discarded) KEK — usually because the
                                -- user wiped `wallet/master.json` and
                                -- re-init'd. Surface as `stale-wrap` with
                                -- a clear next-step hint; one
                                -- `kohaku wallet enroll <name>` rewrites
                                -- the wrap under the current KEK.
                                skipped := skipped.push <| .obj #[
                                  ("name", .str name),
                                  ("reason", .str "stale-wrap"),
                                  ("hint", .str s!"run `kohaku wallet enroll {name}` to re-enrol this slot under the current master KEK")]
                            | .ok seed =>
                                LeanKohaku.Daemon.State.unlock state {
                                  name := rec.name,
                                  seed := seed,
                                  address := rec.address,
                                  derivationPath := rec.derivationPath,
                                  unlockedAtMs := ← IO.monoMsNow,
                                  ttlMs := ttlMs
                                }
                                enrolled := enrolled.push (.str name)
                pure <| .ok <| .obj #[
                  ("masterUnlocked", .bool true),
                  ("enrolled", .arr enrolled),
                  ("skipped", .arr skipped),
                  ("ttlMs", .num (Int.ofNat ttlMs))
                ]
  | "wallet.lock" =>
      -- Why: one-shot clear of every credential held in memory. Tears down
      -- per-slot unlocks AND the master KEK in a single state-modify so
      -- there is no instant where the master is gone but slot seeds linger.
      LeanKohaku.Daemon.State.lockAll state
      pure <| .ok <| .obj #[("locked", .bool true)]
  | "wallet.master.bindTpm" =>
      -- Why: post-init TPM binding. Wraps the existing wallet KEK under
      -- the TPM-sealed master key so future unlocks can come through the
      -- TPM PIN path. Two ways to obtain the KEK:
      --   (a) the daemon already has it loaded (caller previously ran
      --       `wallet.unlock`) — preferred, no passphrase prompt.
      --   (b) the caller supplies `passphrase` and we re-derive it from
      --       the manifest's `passphraseWrap`.
      -- TPM master key is bootstrapped if absent. PIN events flow through
      -- the standard `notify` channel (`pin-required`, `pin-success`,
      -- `pin-auth-failed`, `pin-locked-out`).
      if !(← LeanKohaku.Keystore.MasterPassphrase.existsOnDisk) then
        pure <| .error { code := -32032, message := "wallet master not initialized", data := none }
      else
        match ← LeanKohaku.Keystore.MasterPassphrase.loadManifest with
        | .error err =>
            pure <| .error { code := -32033, message := "master manifest is corrupt", data := some (.str err) }
        | .ok manifest =>
            match paramString req.params "masterPin" with
            | .error err => pure (.error err)
            | .ok pin =>
                -- Resolve the KEK: in-memory first, else derive from passphrase.
                let kekRes ← do
                  match ← LeanKohaku.Daemon.State.getMasterKek? state with
                  | some slot => pure (.ok slot.kek)
                  | none =>
                      match getField "passphrase" req.params >>= asString with
                      | none =>
                          pure (.error "wallet locked — provide `passphrase` or run `wallet.unlock` first")
                      | some p =>
                          LeanKohaku.Keystore.MasterPassphrase.unlockWithPassphrase manifest p
                match kekRes with
                | .error err =>
                    pure <| .error { code := -32034, message := "wallet KEK unavailable", data := some (.str err) }
                | .ok kek =>
                    -- Get the TPM master key (bootstrap if missing).
                    let tpmRes ←
                      if ← LeanKohaku.Keystore.MasterKey.existsOnDisk then
                        LeanKohaku.Keystore.MasterKey.unsealMaster pin notify
                      else
                        match ← LeanKohaku.Keystore.MasterKey.bootstrap pin notify with
                        | .error e => pure (.error e)
                        | .ok _ => LeanKohaku.Keystore.MasterKey.unsealMaster pin notify
                    match tpmRes with
                    | .error err =>
                        pure <| .error { code := -32020, message := "TPM master key unavailable", data := some (.str err) }
                    | .ok tpmKey =>
                        match ← LeanKohaku.Keystore.MasterPassphrase.addTpmWrap manifest kek tpmKey with
                        | .error err =>
                            pure <| .error { code := -32031, message := "failed to bind TPM wrap", data := some (.str err) }
                        | .ok updated =>
                            LeanKohaku.Keystore.MasterPassphrase.saveManifest updated
                            pure <| .ok <| .obj #[
                              ("withTpm", .bool true),
                              ("tpmAvailable", .bool true)
                            ]
  | "wallet.master.setTimeout" =>
      -- Why: update the persisted auto-lock TTL without re-typing the
      -- master passphrase. Rewrites `master.json` in place; the next
      -- `wallet.unlock` will pick up the new TTL. `timeoutMins == 0`
      -- disables auto-lock (slot lives until explicit `wallet.lock`).
      match getField "timeoutMins" req.params >>= asNat with
      | none =>
          pure <| .error { code := -32602, message := "timeoutMins required", data := none }
      | some mins =>
          if !(← LeanKohaku.Keystore.MasterPassphrase.existsOnDisk) then
            pure <| .error { code := -32032, message := "wallet master not initialized", data := none }
          else
            match ← LeanKohaku.Keystore.MasterPassphrase.loadManifest with
            | .error err =>
                pure <| .error { code := -32033, message := "master manifest is corrupt", data := some (.str err) }
            | .ok m =>
                let newTtl : Nat := if mins == 0 then 0 else mins * 60000
                let updated := { m with ttlMs := newTtl }
                LeanKohaku.Keystore.MasterPassphrase.saveManifest updated
                pure <| .ok <| .obj #[("ttlMs", .num (Int.ofNat newTtl))]
  | "wallet.lean_verified_addresses" =>
      -- Phase 1d: trusted-registry RPC. Returns the BIP-44-derived
      -- addresses for currently-unlocked seeds, plus any TPM-backed R1
      -- accounts. Read-only; no chain I/O. See
      -- `docs/PHASE1D_THREAT_MODEL.md` for the full threat model.
      --
      -- Params (all optional):
      --   paths      : Array String — defaults to ["m/44'/60'/0'/0", "m/44'/60'/0'/1"]
      --                Anything outside that allowlist is rejected
      --                with `bad_path` (no arbitrary BIP-32 walks).
      --   count      : Nat — per-path enumeration window; clamped to
      --                `cfg.trustedRegistryMaxPerPath` (default 5).
      --                Clamped silently, not errored — see threat 2.
      --   includeR1  : Bool — default true. When false, omits TPM-
      --                backed R1 entries.
      --
      -- Failure modes documented in the threat model:
      --   `locked`     — no seeds unlocked
      --   `bad_path`   — caller asked for a non-allowlisted prefix
      --
      -- The handler must NOT touch any signing primitive, must NOT
      -- call out to a node, and must NOT export private keys.
      let allowedPrefixes : List String :=
        ["m/44'/60'/0'/0", "m/44'/60'/0'/1"]
      let defaultPaths : Array String :=
        #["m/44'/60'/0'/0", "m/44'/60'/0'/1"]
      let paths : Array String :=
        match getField "paths" req.params with
        | some (.arr arr) => arr.filterMap (fun j => asString j)
        | _ => defaultPaths
      let requestedCount := paramNatD req.params "count" 5
      let count := min requestedCount cfg.trustedRegistryMaxPerPath
      let includeR1 :=
        match getField "includeR1" req.params >>= asBool with
        | some b => b
        | none => true
      -- Path-allowlist gate (threat 4).
      let badPath? : Option String :=
        paths.toList.find? (fun p => !(allowedPrefixes.contains p))
      match badPath? with
      | some bp =>
          pure <| .ok <| .obj #[
            ("ok", .bool false),
            ("error", .obj #[
              ("kind", .str "bad_path"),
              ("msg",  .str s!"path '{bp}' is not in the allowlist")
            ])
          ]
      | none =>
      let unlockedSlots ← LeanKohaku.Daemon.State.unlockedNames state
      -- Locked-seed gate (threat 3). The threat-model contract is
      -- explicit: when no BIP-44 seed is unlocked we return `locked`
      -- **regardless** of whether the keystore has TPM-backed R1
      -- entries on disk. Reasons:
      --   • The prompt's "Trusted Registry" header tells the LLM the
      --     list is "from your seed"; rendering only R1 entries under
      --     that header would be misleading.
      --   • The user has not authorized address disclosure for this
      --     session; the unlock event is what gates that.
      --   • R1-only registries are still served separately via
      --     `account.list`; this RPC is the seed-anchored surface.
      if unlockedSlots.isEmpty then
        pure <| .ok <| .obj #[
          ("ok", .bool false),
          ("error", .obj #[
            ("kind", .str "locked"),
            ("msg",  .str "no seeds unlocked; run wallet.unlock or eoa.unlock first")
          ])
        ]
      else
      -- Resolve actual slot records (skip silently if expired between
      -- the name fetch and the slot fetch — TTL races are not errors).
      let mut entries : Array Json := #[]
      let mut storedAddrs : Array String := #[]
      let mut fingerprints : Array String := #[]
      -- 1. Stored-accounts walk. Once *some* seed is unlocked the user
      --    has authorized address disclosure for this session, so every
      --    on-disk EoaStore slot's already-realized sub-accounts (the
      --    `Record.accounts` array) become visible — these are the
      --    wallets the user creates and references by name from the CLI
      --    / TUI (e.g. "leanWallet/fresh1"). Locked slots are included
      --    with `unlocked:false` so the agent knows it can't sign with
      --    them yet; addresses themselves are public, the secret is the
      --    seed. Labelled accounts win deduplication against the BIP-44
      --    enumeration below.
      let allEoaNames ← LeanKohaku.Wallet.EoaStore.list
      for name in allEoaNames do
        match ← LeanKohaku.Wallet.EoaStore.load name with
        | .error _ => pure ()
        | .ok rec =>
            let isUnlocked := (← LeanKohaku.Daemon.State.getUnlocked? state name).isSome
            for acct in rec.accounts do
              let baseFields : Array (String × Json) := #[
                ("kind",     .str "eoa"),
                ("slot",     .str name),
                ("path",     .str acct.path),
                ("address",  .str acct.address),
                ("unlocked", .bool isUnlocked)
              ]
              let fields : Array (String × Json) :=
                match acct.label with
                | some l => baseFields.push ("label", .str l)
                | none   => baseFields
              entries := entries.push (.obj fields)
              storedAddrs := storedAddrs.push acct.address.toLower
      -- 2. Per-seed BIP-44 enumeration (unlocked slots only). Skips any
      --    address already surfaced by the stored-accounts walk so a
      --    labelled sub-account always wins over its bare derived twin.
      for name in unlockedSlots do
        match ← LeanKohaku.Daemon.State.getUnlocked? state name with
        | none => pure ()
        | some slot =>
            -- Per-slot fingerprint (best-effort; failure is non-fatal).
            match ← seedFingerprintFromSeed slot.seed with
            | .ok fp => fingerprints := fingerprints.push fp
            | .error _ => pure ()
            -- For each allowlisted prefix the user asked about,
            -- enumerate `count` indices.
            for pathPrefix in paths do
              for i in [0:count] do
                let path := s!"{pathPrefix}/{i}"
                match ← deriveAddressFromSeed slot.seed path with
                | .error _ => pure ()  -- skip — malformed path or deriver hiccup
                | .ok address =>
                    if storedAddrs.contains address.toLower then
                      pure ()  -- already surfaced (with label) by the stored walk
                    else
                      entries := entries.push <| .obj #[
                        ("kind",     .str "eoa"),
                        ("slot",     .str name),
                        ("path",     .str path),
                        ("address",  .str address),
                        ("unlocked", .bool true)
                      ]
      -- 3. SPHINCS-hybrid 4337 smart-account records (`kind:"sphincs"`).
      --    The user controls these via a hybrid ECDSA+SPHINCS+ owner; the
      --    smart-account address is the CREATE2-derived contract that
      --    holds the funds. Records without a computed
      --    `smartAccountAddress` are skipped (factory not yet wired up
      --    for that paramSet/chain). Enumeration failure is non-fatal —
      --    we still want EOA + R1 entries to land.
      try
        let sphincsNames ← LeanKohaku.Wallet.SphincsHybridStore.listSlotNames
        for sname in sphincsNames do
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord sname with
          | .error _ => pure ()
          | .ok rec =>
              match rec.smartAccountAddress with
              | none => pure ()
              | some sa =>
                  entries := entries.push <| .obj #[
                    ("kind",                .str "sphincs"),
                    ("slot",                .str sname),
                    ("paramSet",            .str rec.paramSet.toString),
                    ("chainId",             .num (Int.ofNat rec.chainId)),
                    ("ownerAddress",        .str rec.ownerAddress),
                    ("smartAccountAddress", .str sa),
                    ("address",             .str sa)
                  ]
      catch _ => pure ()
      -- 4. Optionally include R1 entries from the TPM keystore — only
      -- now that we know at least one seed is unlocked, so the user
      -- has authorized disclosure. Uses the same enumeration path as
      -- `account.list`; no new keystore API.
      if includeR1 then
        try
          let tpmNames ← listSepoliaKeys
          let stateDir : System.FilePath := ".leankohaku/keystore/tpm2"
          for name in tpmNames do
            let addrFile := stateDir / name / "r1-account-address.txt"
            if ← addrFile.pathExists then
              let raw ← IO.FS.readFile addrFile
              let addr := raw.trimAscii.toString
              if !addr.isEmpty then
                entries := entries.push <| .obj #[
                  ("kind",         .str "r1"),
                  ("credentialId", .str name),
                  ("address",      .str addr)
                ]
        catch _ => pure ()  -- TPM listing failure is non-fatal
      -- Combine fingerprints into a single stable string. If multiple
      -- seeds are unlocked simultaneously the registry shows all of
      -- their fingerprints joined by ","; rotation of any one will
      -- change the joined string.
      let combinedFp : String :=
        if fingerprints.isEmpty then ""
        else String.intercalate "," fingerprints.toList
      pure <| .ok <| .obj #[
        ("ok",              .bool true),
        ("addresses",       .arr entries),
        ("count",           .num (Int.ofNat entries.size)),
        ("seedFingerprint", .str combinedFp)
      ]
  | _ =>
      pure (.error methodNotFound)

private def ensureParentDir (socketPath : String) : IO Unit := do
  let path : System.FilePath := socketPath
  match path.parent with
  | some parent => IO.FS.createDirAll parent
  | none => pure ()

private def listenerFromSocketActivation? : IO (Option LeanKohaku.Daemon.Uds.Listener) := do
  if ← socketActivated then
    pure (some { fd := 3 })
  else
    pure none

private def decodeRequestBytes (bytes : ByteArray) : Except String String :=
  match String.fromUTF8? bytes with
  | some s => .ok s.trimAscii.toString
  | none => .error "request was not valid UTF-8"

/-- Body of `handleConn` — all the request reading and dispatch.
    Extracted so it can be wrapped in a `try/catch` that converts
    any escaping IO error into a JSON-RPC error frame written on
    the connection. -/
private def handleConnBody (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (conn : LeanKohaku.Daemon.Uds.Conn) : IO Unit := do
  let started ← IO.monoMsNow
  let sameUid ← LeanKohaku.Daemon.Uds.peerUidMatchesCurrent conn
  if !sameUid then
    let response := compact <| errorResponse .null
      { code := -32001, message := "peer uid rejected" }
    discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
    LeanKohaku.Daemon.Log.write .warn "<peer>" ((← IO.monoMsNow) - started) false
      (some "peer uid rejected")
  else
    -- `readLine` buffers across SOCK_STREAM `read(2)` chunks until
    -- the terminating `\n`, so a request the kernel splits doesn't
    -- truncate into a parse error here.
    let bytes ← LeanKohaku.Daemon.Uds.readLine conn
    match decodeRequestBytes bytes with
    | .error err =>
        let response := compact <| errorResponse .null
          { parseError with data := some (.str err) }
        discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
        LeanKohaku.Daemon.Log.write .warn "<parse>" ((← IO.monoMsNow) - started) false
          (some err)
    | .ok line =>
        let parsed := LeanKohaku.RPC.Server.parseRequest line
        let method :=
          match parsed with
          | .ok req => req.method
          | .error _ => "<parse>"
        -- UDS-backed notifier: emit JSON-RPC notification frames
        -- (no `id`, no `result`/`error`) on the same connection
        -- before the final response. The CLI client buffers and
        -- splits on `\n`, rendering each notification before
        -- returning the response.
        let notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier :=
          fun event params => do
            let frame : Json := .obj #[
              ("jsonrpc", .str "2.0"),
              ("method", .str "notify"),
              ("params", .obj #[
                ("event", .str event),
                ("data", params)
              ])
            ]
            try
              discard <| LeanKohaku.Daemon.Uds.write conn (compact frame ++ "\n").toByteArray
            catch _ => pure ()
        let response ←
          match parsed with
          | .error err => pure (compact <| errorResponse .null err)
          | .ok req => do
              -- Idle-TTL refresh: any well-formed RPC counts as user
              -- activity, so the master KEK + per-slot unlocks behave
              -- as an idle timeout (lock after `ttlMs` of true
              -- silence) rather than an absolute timeout from
              -- unlock. See `State.touchActivity` for rationale.
              LeanKohaku.Daemon.State.touchActivity state
              let json ← LeanKohaku.RPC.Server.dispatch (methodHandler cfg state notify) req
              pure (compact json)
        discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
        LeanKohaku.Daemon.Log.write .info method ((← IO.monoMsNow) - started) true

/-- Handle one wallet-daemon connection.

    The dispatch path is wrapped in a `try/catch` that always
    delivers a JSON-RPC error frame even when a handler raises an
    IO error past its own catch (FFI panic, untranslated `throw`,
    etc.). Without this arm the peer would observe a closed socket
    and surface the failure on the client as `unexpected end of
    JSON input` rather than a structured `-32603` envelope. -/
def handleConn (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (conn : LeanKohaku.Daemon.Uds.Conn) : IO Unit := do
  let recover (e : IO.Error) : IO Unit := do
    IO.eprintln s!"[daemon] handleConn raised, returning -32603: {toString e}"
    try
      let response := compact <| errorResponse .null
        { code := -32603, message := s!"internal error: {toString e}" }
      discard <| LeanKohaku.Daemon.Uds.write conn (response ++ "\n").toByteArray
    catch _ => pure ()
  let body : IO Unit := do
    try
      handleConnBody cfg state conn
    catch e =>
      recover e
  try
    body
  finally
    LeanKohaku.Daemon.Uds.close conn

partial def acceptLoop (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (listener : LeanKohaku.Daemon.Uds.Listener) : IO Unit := do
  let conn ← LeanKohaku.Daemon.Uds.accept listener
  discard <| IO.asTask (handleConn cfg state conn)
  if !(← LeanKohaku.Daemon.State.isShuttingDown state) then
    acceptLoop cfg state listener

/-- Probe the configured socket to detect whether another daemon is already
    listening on it.

    Returns:
    * `some "already running"` — connect succeeded and a `daemon.ping` round-trip
      either completed within the timeout, or the read window elapsed without
      the peer hanging up. Either way, *something* owns the socket and is
      accepting connections, so we must not start a second instance.
    * `none` — no live daemon (no socket file, or stale socket file removed).

    The probe is bounded to ~250 ms so a half-dead peer cannot stall startup.
    Stale socket files (connect fails with ENOENT or ECONNREFUSED but the path
    still exists / does not exist) are handled by inspecting `pathExists` after
    a connect failure: if the path exists, the file is stale and we remove it. -/
private def detectExistingDaemon (path : String) : IO (Option String) := do
  -- Try to connect. A successful connect means *some* listener is bound.
  let connAttempt ← IO.asTask (LeanKohaku.Daemon.Uds.connect path)
  -- We don't want to block forever on a wedged accept(); 250 ms cap.
  let connResult ← (do
    let mut waited : Nat := 0
    let step : Nat := 25
    let cap : Nat := 250
    let mut done : Option (Except IO.Error LeanKohaku.Daemon.Uds.Conn) := none
    while waited < cap && done.isNone do
      match ← IO.getTaskState connAttempt with
      | .finished =>
          done := some connAttempt.get
      | _ =>
          IO.sleep step.toUInt32
          waited := waited + step
    pure done)
  match connResult with
  | none =>
      -- connect() still pending after 250 ms — assume something is bound but
      -- wedged; refuse to start a second instance rather than racing.
      pure (some "already running (probe timed out)")
  | some (.error _) =>
      -- ECONNREFUSED / ENOENT both surface as IO errors here. Distinguish via
      -- the filesystem: if the path exists, the file is a stale leftover.
      let fp : System.FilePath := path
      if ← fp.pathExists then
        IO.eprintln s!"leankohaku-daemon: removed stale socket {path}"
        try IO.FS.removeFile path catch _ => pure ()
      pure none
  | some (.ok conn) =>
      -- Live listener accepted us. Send a daemon.ping and look for any reply,
      -- but don't block startup if the peer is slow — receiving the connect()
      -- alone is already proof of a competing daemon.
      let pingFrame :=
        "{\"jsonrpc\":\"2.0\",\"method\":\"daemon.ping\",\"params\":[],\"id\":1}\n"
      try
        discard <| LeanKohaku.Daemon.Uds.write conn pingFrame.toByteArray
      catch _ => pure ()
      let readTask ← IO.asTask (LeanKohaku.Daemon.Uds.read conn)
      let mut waited : Nat := 0
      let step : Nat := 25
      let cap : Nat := 250
      while waited < cap do
        match ← IO.getTaskState readTask with
        | .finished => waited := cap
        | _ =>
            IO.sleep step.toUInt32
            waited := waited + step
      try LeanKohaku.Daemon.Uds.close conn catch _ => pure ()
      pure (some "already running")

/-- Native helper binaries the daemon shells out to for every wallet op
    (PBKDF2 / HMAC / ChaCha20-Poly1305 / Keccak / secp256k1 sign+recover).
    They are produced by `script/setup_hacl.sh` and
    `script/setup_secp256k1.sh`, NOT by `lake build`, so a tree built
    with `lake build` alone is missing them and every unlock fails with
    a generic `could not execute external process` mid-flow. The boot
    precheck below stats each and refuses to listen if any are absent. -/
private def requiredNativeHelpers : Array String := #[
  LeanKohaku.Crypto.Hacl.helperKeccak,
  LeanKohaku.Crypto.Hacl.helperSha256,
  LeanKohaku.Crypto.Hacl.helperHmacSha256,
  LeanKohaku.Crypto.Hacl.helperHmacSha512,
  LeanKohaku.Crypto.Hacl.helperRipemd160,
  LeanKohaku.Crypto.Hacl.helperPbkdf2,
  LeanKohaku.Crypto.Hacl.helperHmacDrbg,
  LeanKohaku.Crypto.Hacl.helperChacha20Poly1305,
  LeanKohaku.Crypto.Secp256k1Native.helperSign,
  LeanKohaku.Crypto.Secp256k1Native.helperPubkey,
  LeanKohaku.Crypto.Secp256k1Native.helperRecover,
  LeanKohaku.Crypto.Secp256k1Native.helperVerify
]

/-- Resolve a helper basename the same way `runHexHelper` does at run
    time: prefer `IO.appDir / cmd` (so a daemon shipped via kohakuspawn
    symlinks resolves through `/proc/self/exe`), fall back to a `$PATH`
    lookup. Returns the absolute path when found. -/
private def locateHelper (cmd : String) : IO (Option String) := do
  let appDirHit ← try
    let next := (← IO.appDir) / cmd
    if ← next.pathExists then pure (some next.toString) else pure none
  catch _ => pure none
  match appDirHit with
  | some p => pure (some p)
  | none =>
      -- Fall back to $PATH. `IO.Process.output` with `cmd := basename`
      -- would do the lookup itself but we want to detect absence here.
      match ← IO.getEnv "PATH" with
      | none => pure none
      | some pathStr =>
          let dirs := pathStr.splitOn ":"
          let rec scan : List String → IO (Option String)
            | [] => pure none
            | d :: rest => do
                if d.isEmpty then scan rest
                else
                  let candidate := (System.FilePath.mk d) / cmd
                  if ← candidate.pathExists then pure (some candidate.toString)
                  else scan rest
          scan dirs

/-- Boot-time precheck. Lists every missing native helper, prints one
    actionable block to stderr naming the recovery command, and exits
    with code 70 (EX_SOFTWARE) — distinct from the second-instance exit
    (code 0) so systemd / kohakuspawn can tell the cases apart.

    The check runs after the second-instance guard so a healthy peer
    can keep serving even on a tree whose helpers were just nuked.

    Escape hatch: `KOHAKU_SKIP_HELPER_CHECK=1` downgrades to a single
    warning line. Intended for CI / smoke tests that exercise non-crypto
    code paths (locked-seed replies, RPC framing) on hosts that don't
    build the helpers. Never set this for an interactive daemon. -/
private def verifyNativeHelpersOrExit : IO Unit := do
  let mut missing : Array String := #[]
  for cmd in requiredNativeHelpers do
    match ← locateHelper cmd with
    | some _ => pure ()
    | none   => missing := missing.push cmd
  if missing.isEmpty then return ()
  match ← IO.getEnv "KOHAKU_SKIP_HELPER_CHECK" with
  | some "1" | some "true" | some "yes" =>
      IO.eprintln
        s!"leankohaku-daemon: KOHAKU_SKIP_HELPER_CHECK=1 — \
          continuing despite {missing.size} missing native helper(s); \
          signing/unlock will fail at use time"
      return ()
  | _ => pure ()
  let appDir ← try
    let d ← IO.appDir
    pure d.toString
  catch _ => pure "(unknown)"
  IO.eprintln "leankohaku-daemon: missing native crypto helpers — refusing to start."
  IO.eprintln ""
  IO.eprintln s!"  Expected directory: {appDir}"
  IO.eprintln "  Missing binaries:"
  for cmd in missing do
    IO.eprintln s!"    - {cmd}"
  IO.eprintln ""
  IO.eprintln "  These are NOT produced by `lake build`. Build them with one of:"
  IO.eprintln "    lake script run setup-helpers      # recommended"
  IO.eprintln "    bash script/setup_hacl.sh && bash script/setup_secp256k1.sh"
  IO.eprintln "    kohakuspawn --rebuild-helpers      # if installed via kohakuspawn"
  IO.eprintln ""
  IO.eprintln "  Required system tools: git cmake ninja gcc cargo"
  IO.Process.exit 70

def run (cfg : Config) : IO Unit := do
  let ownsSocket := !(← socketActivated)
  -- Single-instance guard: if we are NOT socket-activated and another daemon
  -- already owns the configured socket, refuse to start a second instance
  -- rather than splitting auto-spawn / network-log state across processes.
  -- Socket activation is skipped because systemd guarantees uniqueness on its
  -- side and there is no path to probe (the fd comes via LISTEN_FDS).
  if !(← socketActivated) then
    match ← detectExistingDaemon cfg.socketPath with
    | some _ =>
        IO.eprintln s!"leankohaku-daemon: another instance is already listening on {cfg.socketPath} (pid unknown); refusing to start a second instance"
        IO.Process.exit 0
    | none => pure ()
  -- Boot-time precheck for native crypto helpers. Without these, every
  -- wallet op fails mid-flow with a generic `could not execute external
  -- process` error — far less actionable than refusing to start. Exits
  -- 70 (EX_SOFTWARE) on miss so callers can disambiguate from the
  -- code-0 second-instance exit above.
  verifyNativeHelpersOrExit
  let listener ←
    match ← listenerFromSocketActivation? with
    | some listener => pure listener
    | none =>
        ensureParentDir cfg.socketPath
        LeanKohaku.Daemon.Uds.bind cfg.socketPath
  let state ← LeanKohaku.Daemon.State.new
  IO.eprintln s!"leankohaku-daemon: listening on {cfg.socketPath}"
  -- Default-on Colibri stateless verification. Spawning the sidecar is
  -- cheap (no committee bootstrap until the first proofable read), so
  -- enabling at startup costs us almost nothing and means proofable
  -- reads are verified out-of-the-box. Opt out with `KOHAKU_COLIBRI=0`.
  -- Failure is non-fatal: the daemon keeps serving and reads transparently
  -- fall through to the configured HTTP RPC.
  let colibriDisabled :=
    match ← IO.getEnv "KOHAKU_COLIBRI" with
    | some "0" | some "off" | some "false" | some "no" => true
    | _ => false
  unless colibriDisabled do
    let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
      | some d => pure d
      | none =>
          match ← IO.getEnv "TMPDIR" with
          | some d => pure d
          | none => pure "/tmp"
    let colibriSocket := s!"{runtimeRoot}/leankohaku/colibri.sock"
    try
      let _ ← LeanKohaku.Daemon.State.colibriEnable state colibriSocket
      IO.eprintln s!"leankohaku-daemon: colibri verified-reads enabled (socket={colibriSocket})"
    catch e =>
      IO.eprintln s!"leankohaku-daemon: colibri auto-enable failed ({e}); reads will use the configured RPC"
  -- Default-on Helios sidecar (helios is now the default `readBackend`,
  -- so the persistent client should be running for it to be useful — a
  -- cold one-shot spawn pays ~10s consensus sync per simulate). Spawning
  -- itself is cheap; the sync defers until the first proofable request.
  -- Opt out with `KOHAKU_HELIOS=0`. Failure is non-fatal: the daemon
  -- keeps serving and per-call `tx.simulateHelios` falls back to a fresh
  -- one-shot spawn (slower but functional).
  let heliosEnabled :=
    match ← IO.getEnv "KOHAKU_HELIOS" with
    | some "0" | some "off" | some "false" | some "no" => false
    | _ => true
  -- Honor `KOHAKU_READ_BACKEND` for the initial default backend. Same
  -- naming as the `daemon.readBackend.set { backend }` RPC. Unrecognized
  -- values fall through to the structure default (.helios) with a warning.
  match ← IO.getEnv "KOHAKU_READ_BACKEND" with
  | some raw =>
      match LeanKohaku.Daemon.State.ReadBackend.parse? raw with
      | some b =>
          LeanKohaku.Daemon.State.setReadBackend state b
          IO.eprintln s!"leankohaku-daemon: read backend default = {b.asString} (from KOHAKU_READ_BACKEND)"
      | none =>
          IO.eprintln s!"leankohaku-daemon: KOHAKU_READ_BACKEND={raw} unrecognized; using default helios"
  | none => pure ()
  if heliosEnabled then
    let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
      | some d => pure d
      | none =>
          match ← IO.getEnv "TMPDIR" with
          | some d => pure d
          | none => pure "/tmp"
    let heliosSocket := s!"{runtimeRoot}/leankohaku/helios.sock"
    try
      let _ ← LeanKohaku.Daemon.State.heliosEnable state heliosSocket
      IO.eprintln s!"leankohaku-daemon: helios enabled (socket={heliosSocket})"
    catch e =>
      IO.eprintln s!"leankohaku-daemon: helios auto-enable failed ({e}); use daemon.helios.toggle to retry"
  try
    acceptLoop cfg state listener
  finally
    -- Tear down persistent sidecars before releasing the listener so we
    -- don't leak the colibri.sock / helios.sock files (and the Node
    -- children) on shutdown.
    LeanKohaku.Daemon.State.colibriDisable state
    LeanKohaku.Daemon.State.heliosDisable state
    LeanKohaku.Daemon.Uds.closeListener listener
    if ownsSocket then
      removeSocketFile cfg.socketPath

end LeanKohaku.Daemon.Server
