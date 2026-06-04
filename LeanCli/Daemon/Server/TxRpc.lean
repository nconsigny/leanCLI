import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Clearsign.Bridge
import LeanCli.Colibri.Bridge
import LeanCli.Colibri.Persistent
import LeanCli.Daemon.EnsNames
import LeanCli.Daemon.Preflight
import LeanCli.Daemon.State
import LeanCli.Daemon.TokenMeta
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Intent
import LeanCli.Ethereum.IntentCanonical
import LeanCli.Ethereum.IntentEncode
import LeanCli.Ethereum.IntentJson
import LeanCli.Helios.Bridge
import LeanCli.Helios.Persistent
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server

/-!
# Daemon server: `tx.*` RPC family

The pre-sign pipeline. Every produced calldata in leanCLI flows
through these methods before reaching a signing surface. Six arms:

  tx.encodeIntent       — pure Lean encoder for leaf intent variants
  tx.decodeIntent       — ERC-7730 + 4byte fallback intent decoder
  tx.simulate           — eth_call + eth_estimateGas + optional trace
                          (with backend selection: rpc | colibri | helios)
  tx.simulateColibri    — opt-in stateless-light-client simulate
  tx.simulateHelios     — opt-in consensus-verified REVM simulate
  tx.preflightContext   — current allowance + recent Transfer/Approval

Trust model: tx.* never signs. Output is rendered into ConfirmGate
where the user is the trust anchor.
-/

namespace LeanCli.Daemon.Server.TxRpc

