import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.State
import LeanCli.Encoding.Json

/-!
# Daemon server: endpoint & verifier resolution

`Config`-dependent lookups hoisted out of `LeanCli/Daemon/Server.lean`:
RPC endpoint resolution per chain, SPHINCS+ verifier/factory/bundler
lookup, the helios-defaults merger, and the Colibri verified-read
backend builder.

No IO except `colibriVia` (which threads through `Daemon.State`).
-/

namespace LeanCli.Daemon.Server

open LeanCli.Encoding.Json

/-- Resolve the RPC endpoint for an optional chain selector. Returns the
default `cfg.rpcEndpoint` when `chain?` is `none`, or the matching entry from
`cfg.chainEndpoints`. Fails closed (returns an error string) when the user
asks for a chain that is not configured — never silently uses a different
chain's endpoint. -/
def endpointForChain (cfg : Config) : Option String →
    Except String LeanCli.RPC.Outbound.Endpoint
  | none => .ok cfg.rpcEndpoint
  | some name =>
      match cfg.chainEndpoints.find? (fun (k, _) => k = name) with
      | some (_, ep) => .ok ep
      | none =>
          let upper := name.toUpper
          .error s!"no rpc_url configured for chain '{name}'; add it via `leancli network set-rpc-chain {name} <url>` or set {upper}_RPC_URL / LEANCLI_RPC_URL_{upper} in your environment"

/-- Look up the deployed SPHINCS- verifier address for a given
    `(chain, paramSet)` pair. Fails closed when no entry is configured;
    the caller must surface the error rather than fall back to a
    different param set. Phase 2 schema-only — Phase 3 RPC handlers
    consume this. -/
def sphincsVerifierFor (cfg : Config)
    (chain : String) (ps : LeanCli.Sphincs.ParamSet)
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
    (chain : String) (ps : LeanCli.Sphincs.ParamSet)
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

/-- Build the verified-read backend if the persistent Colibri client is
    running. Thin wrapper over `State.buildColibriVia`; kept as a private
    alias because most call sites in this file already use the short
    name. Recovery policy (one respawn + HTTP fallback on second crash)
    lives in `Daemon.State` so `Daemon.TokenMeta` and others share it. -/
def colibriVia (state : LeanCli.Daemon.State.Shared) (chainId : Nat) :
    IO (Option LeanCli.RPC.Outbound.VerifyVia) :=
  LeanCli.Daemon.State.buildColibriVia state chainId

/-- Helios verified-read backend (parallel to `colibriVia`). `executionRpc`
    is the untrusted source Helios fetches proofs from and verifies against
    the sync-committee state; supply the resolved endpoint URL for the chain
    being read. -/
def heliosVia (state : LeanCli.Daemon.State.Shared) (chainId : Nat)
    (executionRpc : String) : IO (Option LeanCli.RPC.Outbound.VerifyVia) :=
  LeanCli.Daemon.State.buildHeliosVia state chainId executionRpc

/-- Provider-aware verified-read selector — the single point that maps the
    daemon's active read backend (single-select provider) onto the right
    light client for EVERY proofable read:
      * `helios`  → `heliosVia` (uses `endpoint.url` as executionRpc)
      * `colibri` → `colibriVia`
      * `rpc`     → `none` (direct, unverified)
    Read sites pass this to `Outbound.*`. Before this, the read path was
    hardwired to `colibriVia`, so `provider=helios` left general reads
    (balance, allowance, nonce, …) on unverified direct RPC while only
    `tx.simulate` went through helios. -/
def verifiedReadVia (state : LeanCli.Daemon.State.Shared) (chainId : Nat)
    (endpoint : LeanCli.RPC.Outbound.Endpoint) :
    IO (Option LeanCli.RPC.Outbound.VerifyVia) := do
  match ← LeanCli.Daemon.State.getReadBackend state with
  | .colibri => colibriVia state chainId
  | .helios  =>
      -- Degradation order helios → colibri → direct: prefer the helios via
      -- (its runCall respawns + cascades internally); once helios is disabled
      -- (heliosVia returns none), route straight to colibri so reads stay
      -- verified instead of dropping to direct. Outbound only hits direct
      -- HTTP when BOTH are unavailable.
      match ← heliosVia state chainId endpoint.url with
      | some v => pure (some v)
      | none   => colibriVia state chainId
  | .rpc     => pure none

