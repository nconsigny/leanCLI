import LeanCli.Daemon.Server
import LeanCli.Encoding.Json
import LeanCli.Network.Policy
import LeanCli.RPC.Outbound
import LeanCli.Sphincs.Bridge

/-!
# Daemon configuration

Small JSON-file plus environment-backed resolver. Environment variables take
precedence over file values so tests and service managers can override
deployment defaults without rewriting config.
-/

namespace LeanCli.Daemon.Config

open LeanCli.Encoding.Json
open LeanCli.Network.Policy
open LeanCli.RPC.Outbound

/-- Resolve the per-user runtime directory hosting the wallet UDS
    socket. Linux services (and Linux-rooted Lake builds) set
    `XDG_RUNTIME_DIR` to a mode-0700 tmpfs (`/run/user/<uid>`); macOS
    has no equivalent but launchd points `TMPDIR` at a per-user mode-
    0700 dir under `/var/folders/...`. We accept both before falling
    through to the world-readable `/tmp` of last resort. -/
def runtimeDir : IO String := do
  match ← IO.getEnv "XDG_RUNTIME_DIR" with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "TMPDIR" with
      | some dir => pure dir
      | none => pure "/tmp"

def defaultSocketPath : IO String := do
  pure s!"{← runtimeDir}/leancli/leancli.sock"

def configDir : IO String := do
  match ← IO.getEnv "XDG_CONFIG_HOME" with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "HOME" with
      | some home => pure s!"{home}/.config"
      | none => pure "/tmp"

def defaultConfigPath : IO String := do
  pure s!"{← configDir}/leancli/daemon.json"

def configPath : IO String := do
  match ← IO.getEnv "LEANCLI_CONFIG" with
  | some path => pure path
  | none => defaultConfigPath

def readConfigJson : IO (Option Json) := do
  let path : System.FilePath := ← configPath
  if ← path.pathExists then
    let text ← IO.FS.readFile path
    match parse text with
    | .ok json => pure (some json)
    | .error err => throw <| IO.userError s!"invalid daemon config {path}: {err}"
  else
    pure none

def configString? (cfg? : Option Json) (key : String) : Option String :=
  cfg?.bind fun cfg => getField key cfg >>= asString

def configNat? (cfg? : Option Json) (key : String) : Option Nat :=
  cfg?.bind fun cfg => getField key cfg >>= asNat

def firstSome {α : Type} : List (Option α) → Option α
  | [] => none
  | some x :: _ => some x
  | none :: xs => firstSome xs

def envString? (key : String) : IO (Option String) :=
  IO.getEnv key

def envNat? (key : String) : IO (Option Nat) := do
  match ← IO.getEnv key with
  | some value => pure value.toNat?
  | none => pure none

def parseTransport? : String → Option Transport
  | "tor" => some Transport.tor
  | "direct" => some Transport.direct
  | "loopback" => some Transport.loopback
  | _ => none

/-- Known chain names that participate in env-var fallback resolution. -/
def envChainNames : List String := ["mainnet", "sepolia"]

/-- Extract `rpc_urls.<chain>` from a parsed daemon.json. Accepts the bare
    string form (`{ "mainnet": "https://..." }`) and the object form
    (`{ "mainnet": { "url": "https://...", "transport": "direct" } }`).
    Empty/whitespace-only values are treated as missing. -/
def configChainRpcUrl? (fileCfg : Option Json) (chain : String) : Option String :=
  fileCfg.bind (getField "rpc_urls") |>.bind (getField chain) |>.bind fun entry =>
    match entry with
    | .str url =>
        let trimmed := url.trimAscii.toString
        if trimmed.isEmpty then none else some trimmed
    | .obj sub =>
        sub.findSome? fun (k, v) =>
          if k = "url" then
            asString v |>.bind fun s =>
              let t := s.trimAscii.toString
              if t.isEmpty then none else some t
          else none
    | _ => none

/-- Source of a resolved per-chain RPC URL, used both by `network show` for
    display and by precedence-correctness proofs. -/
