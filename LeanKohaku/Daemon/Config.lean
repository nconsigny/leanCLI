import LeanKohaku.Daemon.Server
import LeanKohaku.Encoding.Json
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.RPC.Outbound
import LeanKohaku.Sphincs.Bridge

/-!
# Daemon configuration

Small JSON-file plus environment-backed resolver. Environment variables take
precedence over file values so tests and service managers can override
deployment defaults without rewriting config.
-/

namespace LeanKohaku.Daemon.Config

open LeanKohaku.Encoding.Json
open LeanKohaku.Privacy.NetworkPolicy
open LeanKohaku.RPC.Outbound

def runtimeDir : IO String := do
  match ← IO.getEnv "XDG_RUNTIME_DIR" with
  | some dir => pure dir
  | none => pure "/tmp"

def defaultSocketPath : IO String := do
  pure s!"{← runtimeDir}/leankohaku/leankohaku.sock"

def configDir : IO String := do
  match ← IO.getEnv "XDG_CONFIG_HOME" with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "HOME" with
      | some home => pure s!"{home}/.config"
      | none => pure "/tmp"

def defaultConfigPath : IO String := do
  pure s!"{← configDir}/leankohaku/daemon.json"

def configPath : IO String := do
  match ← IO.getEnv "LEANKOHAKU_CONFIG" with
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
        let trimmed := url.trim
        if trimmed.isEmpty then none else some trimmed
    | .obj sub =>
        sub.findSome? fun (k, v) =>
          if k = "url" then
            asString v |>.bind fun s =>
              let t := s.trim
              if t.isEmpty then none else some t
          else none
    | _ => none

/-- Source of a resolved per-chain RPC URL, used both by `network show` for
    display and by precedence-correctness proofs. -/
inductive ChainUrlSource
  | persisted   -- daemon.json `rpc_urls.<name>`
  | namespaced  -- LEANKOHAKU_RPC_URL_<UPPER>
  | generic     -- <UPPER>_RPC_URL
  deriving Repr, DecidableEq

def ChainUrlSource.envVarName (name : String) : ChainUrlSource → Option String
  | .persisted  => none
  | .namespaced => some ("LEANKOHAKU_RPC_URL_" ++ name.toUpper)
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
    `LEANKOHAKU_RPC_URL_<UPPER>` taking precedence over the generic
    `<UPPER>_RPC_URL`. Empty or whitespace-only values are treated as unset,
    consistent with how `LEANKOHAKU_RPC_URL` is handled.
    Note: per-chain transport overrides via env (e.g. `LEANKOHAKU_RPC_TRANSPORT_<UPPER>`)
    are intentionally not supported for now. -/
def envChainUrl? (chain : String) : IO (Option (String × ChainUrlSource)) := do
  let readTrimmed (key : String) : IO (Option String) := do
    match ← IO.getEnv key with
    | some raw =>
        let trimmed := raw.trim
        if trimmed.isEmpty then pure none else pure (some trimmed)
    | none => pure none
  let envNs ← readTrimmed ("LEANKOHAKU_RPC_URL_" ++ chain.toUpper)
  let envGen ← readTrimmed (chain.toUpper ++ "_RPC_URL")
  -- Persisted = none here: callers handle persisted-wins separately at the
  -- chainEndpoints merge site. This call only resolves the env half.
  pure (pickChainUrl none envNs envGen)