open LeanCli.Encoding.Json
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- Handle every `tx.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (_notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "tx.encodeIntent" =>
      -- Pure Lean encoder for the leaf intent variants
      -- (nativeTransfer / erc20Transfer / erc20Approve / rawCall). The
      -- multi-step actions (swap, aave*) stay on their per-action RPCs
      -- because they need chain-aware preflight reads. Both UX surfaces
      -- (trusted hard-wired path + future LLM chat path) converge here:
      -- one encoder, one place to audit, deterministic on inputs. No
      -- IO, no signing — encoder output still has to traverse simulate
      -- + ConfirmGate before any key touches it.
      match LeanCli.Ethereum.IntentJson.parseIntent req.params with
      | .error msg =>
          pure <| .error { code := -32602, message := s!"invalid intent: {msg}", data := none }
      | .ok intent =>
          match LeanCli.Ethereum.IntentEncode.encode intent with
          | .error msg =>
              pure <| .error { code := -32602, message := msg, data := none }
          | .ok enc =>
              pure <| .ok <| .obj #[
                ("to",       .str enc.to),
                ("value",    .num (Int.ofNat enc.valueWei)),
                ("data",     .str enc.data),
                ("chainId",  .num (Int.ofNat (LeanCli.Ethereum.Intent.Intent.chainId intent))),
                ("canonical", .str (LeanCli.Ethereum.IntentCanonical.toCanonicalString intent)),
                ("actionTag", .str (LeanCli.Ethereum.IntentCanonical.actionTag intent))
              ]
  | "tx.simulate" =>
      -- Why: dry-run a transaction against the RPC node before signing.
      -- Combines eth_call (catches revert + returns return-data) and
      -- eth_estimateGas (gas estimate). Both are policy-gated through
      -- Outbound. The output is the load-bearing piece of Phase 2 clear-
      -- signing: every signed tx must be simulated and the user must
      -- confirm the simulated effect, not the LLM/dApp's prose summary.
      --
      -- Backend selection (leancli-provider style): callers can pass
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
          let backendParam : Option LeanCli.Daemon.State.ReadBackend :=
            (getField "backend" req.params >>= asString) >>= LeanCli.Daemon.State.ReadBackend.parse?
          let backend ← match backendParam with
            | some b => pure b
            | none => LeanCli.Daemon.State.getReadBackend state
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
                  match ← LeanCli.Daemon.State.colibriClient? state with
                  | some c =>
                      let resp ← LeanCli.Colibri.Persistent.call c "tx.simulate" cParams
                      pure <| .ok <| LeanCli.Colibri.Persistent.responseToJson resp
                  | none =>
                      let resp ← LeanCli.Colibri.Bridge.call
                        { method := "tx.simulate", params := cParams, id := 0 }
                      pure <| .ok <| LeanCli.Colibri.Bridge.responseToJson resp
              | .helios =>
                  -- When safenode is running, substitute its TDX-pinned
                  -- proxy URL for executionRpc on mainnet/sepolia so
                  -- proofs are fetched obliviously. No-op otherwise.
                  let endpoint ← applySafeNodeOverride state endpoint cfg.chainId
                  let hParams := mergeHeliosDefaults req.params endpoint cfg.chainId
                  match ← LeanCli.Daemon.State.heliosClient? state with
                  | some c =>
                      let resp ← LeanCli.Helios.Persistent.call c "tx.simulate" hParams
                      pure <| .ok <| LeanCli.Helios.Persistent.responseToJson resp
                  | none =>
                      let resp ← LeanCli.Helios.Bridge.call
                        { method := "tx.simulate", params := hParams, id := 0 }
                      pure <| .ok <| LeanCli.Helios.Bridge.responseToJson resp
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
                let via? : Option LeanCli.RPC.Outbound.VerifyVia := none
                let callRes ← LeanCli.RPC.Outbound.call cfg.policy endpoint
                  .call (.arr #[txObj, .str block]) via?
                let gasRes ← LeanCli.RPC.Outbound.estimateGas
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
                    match ← LeanCli.RPC.Outbound.call cfg.policy endpoint
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
                          match ← LeanCli.Daemon.TokenMeta.lookupOrFetch
                              state cfg.policy endpoint chainIdForMeta raw with
                          | some m =>
                              tmObj := tmObj.push (lo,
                                LeanCli.Daemon.TokenMeta.toJson m)
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
      -- signature. See LeanCli/Daemon/Preflight.lean for the per-kind
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
                  LeanCli.Daemon.Preflight.defaultLookback
              if fromAddr.isEmpty then
                pure <| .error {
                  code := -32602
                  message := "tx.preflightContext: `from` (string) required"
                  data := none
                }
              else
                let result ← LeanCli.Daemon.Preflight.run
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
      match ← LeanCli.Daemon.State.colibriClient? state with
      | some c =>
          let resp ← LeanCli.Colibri.Persistent.call c "tx.simulate" req.params
          pure <| .ok <| LeanCli.Colibri.Persistent.responseToJson resp
      | none =>
          let resp ← LeanCli.Colibri.Bridge.call
            { method := "tx.simulate", params := req.params, id := 0 }
          pure <| .ok <| LeanCli.Colibri.Bridge.responseToJson resp
  | "eth.proxyVerified" =>
      -- Why: generic verified-read surface. Forwards { chainId, method,
      -- params } through the persistent Colibri client so callers (TUI,
      -- agents) can fetch eth_getBalance / eth_call / eth_getLogs / etc.
      -- with consensus-verified results. Only available while the
      -- persistent client is running; returns a clear error otherwise so
      -- callers can fall back to the untrusted-RPC path.
      match ← LeanCli.Daemon.State.colibriClient? state with
      | some c =>
          let resp ← LeanCli.Colibri.Persistent.call c "eth.proxy" req.params
          pure <| .ok <| LeanCli.Colibri.Persistent.responseToJson resp
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
        let socketPath := s!"{runtimeRoot}/leancli/colibri.sock"
        try
          let _ ← LeanCli.Daemon.State.colibriEnable state socketPath
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
        LeanCli.Daemon.State.colibriDisable state
        pure <| .ok <| .obj #[("ok", .bool true), ("running", .bool false)]
  | "daemon.colibri.status" =>
      match ← LeanCli.Daemon.State.colibriClient? state with
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
          let endpoint ← applySafeNodeOverride state endpoint cfg.chainId
          let injected := mergeHeliosDefaults req.params endpoint cfg.chainId
          match ← LeanCli.Daemon.State.heliosClient? state with
          | some c =>
              let resp ← LeanCli.Helios.Persistent.call c "tx.simulate" injected
              pure <| .ok <| LeanCli.Helios.Persistent.responseToJson resp
          | none =>
              let resp ← LeanCli.Helios.Bridge.call
                { method := "tx.simulate", params := injected, id := 0 }
              pure <| .ok <| LeanCli.Helios.Bridge.responseToJson resp
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
          let endpoint ← applySafeNodeOverride state endpoint cfg.chainId
          let injected := mergeHeliosDefaults req.params endpoint cfg.chainId
          match ← LeanCli.Daemon.State.heliosClient? state with
          | some c =>
              let resp ← LeanCli.Helios.Persistent.call c "eth.proxy" injected
              pure <| .ok <| LeanCli.Helios.Persistent.responseToJson resp
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
        let socketPath := s!"{runtimeRoot}/leancli/helios.sock"
        try
          let _ ← LeanCli.Daemon.State.heliosEnable state socketPath
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
        LeanCli.Daemon.State.heliosDisable state
        pure <| .ok <| .obj #[("ok", .bool true), ("running", .bool false)]
  | "daemon.helios.status" =>
      match ← LeanCli.Daemon.State.heliosClient? state with
      | some c =>
          pure <| .ok <| .obj #[
            ("running", .bool true),
            ("socket", .str c.socket)
          ]
      | none =>
          pure <| .ok <| .obj #[("running", .bool false)]
  | "daemon.readBackend.set" =>
      -- Pick the daemon's default read/simulate backend (leancli-provider
      -- style toggle). Honored by `tx.simulate` when its `backend` field
      -- is absent. `tx.simulate{Colibri,Helios}` dedicated aliases ignore
      -- this; pass `backend` explicitly per call to override.
      match (getField "backend" req.params >>= asString)
            >>= LeanCli.Daemon.State.ReadBackend.parse? with
      | none =>
          pure <| .error {
            code := -32602,
            message := "params.backend must be one of: rpc | colibri | helios",
            data := none
          }
      | some b =>
          LeanCli.Daemon.State.setReadBackend state b
          pure <| .ok <| .obj #[
            ("ok", .bool true),
            ("backend", .str b.asString)
          ]
  | "daemon.readBackend.status" =>
      let b ← LeanCli.Daemon.State.getReadBackend state
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
        match ← LeanCli.Daemon.TokenMeta.lookupOrFetch
            state cfg.policy ep chainIdParam toParam with
        | some m =>
            tokenMetaPairs := tokenMetaPairs.push (toParam.toLower,
              LeanCli.Daemon.TokenMeta.toJson m)
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
          match ← LeanCli.Daemon.TokenMeta.lookupOrFetch
              state cfg.policy ep chainIdParam addr with
          | some m =>
              tokenMetaPairs := tokenMetaPairs.push (lower,
                LeanCli.Daemon.TokenMeta.toJson m)
          | none => pure ()
      let tokenMeta : Json := .obj tokenMetaPairs
      -- ENS namehash → name session cache. Empty in the MVP — the
      -- shape is in place so the sidecar's `ensName` formatter has
      -- something to consult; population from observed register/renew
      -- calls + chain.ensReverseLookup is a follow-up.
      let ensNamesJson : Json :=
        LeanCli.Daemon.EnsNames.forDecodeRequest
          LeanCli.Daemon.EnsNames.emptyCache chainIdParam toParam dataParam
      let augmented : Json :=
        match req.params with
        | .obj fields =>
            .obj (fields.filter (fun (k, _) =>
                k != "tokenMetadata" ∧ k != "ensNames")
              ++ #[("tokenMetadata", tokenMeta), ("ensNames", ensNamesJson)])
        | other => other
      let resp ← LeanCli.Clearsign.Bridge.call
        { method := "tx.decodeIntent", params := augmented, id := 0 }
      pure <| .ok <| LeanCli.Clearsign.Bridge.responseToJson resp
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.TxRpc