inductive ChainUrlSource
  | persisted   -- daemon.json `rpc_urls.<name>`
  | namespaced  -- LEANCLI_RPC_URL_<UPPER>
  | generic     -- <UPPER>_RPC_URL
  deriving Repr, DecidableEq

def ChainUrlSource.envVarName (name : String) : ChainUrlSource → Option String
  | .persisted  => none
  | .namespaced => some ("LEANCLI_RPC_URL_" ++ name.toUpper)
  | .generic    => some (name.toUpper ++ "_RPC_URL")

/-- Pure model of per-chain RPC URL resolution. Persisted (`daemon.json`)
    wins; otherwise the namespaced env var beats the generic one. Empty inputs
    must be filtered by callers (env reads trim and discard empty values). -/
def pickChainUrl (persisted envNamespaced envGeneric : Option String)
    : Option (String × ChainUrlSource) :=
  match persisted with
  | some u => some (u, .persisted)
  | none =>
      match envNamespaced with
      | some u => some (u, .namespaced)
      | none =>
          match envGeneric with
          | some u => some (u, .generic)
          | none => none

/-- Lookup an env-supplied RPC URL for `chain`, with the namespaced form
    `LEANCLI_RPC_URL_<UPPER>` taking precedence over the generic
    `<UPPER>_RPC_URL`. Empty or whitespace-only values are treated as unset,
    consistent with how `LEANCLI_RPC_URL` is handled.
    Note: per-chain transport overrides via env (e.g. `LEANCLI_RPC_TRANSPORT_<UPPER>`)
    are intentionally not supported for now. -/
def envChainUrl? (chain : String) : IO (Option (String × ChainUrlSource)) := do
  let readTrimmed (key : String) : IO (Option String) := do
    match ← IO.getEnv key with
    | some raw =>
        let trimmed := raw.trimAscii.toString
        if trimmed.isEmpty then pure none else pure (some trimmed)
    | none => pure none
  let envNs ← readTrimmed ("LEANCLI_RPC_URL_" ++ chain.toUpper)
  let envGen ← readTrimmed (chain.toUpper ++ "_RPC_URL")
  -- Persisted = none here: callers handle persisted-wins separately at the
  -- chainEndpoints merge site. This call only resolves the env half.
  pure (pickChainUrl none envNs envGen)