def resolve : IO LeanKohaku.Daemon.Server.Config := do
  let fileCfg ← readConfigJson
  let socketPath ←
    match ← IO.getEnv "LEANKOHAKU_SOCKET" with
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
      ← envNat? "LEANKOHAKU_CHAIN_ID",
      configNat? fileCfg "chain_id",
      configNat? fileCfg "chainId"
    ] |>.getD 1
  let policy :=
    match ← IO.getEnv "LEANKOHAKU_NETWORK_POLICY" with
    | some s =>
        match LeanKohaku.Privacy.NetworkPolicy.parsePolicy s with
        | some p => p
        | none => strictDaemonPolicy
    | none =>
        match firstSome [
          configString? fileCfg "network_policy",
          configString? fileCfg "networkPolicy"
        ] with
        | some s =>
            match LeanKohaku.Privacy.NetworkPolicy.parsePolicy s with
            | some p => p
            | none => strictDaemonPolicy
        | none => strictDaemonPolicy
  -- Top-level `rpc_url` is the daemon's "default" endpoint (used when a
  -- request doesn't name a chain). When unset, fall back to the chain
  -- matching the configured chainId so `kohaku network set-rpc-chain
  -- mainnet <url>` alone is enough to start the daemon — no separate
  -- `set-rpc` needed. An explicit empty `rpc_url` still throws (treated
  -- as "user attempted to unset").
  let chainNameFromId : Option String :=
    match chainId with
    | 1 => some "mainnet"
    | 11155111 => some "sepolia"
    | _ => none
  let rpcUrl ← match firstSome [
      ← envString? "LEANKOHAKU_RPC_URL",
      configString? fileCfg "rpc_url",
      configString? fileCfg "rpcUrl",
      configString? fileCfg "rpc_endpoint",
      configString? fileCfg "rpcEndpoint"
    ] with
    | some url =>
        let trimmed := url.trim
        if trimmed.isEmpty then
          throw <| IO.userError
            "no rpc_url configured: set LEANKOHAKU_RPC_URL or 'rpc_url' in daemon.json (empty value rejected)"
        else
          pure trimmed
    | none =>
        match chainNameFromId with
        | none =>
            throw <| IO.userError
              s!"no rpc_url configured (chain id {chainId}): set LEANKOHAKU_RPC_URL or 'rpc_url' in daemon.json"
        | some chain =>
            let envChain? := (← envChainUrl? chain).map (·.1)
            match firstSome [configChainRpcUrl? fileCfg chain, envChain?] with
            | some url => pure url
            | none =>
                throw <| IO.userError
                  s!"no rpc_url configured: run `kohaku network set-rpc-chain {chain} <url>` (or set LEANKOHAKU_RPC_URL / 'rpc_url' in daemon.json)"
  let transport? :=
    match ← envString? "LEANKOHAKU_RPC_TRANSPORT" with
    | some s => parseTransport? s
    | none =>
        firstSome [
          configString? fileCfg "rpc_transport",
          configString? fileCfg "rpcTransport"
        ] >>= parseTransport?
  let rpcEndpoint := endpointFromUrl rpcUrl transport?
  -- Why: ENS resolution is always against mainnet (names canonical there).
  -- Fallback chain so users only set one mainnet RPC and ENS just works:
  --   1. Explicit ENS RPC (env or file) — escape hatch for a different
  --      mainnet endpoint than the operating one.
  --   2. Top-level mainnet_rpc_url / mainnetRpcUrl (legacy spelling).
  --   3. rpc_urls.mainnet (whatever `kohaku network set-rpc-chain mainnet`
  --      wrote — the primary path).
  --   4. LEANKOHAKU_RPC_URL_MAINNET or MAINNET_RPC_URL env, with the
  --      namespaced form winning per envChainUrl? convention.
  -- If none of these are set, ENS resolution stays disabled — the daemon
  -- refuses ENS requests at call time rather than silently dialing the
  -- operating chain's RPC.
  let envMainnetUrl? := (← envChainUrl? "mainnet").map (·.1)
  let ensRpcEndpoint : Option LeanKohaku.RPC.Outbound.Endpoint ← match firstSome [
      ← envString? "LEANKOHAKU_ENS_RPC_URL",
      configString? fileCfg "ens_rpc_url",
      configString? fileCfg "ensRpcUrl",
      configString? fileCfg "mainnet_rpc_url",
      configString? fileCfg "mainnetRpcUrl",
      configChainRpcUrl? fileCfg "mainnet",
      envMainnetUrl?
    ] with
    | some url =>
        let trimmed := url.trim
        if trimmed.isEmpty then
          throw <| IO.userError
            "no ens_rpc_url configured: set a mainnet RPC via `kohaku network set-rpc-chain mainnet <url>` (or LEANKOHAKU_ENS_RPC_URL / ens_rpc_url for an explicit override; empty value rejected)"
        else
          pure (some (endpointFromUrl trimmed none))
    | none => pure none
  -- Why: per-chain RPC URL map. Picked at call time when a request specifies
  -- `chain`. We accept either bare strings (`{ "mainnet": "https://..." }`) or
  -- objects with optional transport (`{ "mainnet": { "url": "...", "transport": "direct" } }`).
  let persistedChainEndpoints : Array (String × LeanKohaku.RPC.Outbound.Endpoint) :=
    match fileCfg.bind (getField "rpc_urls") with
    | some (.obj fields) =>
        fields.filterMap fun (name, value) =>
          match value with
          | .str url =>
              let trimmed := url.trim
              if trimmed.isEmpty then none
              else some (name, endpointFromUrl trimmed none)
          | .obj sub =>
              match sub.findSome? (fun (k, v) =>
                  if k = "url" then asString v else none) with
              | some url =>
                  let trimmed := url.trim
                  if trimmed.isEmpty then none
                  else
                    let t? := sub.findSome? (fun (k, v) =>
                      if k = "transport" then asString v >>= parseTransport? else none)
                    some (name, endpointFromUrl trimmed t?)
              | none => none
          | _ => none
    | _ => #[]
  -- Why: env-var fallback for per-chain RPC URLs. Persisted entries always win
  -- (explicit user config in `daemon.json`); env only fills in missing chains.
  -- For each known chain, we look at `LEANKOHAKU_RPC_URL_<UPPER>` first
  -- (authoritative, namespaced) and then `<UPPER>_RPC_URL` (matches typical
  -- `.env` ergonomics). See `envChainUrl?` for empty-string handling.
  let mut chainEndpoints := persistedChainEndpoints
  for chain in envChainNames do
    if chainEndpoints.any (fun (k, _) => k = chain) then
      continue
    match ← envChainUrl? chain with
    | some (url, _src) => chainEndpoints := chainEndpoints.push (chain, endpointFromUrl url none)
    | none => pure ()
  -- Why: SPHINCS- verifier address map. Per-(chain × paramSet); each entry's
  -- address is optional (null in JSON = "schema known, address pending").
  -- We accept `paramSet` keys exactly as `Sphincs.ParamSet.toString` emits them
  -- ("SLH-DSA-SHA2-128-24", "C7") and silently drop unknown values rather than
  -- error — the daemon enforces fail-closed at use time via `sphincsVerifierFor`.
  let sphincsVerifiers : Array LeanKohaku.Daemon.Server.SphincsVerifierEntry :=
    match fileCfg.bind (getField "sphincs_verifiers") with
    | some (.obj chains) =>
        chains.flatMap fun (chain, value) =>
          match value with
          | .obj psFields =>
              psFields.filterMap fun (psName, addrJson) =>
                match LeanKohaku.Sphincs.ParamSet.parse? psName with
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
  -- Why: read configured indexers (urls only — never api keys on disk).
  let indexers : Array LeanKohaku.Daemon.Server.IndexerEntry :=
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
  pure { socketPath := socketPath, chainId := chainId, policy := policy,
         rpcEndpoint := rpcEndpoint, ensRpcEndpoint := ensRpcEndpoint,
         chainEndpoints := chainEndpoints,
         indexers := indexers,
         sphincsVerifiers := sphincsVerifiers }

end LeanKohaku.Daemon.Config