/-- Helios's verified `eth_getLogs` window (one sync-committee period). A
    query spanning more blocks than this cannot be verified by helios, so
    `verifiedLogsVia` routes it to colibri instead (decision: helios mode
    keeps colibri as the deep-log fallback). Mirrors `HELIOS_LOG_WINDOW` in
    the helios sidecar. -/
def heliosLogWindow : Nat := 8191

/-- Verified-read backend selector specialised for `eth_getLogs`, honoring
    the tiered model. Under `provider=helios`:
      * a span ≤ `heliosLogWindow` → helios (recent logs are verifiable);
      * a deeper span → colibri when it is running (it verifies deeper
        ranges); if colibri is down, fall back to helios (whose sidecar
        then bypasses to raw — flagged unverified).
    `provider=colibri`/`rpc` behave exactly like `verifiedReadVia`. The
    `span` is `toBlock - fromBlock` (a safe proxy for "deep scan"); the
    helios sidecar still applies the precise head-relative window per call. -/
def verifiedLogsVia (state : LeanCli.Daemon.State.Shared) (chainId : Nat)
    (endpoint : LeanCli.RPC.Outbound.Endpoint) (span : Nat) :
    IO (Option LeanCli.RPC.Outbound.VerifyVia) := do
  match ← LeanCli.Daemon.State.getReadBackend state with
  | .helios =>
      if span > heliosLogWindow then
        match ← colibriVia state chainId with
        | some via => pure (some via)
        | none     => heliosVia state chainId endpoint.url
      else heliosVia state chainId endpoint.url
  | .colibri => colibriVia state chainId
  | .rpc     => pure none

/-- Resolve an RPC endpoint from a request. Honors an explicit `chain`
    string in `params` first; falls back to a tiny chainId → name map for
    the common cases (1 → "mainnet", 11155111 → "sepolia") so callers that
    only know the chainId still hit the right per-chain endpoint when the
    daemon was configured with one. Falls back to `cfg.rpcEndpoint`
    silently for anything else (clearsign decimals prefetch is best-
    effort; sidecar gracefully renders raw addresses on miss). -/
def chainEndpointFor (cfg : Config) (params : Json) (chainId : Nat) :
    LeanCli.RPC.Outbound.Endpoint :=
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
def mergeHeliosDefaults
    (params : Json) (endpoint : LeanCli.RPC.Outbound.Endpoint) (fallbackChainId : Nat) :
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

/-- State-aware post-process on a resolved endpoint for helios calls.
    When the safenode sidecar is running and the effective chainId is
    mainnet (1) or sepolia (11155111), substitute the safenode local
    HTTP proxy URL for `endpoint.url`. Helios will then receive that
    URL as `executionRpc`, and every `eth_getProof` lookup tunnels
    through the TDX-pinned channel — i.e. fetched obliviously.

    Critical invariants:

    1. ONLY `endpoint.url` is rewritten. `endpoint.chainId` and any
       caller-supplied `consensusRpc` / `executionRpc` overrides are
       untouched (and `mergeHeliosDefaults` already preserves caller
       overrides via its `has` guard).

    2. Helios's consensus verification is independent of the
       execution-RPC source: it Merkle-verifies every proof against
       the sync-committee-attested state root regardless of who served
       it. So swapping the URL strengthens privacy without weakening
       integrity.

    3. Only mainnet + sepolia are routed in v1 (matching the dev
       safe-node deployment scope). Other chainIds (L2s etc.) bypass
       safenode and use the configured endpoint, so the daemon stays
       multi-chain while safenode is enabled. -/
def applySafeNodeOverride (state : LeanCli.Daemon.State.Shared)
    (endpoint : LeanCli.RPC.Outbound.Endpoint) (fallbackChainId : Nat) :
    IO LeanCli.RPC.Outbound.Endpoint := do
  let cid : Nat := endpoint.chainId.getD fallbackChainId
  if cid = 1 || cid = 11155111 then
    match ← LeanCli.Daemon.State.safeNodeProxyUrl? state with
    | some url => pure { endpoint with url := url }
    | none => pure endpoint
  else
    pure endpoint

end LeanCli.Daemon.Server