def resolve : IO LeanCli.Daemon.Server.Config := do
  let fileCfg ← readConfigJson
  let socketPath ←
    match ← IO.getEnv "LEANCLI_SOCKET" with
    | some path => pure path
    | none =>
        match firstSome [
          configString? fileCfg "socket_path",
          configString? fileCfg "socketPath"
        ] with
        | some path => pure path
        | none => defaultSocketPath
  let chainId :=
    firstSome [
      ← envNat? "LEANCLI_CHAIN_ID",
      configNat? fileCfg "chain_id",
      configNat? fileCfg "chainId"
    ] |>.getD 11155111  -- sepolia: this is a dev wallet; never default to mainnet
  -- Default policy: when neither env nor daemon.json names one we use
  -- the chain-aware mainnetSafeDaemonPolicy (what `parsePolicy "strict"`
  -- now returns). The previous bare `strictDaemonPolicy` fallback was
  -- the loopback-only version — it denied configured-node traffic on
  -- every chain including sepolia, which is the wrong default for a
  -- testnet wallet whose RPC is configured but not loopback-hosted.
  let defaultPolicy := mainnetSafeDaemonPolicy
  let policy :=
    match ← IO.getEnv "LEANCLI_NETWORK_POLICY" with
    | some s =>
        match LeanCli.Network.Policy.parsePolicy s with
        | some p => p
        | none => defaultPolicy
    | none =>
        match firstSome [
          configString? fileCfg "network_policy",
          configString? fileCfg "networkPolicy"
        ] with
        | some s =>
            match LeanCli.Network.Policy.parsePolicy s with
            | some p => p
            | none => defaultPolicy
        | none => defaultPolicy
  -- Top-level `rpc_url` is the daemon's "default" endpoint (used when a
  -- request doesn't name a chain). When unset, fall back to the chain
  -- matching the configured chainId so `leancli network set-rpc-chain
  -- mainnet <url>` alone is enough to start the daemon — no separate
  -- `set-rpc` needed. An explicit empty `rpc_url` still throws (treated
  -- as "user attempted to unset").
  let chainNameFromId : Option String :=
    match chainId with
    | 1 => some "mainnet"
    | 11155111 => some "sepolia"
    | _ => none
  -- Resolve the default RPC URL. We do NOT throw on missing config any
  -- more — the daemon starts with an empty-URL sentinel and the RPC layer
  -- (LeanCli/RPC/Outbound.lean#call) refuses outbound dials with the
  -- "no rpc_url configured" message at request time. This lets local-only
  -- operations (wallet.master.init/status/unlock, TPM ops, every key
  -- management RPC) run before an RPC URL is set, which is how the TUI's
  -- first-run flow now puts master setup *before* the network step.
  --
  -- An *explicit empty* `rpc_url` in env or file is still a hard error —
  -- that's "user tried to unset" and we don't want a silent no-op there.
  let rpcUrl ← match firstSome [
      ← envString? "LEANCLI_RPC_URL",
      configString? fileCfg "rpc_url",
      configString? fileCfg "rpcUrl",
      configString? fileCfg "rpc_endpoint",
      configString? fileCfg "rpcEndpoint"
    ] with
    | some url =>
        let trimmed := url.trimAscii.toString
        if trimmed.isEmpty then
          throw <| IO.userError
            "no rpc_url configured: set LEANCLI_RPC_URL or 'rpc_url' in daemon.json (empty value rejected)"
        else
          pure trimmed
    | none =>
        match chainNameFromId with
        | none =>
            -- No URL anywhere and chain isn't one we can name-lookup.
            -- Run anyway, sentinel empty URL → RPC calls reject at use.
            pure ""
        | some chain =>
            let envChain? := (← envChainUrl? chain).map (·.1)
            match firstSome [configChainRpcUrl? fileCfg chain, envChain?] with
            | some url => pure url
            | none => pure ""
  let transport? :=
    match ← envString? "LEANCLI_RPC_TRANSPORT" with
    | some s => parseTransport? s
    | none =>
        firstSome [
          configString? fileCfg "rpc_transport",
          configString? fileCfg "rpcTransport"
        ] >>= parseTransport?
  -- Tag the default endpoint with the daemon's configured chainId.
  -- Without this the endpoint is `chainId = none`, which the
  -- `mainnetSafeDaemonPolicy` ("strict") treats as "unknown chain →
  -- apply mainnet-strict rule" and denies configured-node broadcasts.
  -- That trips every non-EOA broadcast path (shielded.*, anything that
  -- uses `cfg.rpcEndpoint` directly), while
  -- `eoa.send` works because it rebuilds the endpoint per call via
  -- `endpointForChain` (Server.lean#"eoa.send").
  let rpcEndpoint := endpointFromUrl rpcUrl transport? (some chainId)
  -- Why: ENS resolution is always against mainnet (names canonical there).
  -- Fallback chain so users only set one mainnet RPC and ENS just works:
  --   1. Explicit ENS RPC (env or file) — escape hatch for a different
  --      mainnet endpoint than the operating one.
  --   2. Top-level mainnet_rpc_url / mainnetRpcUrl (legacy spelling).
  --   3. rpc_urls.mainnet (whatever `leancli network set-rpc-chain mainnet`
  --      wrote — the primary path).
  --   4. LEANCLI_RPC_URL_MAINNET or MAINNET_RPC_URL env, with the
  --      namespaced form winning per envChainUrl? convention.
  -- If none of these are set, ENS resolution stays disabled — the daemon
  -- refuses ENS requests at call time rather than silently dialing the
  -- operating chain's RPC.
  let envMainnetUrl? := (← envChainUrl? "mainnet").map (·.1)
  let ensRpcEndpoint : Option LeanCli.RPC.Outbound.Endpoint ← match firstSome [
      ← envString? "LEANCLI_ENS_RPC_URL",
      configString? fileCfg "ens_rpc_url",
      configString? fileCfg "ensRpcUrl",
      configString? fileCfg "mainnet_rpc_url",
      configString? fileCfg "mainnetRpcUrl",
      configChainRpcUrl? fileCfg "mainnet",
      envMainnetUrl?
    ] with
    | some url =>
        let trimmed := url.trimAscii.toString
        if trimmed.isEmpty then
          throw <| IO.userError
            "no ens_rpc_url configured: set a mainnet RPC via `leancli network set-rpc-chain mainnet <url>` (or LEANCLI_ENS_RPC_URL / ens_rpc_url for an explicit override; empty value rejected)"
        else
          pure (some (endpointFromUrl trimmed none))
    | none => pure none
  -- Why: per-chain RPC URL map. Picked at call time when a request specifies
  -- `chain`. We accept either bare strings (`{ "mainnet": "https://..." }`) or
  -- objects with optional transport (`{ "mainnet": { "url": "...", "transport": "direct" } }`).
  let persistedChainEndpoints : Array (String × LeanCli.RPC.Outbound.Endpoint) :=
    match fileCfg.bind (getField "rpc_urls") with
    | some (.obj fields) =>
        fields.filterMap fun (name, value) =>
          match value with
          | .str url =>
              let trimmed := url.trimAscii.toString
              if trimmed.isEmpty then none
              else some (name, endpointFromUrl trimmed none (LeanCli.RPC.Outbound.chainNameToId name))
          | .obj sub =>
              match sub.findSome? (fun (k, v) =>
                  if k = "url" then asString v else none) with
              | some url =>
                  let trimmed := url.trimAscii.toString
                  if trimmed.isEmpty then none
                  else
                    let t? := sub.findSome? (fun (k, v) =>
                      if k = "transport" then asString v >>= parseTransport? else none)
                    some (name, endpointFromUrl trimmed t? (LeanCli.RPC.Outbound.chainNameToId name))
              | none => none
          | _ => none
    | _ => #[]
  -- Why: env-var fallback for per-chain RPC URLs. Persisted entries always win
  -- (explicit user config in `daemon.json`); env only fills in missing chains.
  -- For each known chain, we look at `LEANCLI_RPC_URL_<UPPER>` first
  -- (authoritative, namespaced) and then `<UPPER>_RPC_URL` (matches typical
  -- `.env` ergonomics). See `envChainUrl?` for empty-string handling.
  let mut chainEndpoints := persistedChainEndpoints
  for chain in envChainNames do
    if chainEndpoints.any (fun (k, _) => k = chain) then
      continue
    match ← envChainUrl? chain with
    | some (url, _src) => chainEndpoints := chainEndpoints.push (chain, endpointFromUrl url none (LeanCli.RPC.Outbound.chainNameToId chain))
    | none => pure ()
  -- Why: SPHINCS- verifier address map. Per-(chain × paramSet); each entry's
  -- address is optional (null in JSON = "schema known, address pending").
  -- We accept `paramSet` keys exactly as `Sphincs.ParamSet.toString` emits
  -- them ("SLH-DSA-SHA2-128-24", "C13") and silently
  -- drop unknown values rather than error — the daemon enforces fail-closed
  -- at use time via `sphincsVerifierFor`.
  let sphincsVerifiers : Array LeanCli.Daemon.Server.SphincsVerifierEntry :=
    match fileCfg.bind (getField "sphincs_verifiers") with
    | some (.obj chains) =>
        chains.flatMap fun (chain, value) =>
          match value with
          | .obj psFields =>
              psFields.filterMap fun (psName, addrJson) =>
                match LeanCli.Sphincs.ParamSet.parse? psName with
                | some ps =>
                    let address : Option String :=
                      match addrJson with
                      | .str s =>
                          let trimmed := s.trimAscii.toString
                          if trimmed.isEmpty then none else some trimmed
                      | _ => none
                    some { chain := chain, paramSet := ps, address := address }
                | none => none
          | _ => #[]
    | _ => #[]
  -- Same shape as `sphincs_verifiers` but reads the factory address map.
  -- Re-uses `SphincsVerifierEntry` because per-row structure is
  -- identical (chain × paramSet → optional address).
  let sphincsFactories : Array LeanCli.Daemon.Server.SphincsVerifierEntry :=
    match fileCfg.bind (getField "sphincs_factories") with
    | some (.obj chains) =>
        chains.flatMap fun (chain, value) =>
          match value with
          | .obj psFields =>
              psFields.filterMap fun (psName, addrJson) =>
                match LeanCli.Sphincs.ParamSet.parse? psName with
                | some ps =>
                    let address : Option String :=
                      match addrJson with
                      | .str s =>
                          let t := s.trimAscii.toString
                          if t.isEmpty then none else some t
                      | _ => none
                    some { chain := chain, paramSet := ps, address := address }
                | none => none
          | _ => #[]
    | _ => #[]
  -- Per-chain bundler URLs, e.g. `{"sepolia": "https://api.candide.dev/.../v3/sepolia"}`.
  let sphincsBundlers : Array (String × String) :=
    match fileCfg.bind (getField "sphincs_bundlers") with
    | some (.obj fields) =>
        fields.filterMap fun (chain, value) =>
          match value with
          | .str s =>
              let t := s.trimAscii.toString
              if t.isEmpty then none else some (chain, t)
          | _ => none
    | _ => #[]
  -- Built-in defaults for known-deployed SPHINCS- infrastructure on
  -- Sepolia. Users can override every entry below from daemon.json
  -- (their entries are parsed first and win the deduplication step); the
  -- defaults exist so a fresh daemon boots in a usable state without
  -- the user having to track down magic addresses. NO mainnet defaults
  -- — no factory or verifier has been deployed there at the time of
  -- writing, and shipping a placeholder would invite failure-by-typo.
  --
  -- Provenance: the C13 verifier, account, and factory below are the
  -- canonical upstream `nconsigny/SPHINCS-` Sepolia deployment recorded
  -- in that repo's README "Deployed Contracts" table. The verifier
  -- source is `src/SPHINCs-C13Asm.sol` (FIPS 205 §11.2.2 uncompressed
  -- 32-byte ADRS + keccak256); the account/factory are upstream
  -- `src/SphincsAccount.sol` / `SphincsAccountFactory.sol`. The retired
  -- C9 deployment (verifier 0xdcC83c41…, factory 0xE1494133…) is NOT
  -- carried over — C9 is superseded by C13 upstream.
  let withVerifierDefault
      (acc : Array LeanCli.Daemon.Server.SphincsVerifierEntry)
      (chain : String) (ps : LeanCli.Sphincs.ParamSet) (addr : String)
      : Array LeanCli.Daemon.Server.SphincsVerifierEntry :=
    if acc.any (fun e => e.chain = chain && e.paramSet = ps) then acc
    else acc.push { chain := chain, paramSet := ps, address := some addr }
  let sphincsVerifiers :=
    -- C13 shared verifier — canonical upstream `nconsigny/SPHINCS-`
    -- Sepolia deployment, 2026-06-04 redeploy (`script/.c13_addresses.json`).
    -- This verifier is hardened over the original (commit 16732a7: N_MASK
    -- canonical-key checks rejecting non-canonical pkSeed/pkRoot; codesize
    -- 1091 → 1191 B). C13 (WOTS+C / FORS+C, h=22 d=2 a=19 k=7 w=8,
    -- 3688-byte sig, FIPS 205 §11.2.2 uncompressed 32-byte ADRS +
    -- keccak256) supersedes the retired C9 variant and is the param set
    -- with a live on-chain hybrid 4337 account. Standalone verify-tx gas
    -- ≈ 188 K. Superseded verifier: 0xce176df2…14d23d (pre-hardening).
    withVerifierDefault sphincsVerifiers
      "sepolia" .c13 "0xc6f4009D4a8220527b849670431Cbde5FeD8A5F2"
  let sphincsVerifiers :=
    -- SLH-DSA-SHA2-128-24 verifier — upstream Sepolia deployment per
    -- `lib/sphincs-minus/README.md`. NOTE: only the verifier is
    -- deployed; upstream explicitly labels it "standalone verifier, no
    -- account wired yet". `SphincsAccountFactory.sol` in the submodule
    -- only emits C-series-shaped userOps (different sig size, different
    -- ADRS layout), so deploying a factory pointing here would build
    -- and deploy fine but verifyUserOp would reject every signature.
    -- The factory contract has to be ported before SLH-DSA accounts
    -- can land on chain.
    withVerifierDefault sphincsVerifiers
      "sepolia" .slhDsaSha2_128_24 "0x9Fe41769395BC9fefb7e0d340064ed29F4a4Af91"
  let sphincsFactories :=
    -- C13 Sepolia factory — 2026-06-04 redeploy bundled with the hardened
    -- verifier above (`script/.c13_addresses.json`; a second fresh factory
    -- 0x79FDD0aF…56Cd857 also points at the same verifier — either works,
    -- accounts get distinct CREATE2 addresses). Deploys `SphincsAccount`
    -- (inherits eth-infinitism `BaseAccount` @ v0.9.0, which pays prefund
    -- unconditionally in `validateUserOp`, so bundler estimate with a dummy
    -- signature clears the AA21 path) bound to the canonical v0.9 EntryPoint
    -- 0x433709009B8330FDa32311DF1C2AFA402eD8D009. Sample account minted by
    -- this factory: 0x01280171F336869e9c96F9e6eb674b1548D10dD4; full hybrid
    -- handleOps gas ≈ 293 K. Superseded factory: 0xcaf5d2…d96fed (paired
    -- with the pre-hardening verifier). Earlier C9 factories are retired.
    withVerifierDefault sphincsFactories
      "sepolia" .c13 "0x8830d36284829656F2A60CD028062686069FABA4"
  let sphincsFactories :=
    -- SLH-DSA-SHA2-128-24 factory — same `SphincsAccountFactory.sol` as
    -- C13, just wired to the SLH-DSA verifier
    -- (`0x9Fe41769395BC9fefb7e0d340064ed29F4a4Af91`). The factory
    -- contract is paramSet-agnostic at the constructor level
    -- (`verifier` is just an immutable address it staticcalls), so the
    -- bytecode is identical to the C13 factory; only the wired verifier
    -- changes. Whether sends actually validate depends on the signer
    -- side emitting SLH-DSA-shaped signatures (Lean shim:
    -- LEANCLI_SPHINCS_SLHDSA / _SLHDSA_VK env vars); end-to-end is untested.
    withVerifierDefault sphincsFactories
      "sepolia" .slhDsaSha2_128_24 "0xb0448151d26EE375473cD69De9E29591aF892821"
  let withBundlerDefault (acc : Array (String × String)) (chain url : String) :
      Array (String × String) :=
    if acc.any (fun (c, _) => c = chain) then acc
    else acc.push (chain, url)
  let sphincsBundlers :=
    -- Candide's public Sepolia bundler. The URL path is `/public/v3/...`
    -- (NOT `/bundler/v3/...` — that route returns 404). Users with a
    -- Pimlico/Stackup/Alchemy account override via daemon.json
    -- `sphincs_bundlers.sepolia`.
    withBundlerDefault sphincsBundlers
      "sepolia" "https://api.candide.dev/public/v3/sepolia"
  -- Why: bootstrap the entry for the daemon's primary chain from the
  -- default `rpc_url` when no per-chain entry covers it. Internally
  -- consistent: if the user said "this URL is the daemon's RPC for
  -- chain X", then `chain_endpoints[X]` should equal that. Otherwise
  -- callers that pass `chain: X` to RPC handlers fail at `endpointForChain`
  -- even though the daemon obviously has a usable endpoint for X.
  -- Mismatched configs (rpc_url disagrees with chainId) are caught by
  -- the eth_chainId probe below; this bootstrap only widens access, it
  -- never lies about a chain we don't have.
  match chainNameFromId with
  | some primaryName =>
      if !chainEndpoints.any (fun (k, _) => k = primaryName) then
        chainEndpoints := chainEndpoints.push (primaryName, rpcEndpoint)
  | none => pure ()
  -- Why: read configured indexers (urls only — never api keys on disk).
  let indexers : Array LeanCli.Daemon.Server.IndexerEntry :=
    match fileCfg.bind (getField "indexers") with
    | some (.obj fields) =>
        fields.filterMap fun (name, value) =>
          match value with
          | .obj sub =>
              match sub.findSome? (fun (k, v) =>
                if k = "url" then asString v else none) with
              | some url => some { name := name, url := url }
              | none => none
          | _ => none
    | _ => #[]
  -- Why: probe the configured RPC for its actual chainId and refuse to
  -- start if it disagrees with `cfg.chainId`. Catches the silent
  -- "rpc_url is sepolia but chain_id is 1" misconfiguration that
  -- otherwise lets the daemon happily quote mainnet semantics for
  -- testnet endpoints (or vice-versa). Skips silently when the probe
  -- itself can't run (RPC unreachable, malformed response) — a flaky
  -- RPC at boot should not soft-brick the wallet daemon.
  --
  -- Disable with `LEANCLI_NO_CHAINID_PROBE=1` (escape hatch for
  -- offline development / a node that doesn't yet expose eth_chainId).
  let skipProbe : Bool ← do
    match ← IO.getEnv "LEANCLI_NO_CHAINID_PROBE" with
    | some v =>
        let t := v.trimAscii.toString
        pure (t ≠ "" && t ≠ "0")
    | none => pure false
  -- Skip the probe when no rpc_url is configured. With the empty-URL
  -- sentinel the probe would just emit a confusing "eth_chainId probe
  -- failed" line on every fresh-install daemon start.
  if !skipProbe && !rpcUrl.isEmpty then
    -- Why: the probe is config validation, not arbitrary outbound traffic.
    -- We're asking the user's own explicitly-configured `rpc_url` what
    -- chain it's on, with one call, at startup. Routing through
    -- `cfg.policy` would deny this on every mainnet daemon (the default
    -- `mainnetSafeDaemonPolicy` denies configured-node mainnet reads),
    -- silently no-op'ing the mismatch check. Use a permissive policy
    -- for THIS call only — all runtime calls still go through cfg.policy.
    let probePolicy : LeanCli.Network.Policy.Policy := fun _ => true
    match ← LeanCli.RPC.Outbound.call probePolicy rpcEndpoint .chainId (.arr #[]) none with
    | .ok j =>
        match asString j with
        | some hex =>
            let body := if hex.startsWith "0x" || hex.startsWith "0X"
                        then (hex.drop 2).toString
                        else hex
            let hexNibble : Char → Option Nat := fun c =>
              if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat)
              else if 'a' ≤ c ∧ c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
              else if 'A' ≤ c ∧ c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
              else none
            let parsed : Option Nat :=
              body.toList.foldl (init := some 0)
                (fun acc c => acc.bind (fun n => (hexNibble c).map (fun d => n * 16 + d)))
            match parsed with
            | some onChainId =>
                if onChainId ≠ chainId then
                  throw <| IO.userError
                    s!"daemon chain_id ({chainId}) disagrees with RPC eth_chainId ({onChainId}). \
                       Fix: set `chain_id` in daemon.json (or LEANCLI_CHAIN_ID) to match, \
                       or point `rpc_url` at the RPC for chain {chainId}. \
                       Bypass: LEANCLI_NO_CHAINID_PROBE=1 (not recommended)."
            | none =>
                IO.eprintln s!"[config] eth_chainId returned unparseable hex ({hex}); skipping mismatch check"
        | none =>
            IO.eprintln "[config] eth_chainId returned non-string; skipping mismatch check"
    | .error e =>
        IO.eprintln s!"[config] eth_chainId probe failed ({e}); skipping mismatch check"
  pure { socketPath := socketPath, chainId := chainId, policy := policy,
         rpcEndpoint := rpcEndpoint, ensRpcEndpoint := ensRpcEndpoint,
         chainEndpoints := chainEndpoints,
         indexers := indexers,
         sphincsVerifiers := sphincsVerifiers,
         sphincsFactories := sphincsFactories,
         sphincsBundlers := sphincsBundlers }

end LeanCli.Daemon.Config
