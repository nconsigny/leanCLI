import LeanKohaku.Encoding.Json
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.RPC.Outbound

/-!
# CLI helper: read/write the daemon network config file

Centralises reading and updating the daemon's JSON config (`daemon.json`) so
the CLI can offer `network show` / `network set-rpc` / `network
set-lightclient` / `network unset` without depending on the daemon module.
-/

namespace LeanKohaku.Cli.NetworkConfig

open LeanKohaku.Encoding.Json
open LeanKohaku.Privacy.NetworkPolicy
open LeanKohaku.RPC.Outbound

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

def readObject : IO (Array (String × Json)) := do
  let path : System.FilePath := ← configPath
  if ← path.pathExists then
    let text ← IO.FS.readFile path
    match parse text with
    | .ok (.obj fields) => pure fields
    | .ok _ => throw <| IO.userError s!"daemon config {path} is not a JSON object"
    | .error err => throw <| IO.userError s!"invalid daemon config {path}: {err}"
  else
    pure #[]

def upsert (fields : Array (String × Json)) (key : String) (value : Json)
    : Array (String × Json) :=
  match fields.findIdx? (fun (k, _) => k = key) with
  | some i => fields.set! i (key, value)
  | none => fields.push (key, value)

def removeKey (fields : Array (String × Json)) (key : String)
    : Array (String × Json) :=
  fields.filter (fun (k, _) => k ≠ key)

private def writeObject (fields : Array (String × Json)) : IO Unit := do
  let path : System.FilePath := ← configPath
  match path.parent with
  | some parent => IO.FS.createDirAll parent
  | none => pure ()
  IO.FS.writeFile path (compact (.obj fields) ++ "\n")

def transportNamesList : List String := ["loopback", "direct", "tor"]

def parseTransport? : String → Option Transport
  | "tor" => some Transport.tor
  | "direct" => some Transport.direct
  | "loopback" => some Transport.loopback
  | _ => none

/-- Resolve the same fields the daemon does, for `network show`. -/
def resolved : IO (String × String × String × String × String) := do
  let path ← configPath
  let fileFields ← readObject
  let lookup (keys : List String) : Option String :=
    keys.foldl (fun acc k =>
      match acc with
      | some _ => acc
      | none =>
          match fileFields.find? (fun (fk, _) => fk = k) with
          | some (_, .str v) => some v
          | _ => none) none
  let envOr (envKey : String) (fileKeys : List String) : IO (Option String) := do
    match ← IO.getEnv envKey with
    | some v => pure (some v)
    | none => pure (lookup fileKeys)
  -- Why: never fabricate a localhost default. If unset, surface `<unset>`
  -- so the CLI report reflects what the daemon would refuse to start on.
  let urlOpt ← envOr "LEANKOHAKU_RPC_URL" ["rpc_url", "rpcUrl", "rpc_endpoint", "rpcEndpoint"]
  let url := urlOpt.getD "<unset>"
  let transportS := (← envOr "LEANKOHAKU_RPC_TRANSPORT" ["rpc_transport", "rpcTransport"]).getD "<auto>"
  let policyS := (← envOr "LEANKOHAKU_NETWORK_POLICY" ["network_policy", "networkPolicy"]).getD "strict"
  let (transportStr, backendStr) :=
    match urlOpt with
    | some u =>
        let ep := endpointFromUrl u (parseTransport? transportS)
        (ep.transport.asString, ep.backend.asString)
    | none => ("<unset>", "<unset>")
  pure (path, url, transportStr, backendStr, policyS)

def setRpcUrl (url : String) (transport? : Option String) : IO Unit := do
  let mut fields ← readObject
  fields := upsert fields "rpc_url" (.str url)
  match transport? with
  | some t => fields := upsert fields "rpc_transport" (.str t)
  | none => pure ()
  writeObject fields

/-- Persist the mainnet ENS RPC URL. Why: ENS names are canonical on mainnet,
    so resolution must always query mainnet regardless of the operating chain.
    No fallback: if unset, ENS resolution fails with a clear error. -/
def setEnsRpcUrl (url : String) : IO Unit := do
  let mut fields ← readObject
  fields := upsert fields "ens_rpc_url" (.str url)
  writeObject fields

def unsetEnsRpc : IO Unit := do
  let mut fields ← readObject
  fields := removeKey fields "ens_rpc_url"
  fields := removeKey fields "ensRpcUrl"
  fields := removeKey fields "mainnet_rpc_url"
  fields := removeKey fields "mainnetRpcUrl"
  writeObject fields

