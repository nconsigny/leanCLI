import LeanKohaku.Daemon.Server.Core
import LeanKohaku.Daemon.Server.Helpers
import LeanKohaku.Daemon.Server.Endpoints
import LeanKohaku.Daemon.Server.Connection
import LeanKohaku.Cli.Commands
import LeanKohaku.Cli.NetworkConfig
import LeanKohaku.Daemon.State
import LeanKohaku.Daemon.Status
import LeanKohaku.Encoding.Json
import LeanKohaku.Keystore.Tpm2Runtime
import LeanKohaku.RPC.Server
import LeanKohaku.SafeNode.Persistent

/-!
# Daemon server: `daemon.*` / `status.*` / `network.*` RPC family

Six small arms that don't fit any per-feature family — they describe
the daemon itself or surface read-only host/network metadata:

  daemon.ping       — liveness + shutdown-in-progress check
  daemon.version    — version + config snapshot
  daemon.shutdown   — graceful exit (state.requestShutdown)
  daemon.preflight  — replay CLI's strictCliPreflight as a daemon RPC
  status.snapshot   — host/runtime + sidecar status JSON
  network.show      — configured-network metadata (no URL leak)
-/

namespace LeanKohaku.Daemon.Server.DaemonRpc

open LeanKohaku.Encoding.Json
open LeanKohaku.RPC.Server
open LeanKohaku.Daemon.Server


/-- Handle `daemon.*`, `status.*`, and `network.*` methods. -/
def dispatch (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (_notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
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
  | "daemon.safeNode.toggle" =>
      -- Why: spawn or tear down the persistent safenode sidecar at
      -- runtime. Idempotent. Spawning runs the full TDX verify flow
      -- (Rust quote verifier + RTMR3 replay + attested-TLS pin); a
      -- few seconds of latency is expected. Failure to attest =>
      -- error to caller, no state mutation. When enabled, helios
      -- transparently routes through the TDX-pinned proxy via
      -- `Endpoints.applySafeNodeOverride`.
      let enable := ((getField "enable" req.params) >>= asBool).getD true
      if enable then
        let runtimeRoot ← match ← IO.getEnv "XDG_RUNTIME_DIR" with
          | some d => pure d
          | none =>
              match ← IO.getEnv "TMPDIR" with
              | some d => pure d
              | none => pure "/tmp"
        let socketPath := s!"{runtimeRoot}/leankohaku/safenode.sock"
        try
          let c ← LeanKohaku.Daemon.State.safeNodeEnable state socketPath
          let proxy ← LeanKohaku.SafeNode.Persistent.getProxyUrl c
          pure <| .ok <| .obj #[
            ("ok", .bool true),
            ("running", .bool true),
            ("socket", .str socketPath),
            ("proxyUrl", match proxy with
              | some u => .str u
              | none => .null)
          ]
        catch e =>
          pure <| .error {
            code := -32099,
            message := s!"failed to start safenode (TDX attestation may have failed): {e}",
            data := some (.str "check stderr for verify_client_tdx output; ensure KOHAKU_SAFE_NODE_URL / KOHAKU_SAFE_NODE_API_KEY / TDX_QUOTE_VERIFIER_BIN are set"),
          }
      else
        LeanKohaku.Daemon.State.safeNodeDisable state
        pure <| .ok <| .obj #[("ok", .bool true), ("running", .bool false)]
  | "daemon.safeNode.status" =>
      match ← LeanKohaku.Daemon.State.safeNodeClient? state with
      | some c =>
          -- Forward to the sidecar's safenode.status; it owns the
          -- attestation metadata (pin, mrtd, rtmr*).
          let resp ← LeanKohaku.SafeNode.Persistent.call c "safenode.status" (.obj #[])
          match resp with
          | .ok j =>
              pure <| .ok <| .obj #[
                ("running", .bool true),
                ("socket", .str c.socket),
                ("attestation", j)
              ]
          | .err code msg _ =>
              pure <| .ok <| .obj #[
                ("running", .bool true),
                ("socket", .str c.socket),
                ("error", .obj #[("code", .num code), ("message", .str msg)])
              ]
          | .crash reason | .transportCrash reason =>
              pure <| .ok <| .obj #[
                ("running", .bool true),
                ("socket", .str c.socket),
                ("crash", .str reason)
              ]
      | none =>
          pure <| .ok <| .obj #[("running", .bool false)]
  | "daemon.safeNode.verify" =>
      -- Re-run the TDX verify flow against the live sidecar. Useful
      -- to confirm the enclave is still attesting (and refresh the
      -- pin if the cert rotated). On attestation failure we do NOT
      -- tear safenode down — that's the operator's call via toggle.
      match ← LeanKohaku.Daemon.State.safeNodeClient? state with
      | none =>
          pure <| .error {
            code := -32099,
            message := "safenode is not running",
            data := some (.str "call daemon.safeNode.toggle { enable: true } first"),
          }
      | some c =>
          let resp ← LeanKohaku.SafeNode.Persistent.call c "safenode.verify" (.obj #[])
          let _ ← LeanKohaku.SafeNode.Persistent.refreshProxyUrl c
          pure <| .ok <| LeanKohaku.SafeNode.Persistent.responseToJson resp
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanKohaku.Daemon.Server.DaemonRpc
