import LeanKohaku.Daemon.Server
import LeanKohaku.Encoding.Json
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.RPC.Outbound

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
        throw <| IO.userError
          "no rpc_url configured: set LEANKOHAKU_RPC_URL or 'rpc_url' in daemon.json"
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
  -- Optional, no fallback: if unset, the daemon refuses ENS resolution at
  -- request time rather than silently dialing the operating-chain RPC.
  let ensRpcEndpoint : Option LeanKohaku.RPC.Outbound.Endpoint ← match firstSome [
      ← envString? "LEANKOHAKU_ENS_RPC_URL",
      configString? fileCfg "ens_rpc_url",
      configString? fileCfg "ensRpcUrl",
      configString? fileCfg "mainnet_rpc_url",
      configString? fileCfg "mainnetRpcUrl"
    ] with
    | some url =>
        let trimmed := url.trim
        if trimmed.isEmpty then
          throw <| IO.userError
            "no ens_rpc_url configured: set LEANKOHAKU_ENS_RPC_URL or 'ens_rpc_url' in daemon.json (empty value rejected)"
        else
          pure (some (endpointFromUrl trimmed none))
    | none => pure none
  -- Why: per-chain RPC URL map. Picked at call time when a request specifies
  -- `chain`. We accept either bare strings (`{ "mainnet": "https://..." }`) or
  -- objects with optional transport (`{ "mainnet": { "url": "...", "transport": "direct" } }`).
  let chainEndpoints : Array (String × LeanKohaku.RPC.Outbound.Endpoint) :=
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
         indexers := indexers }

end LeanKohaku.Daemon.Config