/-- Persist a per-chain RPC URL under `rpc_urls.<chain>`. Stored as an object
when transport is supplied so the daemon honours it; bare string otherwise.
Why: lets users select the chain at scan time rather than racing the daemon's
single default endpoint. -/
def setChainRpcUrl (chain url : String) (transport? : Option String) : IO Unit := do
  let mut fields ← readObject
  let chainsObj : Json :=
    match fields.find? (fun (k, _) => k = "rpc_urls") with
    | some (_, .obj inner) => .obj inner
    | _ => .obj #[]
  let inner :=
    match chainsObj with
    | .obj fs => fs
    | _ => #[]
  let entry : Json :=
    match transport? with
    | some t => .obj #[("url", .str url), ("transport", .str t)]
    | none => .str url
  let inner' := upsert inner chain entry
  fields := upsert fields "rpc_urls" (.obj inner')
  writeObject fields

def unsetChainRpcUrl (chain : String) : IO Unit := do
  let mut fields ← readObject
  match fields.find? (fun (k, _) => k = "rpc_urls") with
  | some (_, .obj inner) =>
      let inner' := removeKey inner chain
      if inner'.isEmpty then
        fields := removeKey fields "rpc_urls"
      else
        fields := upsert fields "rpc_urls" (.obj inner')
      writeObject fields
  | _ => pure ()

/-- List `(chain, url)` pairs configured under `rpc_urls`. -/
def listChainRpcUrls : IO (Array (String × String)) := do
  let fields ← readObject
  match fields.find? (fun (k, _) => k = "rpc_urls") with
  | some (_, .obj inner) =>
      pure <| inner.filterMap fun (k, v) =>
        match v with
        | .str u => some (k, u)
        | .obj sub =>
            match sub.findSome? (fun (sk, sv) => if sk = "url" then asString sv else none) with
            | some u => some (k, u)
            | none => none
        | _ => none
  | _ => pure #[]

def unsetRpc : IO Unit := do
  let mut fields ← readObject
  fields := removeKey fields "rpc_url"
  fields := removeKey fields "rpcUrl"
  fields := removeKey fields "rpc_endpoint"
  fields := removeKey fields "rpcEndpoint"
  fields := removeKey fields "rpc_transport"
  fields := removeKey fields "rpcTransport"
  writeObject fields

/-- Resolve the same network-log path the daemon uses. -/
def networkLogPath : IO (Option String) :=
  LeanKohaku.RPC.Outbound.networkLogPath

/-- Pretty multi-line config block with overrides clearly marked. -/
def humanReport : IO String := do
  let path ← configPath
  let fileFields ← readObject
  let fileLookup (keys : List String) : Option String :=
    keys.foldl (fun acc k =>
      match acc with
      | some _ => acc
      | none =>
          match fileFields.find? (fun (fk, _) => fk = k) with
          | some (_, .str v) => some v
          | _ => none) none
  let fileRpc := fileLookup ["rpc_url", "rpcUrl", "rpc_endpoint", "rpcEndpoint"]
  -- Pluck `rpc_urls.<chain>` from the file. Accepts both bare string and
  -- `{ url, transport }` object forms (matches `LeanKohaku.Daemon.Config`).
  let fileChainRpc (chain : String) : Option String :=
    fileFields.find? (fun (k, _) => k = "rpc_urls") |>.bind fun (_, v) =>
      match v with
      | .obj inner =>
          inner.find? (fun (k, _) => k = chain) |>.bind fun (_, entry) =>
            match entry with
            | .str u =>
                let t := u.trim
                if t.isEmpty then none else some t
            | .obj sub =>
                sub.findSome? fun (k, v') =>
                  if k = "url" then
                    asString v' |>.bind fun s =>
                      let t := s.trim
                      if t.isEmpty then none else some t
                  else none
            | _ => none
      | _ => none
  -- ENS falls back to rpc_urls.mainnet so `kohaku network set-rpc-chain
  -- mainnet <url>` alone is enough to enable ENS resolution. Mirrors the
  -- daemon-side resolver in `LeanKohaku/Daemon/Config.lean`.
  let fileEns :=
    (fileLookup ["ens_rpc_url", "ensRpcUrl", "mainnet_rpc_url", "mainnetRpcUrl"]).orElse
      (fun () => fileChainRpc "mainnet")
  let fileTransport := fileLookup ["rpc_transport", "rpcTransport"]
  let filePolicy := fileLookup ["network_policy", "networkPolicy"]
  let fileSocket := fileLookup ["socket_path", "socketPath"]
  let envRpc ← IO.getEnv "LEANKOHAKU_RPC_URL"
  -- Same fallback chain as the daemon: namespaced env > generic env.
  let trim? (s : String) : Option String :=
    let t := s.trim
    if t.isEmpty then none else some t
  let envEnsRaw ← IO.getEnv "LEANKOHAKU_ENS_RPC_URL"
  let envEnsNs ← IO.getEnv "LEANKOHAKU_RPC_URL_MAINNET"
  let envEnsGen ← IO.getEnv "MAINNET_RPC_URL"
  let envEns := (envEnsRaw.bind trim?).orElse fun () =>
                  (envEnsNs.bind trim?).orElse fun () =>
                    (envEnsGen.bind trim?)
  let envTransport ← IO.getEnv "LEANKOHAKU_RPC_TRANSPORT"
  let envPolicy ← IO.getEnv "LEANKOHAKU_NETWORK_POLICY"
  let envSocket ← IO.getEnv "LEANKOHAKU_SOCKET"
  let envChainId ← IO.getEnv "LEANKOHAKU_CHAIN_ID"
  let resolveSrc (envV : Option String) (fileV : Option String) (default? : Option String)
      : (String × String) :=
    match envV with
    | some v => (v, "env")
    | none =>
        match fileV with
        | some v => (v, "file")
        | none =>
            match default? with
            | some v => (v, "default")
            | none => ("<unset>", "default")
  -- Why: no implicit localhost default. `<unset>` makes it explicit that
  -- the daemon would refuse to start until the user sets one.
  let (rpcUrl, rpcSrc) := resolveSrc envRpc fileRpc none
  -- Why: ENS RPC resolves independently — it must point at mainnet regardless
  -- of the operating chain RPC. `<unset>` means ENS resolution will fail.
  let (ensUrl, ensSrc) := resolveSrc envEns fileEns none
  let (ensTransport, ensBackend) :=
    if ensUrl = "<unset>" then ("<unset>", "<unset>")
    else
      let ep := endpointFromUrl ensUrl none
      (ep.transport.asString, ep.backend.asString)
  let (transportRaw, transportSrc) := resolveSrc envTransport fileTransport none
  let (effectiveTransport, backendStr) :=
    if rpcUrl = "<unset>" then ("<unset>", "<unset>")
    else
      let ep := endpointFromUrl rpcUrl (parseTransport? transportRaw)
      (ep.transport.asString, ep.backend.asString)
  let (policy, policySrc) := resolveSrc envPolicy filePolicy (some "strict")
  let (socket, socketSrc) := resolveSrc envSocket fileSocket none
  let chainId :=
    match envChainId with
    | some v => s!"{v} (env)"
    | none => "1 (default)"
  let persistedChains ← listChainRpcUrls
  -- Why: mirror the daemon's env-merge so users can debug "why does the daemon
  -- say mainnet has no RPC" from a single command. Persisted entries always
  -- win over env (explicit user config in `daemon.json` is authoritative). For
  -- the persisted-and-env case we surface a `(env <NAME> shadowed)` note so
  -- the conflict is visible without leaking the env value.
  let envChainNames : List String := ["mainnet", "sepolia"]
  let envChainUrl (chain : String) : IO (Option (String × String)) := do
    let upper := chain.toUpper
    let trim? (raw : String) : Option String :=
      let t := raw.trim
      if t.isEmpty then none else some t
    match (← IO.getEnv s!"LEANKOHAKU_RPC_URL_{upper}").bind trim? with
    | some v => pure (some (v, s!"env: LEANKOHAKU_RPC_URL_{upper}"))
    | none =>
        match (← IO.getEnv s!"{upper}_RPC_URL").bind trim? with
        | some v => pure (some (v, s!"env: {upper}_RPC_URL"))
        | none => pure none
  let mut rows : Array (String × String × String) := #[]  -- (chain, url, source)
  for (chain, url) in persistedChains do
    let shadow ← envChainUrl chain
    let src :=
      match shadow with
      | some (_, label) => s!"daemon.json (shadows {label})"
      | none => "daemon.json"
    rows := rows.push (chain, url, src)
  for chain in envChainNames do
    if persistedChains.any (fun (k, _) => k = chain) then continue
    match ← envChainUrl chain with
    | some (url, label) => rows := rows.push (chain, url, label)
    | none => pure ()
  let chainsBlock : String :=
    if rows.isEmpty then
      "  per-chain rpc:  <none configured — set via `kohaku network set-rpc-chain <name> <url>` or " ++
      "export MAINNET_RPC_URL / SEPOLIA_RPC_URL>\n"
    else
      let header := "  per-chain rpc:\n"
      let body := rows.foldl (init := "") fun acc (k, u, s) =>
        acc ++ s!"    {k}: {u}  ({s})\n"
      header ++ body
  let logPath ← networkLogPath
  let logLine :=
    match logPath with
    | some p => s!"network log: {p}  (default-on; LEANKOHAKU_NETWORK_LOG=0 disables)"
    | none => "network log: <disabled via LEANKOHAKU_NETWORK_LOG=0>"
  pure <|
    "leanKohaku networking config\n" ++
    s!"  config file:    {path}\n" ++
    s!"  rpc url:        {rpcUrl}  ({rpcSrc})\n" ++
    s!"  transport:      {effectiveTransport}  (configured: {transportRaw}, {transportSrc})\n" ++
    s!"  backend:        {backendStr}\n" ++
    s!"  ens rpc url:    {ensUrl}  ({ensSrc})\n" ++
    s!"  ens transport:  {ensTransport}  (backend: {ensBackend})\n" ++
    chainsBlock ++
    s!"  network policy: {policy}  ({policySrc})\n" ++
    s!"  chain id:       {chainId}\n" ++
    s!"  socket path:    {socket}  ({socketSrc})\n" ++
    s!"  {logLine}\n" ++
    "  env overrides:  LEANKOHAKU_RPC_URL, LEANKOHAKU_RPC_TRANSPORT, LEANKOHAKU_NETWORK_POLICY,\n" ++
    "                  LEANKOHAKU_CHAIN_ID, LEANKOHAKU_SOCKET, LEANKOHAKU_NETWORK_LOG,\n" ++
    "                  LEANKOHAKU_ENS_RPC_URL\n" ++
    "  per-chain env:  LEANKOHAKU_RPC_URL_<NAME>  (authoritative)\n" ++
    "                  <NAME>_RPC_URL             (e.g. MAINNET_RPC_URL, SEPOLIA_RPC_URL)\n"

/-- Return the current chain shortname (`sepolia`, `mainnet`, etc.) used for
    chain-aware operations like `wallet deploy`. Falls back to `sepolia` until
    the configured chain id is known. -/
def currentChainName : IO String := do
  match ← IO.getEnv "LEANKOHAKU_CHAIN_ID" with
  | some "1" => pure "mainnet"
  | some "11155111" => pure "sepolia"
  | some other => pure s!"chain-{other}"
  | none =>
      let fields ← readObject
      match fields.find? (fun (k, _) => k = "chain") with
      | some (_, .str v) => pure v
      | _ => pure "sepolia"

def setPolicy (policy : String) : IO Unit := do
  let mut fields ← readObject
  fields := upsert fields "network_policy" (.str policy)
  writeObject fields

/-- Add an indexer entry to the daemon config. URL is persisted; never
    the API key. Why: explicit user consent before Layer 3 leaks
    watch-addresses to a third-party. -/
def allowIndexer (name url : String) : IO Unit := do
  let mut fields ← readObject
  let indexers : Array (String × Json) :=
    match fields.findSome? (fun (k, v) =>
      if k = "indexers" then
        match v with | .obj fs => some fs | _ => none
      else none) with
    | some fs => fs
    | none => #[]
  let updated := upsert indexers name (.obj #[("url", .str url)])
  fields := upsert fields "indexers" (.obj updated)
  writeObject fields

def denyIndexer (name : String) : IO Unit := do
  let mut fields ← readObject
  let indexers : Array (String × Json) :=
    match fields.findSome? (fun (k, v) =>
      if k = "indexers" then
        match v with | .obj fs => some fs | _ => none
      else none) with
    | some fs => fs
    | none => #[]
  let updated := indexers.filter (fun (k, _) => k ≠ name)
  if updated.isEmpty then
    fields := removeKey fields "indexers"
  else
    fields := upsert fields "indexers" (.obj updated)
  writeObject fields

end LeanKohaku.Cli.NetworkConfig
