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
import LeanCli.Ethereum.RevertDecode
import LeanCli.Sphincs.Send
import LeanCli.Helios.Bridge
import LeanCli.Helios.Persistent
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Util.Units

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

/-- Read a JSON value that may be a `0x`-hex "quantity" string OR a plain
non-negative number into a `Nat`. Gas estimates come back as hex strings
from direct RPC but can arrive as numbers from a sidecar's `responseToJson`. -/
def jsonHexOrNat? (j : Json) : Option Nat :=
  (asString j >>= parseHexQuantity) <|> asNat j

/-- Append `extra` fields to `j` when it is a JSON object; pass through
otherwise. Used to graft the affordability block onto a backend's
simulate result without caring which backend produced it. -/
def mergeFields (j : Json) (extra : Array (String × Json)) : Json :=
  match j with
  | .obj fields => .obj (fields ++ extra)
  | _ => j

/-- Replace field `k` (or append it) — unlike `mergeFields`, never leaves
a duplicate key for consumers whose JSON parser keeps the first one. -/
def setField (j : Json) (k : String) (v : Json) : Json :=
  match j with
  | .obj fields => .obj ((fields.filter (fun kv => kv.fst ≠ k)) ++ #[(k, v)])
  | _ => j

/-- Affordability — a signal DISTINCT from simulate's `ok` (revert). `eth_call`
never enforces the sender's gas balance (it executes against state without
debiting `from`), so a 0-ETH account's `approve()` simulates as "ok = would
not revert". That says nothing about whether the tx can be broadcast. This
asks the separate question: does `from` hold enough ETH for `gas × price +
value`? Reads `eth_getBalance(from)` + `eth_gasPrice` (policy-gated,
display-only) and uses whatever gas figure the simulate path produced.
Computed uniformly for every backend. Never folded into `ok`, never gates
signing — ConfirmGate is the trust anchor; this just stops "✓ would succeed"
from masking "you cannot pay for this". -/
def affordabilityField
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (from? : Option String) (value block : String)
    (gas? : Option Nat) : IO (Array (String × Json)) := do
  match from? with
  | none =>
      pure #[("affordability", .obj #[
        ("checked", .bool false),
        ("reason", .str "no from address supplied")])]
  | some fromAddr =>
    -- ALWAYS read the balance — even when the gas estimate is missing. A
    -- node that rejects `eth_estimateGas` with "insufficient funds" (the
    -- 0-balance case here) leaves us no fee figure, but a balance that
    -- can't even cover `value` definitively can't pay gas on top, so we
    -- still return a hard `affordable:false` rather than silently checking
    -- nothing and letting "✓ would succeed" stand.
    let balRes ← LeanCli.RPC.Outbound.getBalance policy endpoint fromAddr block none
    let priceRes ← LeanCli.RPC.Outbound.gasPrice policy endpoint none
    let bal? :=
      (match balRes with | .ok j => asString j | .error _ => none) >>= parseHexQuantity
    let price? :=
      (match priceRes with | .ok j => asString j | .error _ => none) >>= parseHexQuantity
    let val := (parseHexQuantity value).getD 0
    let balHuman (b : Nat) : String := LeanCli.Util.Units.formatUnits b 18 ++ " ETH"
    match bal? with
    | none =>
        pure #[("affordability", .obj #[
          ("checked", .bool false),
          ("reason", .str "balance probe failed")])]
    | some bal =>
      match gas?, price? with
      | some gas, some price =>
          -- Precise: gas × price + value vs balance.
          let fee := gas * price
          let cost := fee + val
          pure #[("affordability", .obj #[
            ("checked", .bool true),
            ("affordable", .bool (cost ≤ bal)),
            ("feeWei", .str (natQuantityHex fee)),
            ("feeHuman", .str (balHuman fee)),
            ("requiredWei", .str (natQuantityHex cost)),
            ("requiredHuman", .str (balHuman cost)),
            ("senderBalanceWei", .str (natQuantityHex bal)),
            ("senderBalanceHuman", .str (balHuman bal)),
            ("note", .str "eth_gasPrice estimate; eth_call cannot enforce gas balance")])]
      | _, _ =>
          -- No fee figure (estimate and/or gas-price unavailable). We can
          -- still give a hard verdict when the balance can't cover even
          -- `value` (0 ETH being the common case) — every tx needs gas on
          -- top of `value`, so `bal ≤ val` ⇒ unaffordable.
          if bal ≤ val then
            pure #[("affordability", .obj #[
              ("checked", .bool true),
              ("affordable", .bool false),
              ("requiredWei", .str (natQuantityHex val)),
              ("requiredHuman",
                .str (if val == 0 then "gas (estimate unavailable)"
                      else balHuman val ++ " + gas")),
              ("senderBalanceWei", .str (natQuantityHex bal)),
              ("senderBalanceHuman", .str (balHuman bal)),
              ("note", .str "gas estimate unavailable — balance cannot cover gas")])]
          else
            -- Balance covers `value` but we can't price the gas → don't
            -- assert affordability either way; surface the balance.
            pure #[("affordability", .obj #[
              ("checked", .bool false),
              ("senderBalanceWei", .str (natQuantityHex bal)),
              ("senderBalanceHuman", .str (balHuman bal)),
              ("reason", .str "gas estimate unavailable — gas affordability not verified")])]

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
          let callerFrom? := getField "from" req.params >>= asString
          -- ERC-4337 executeBatch (0x34fcd5be) is EntryPoint-only:
          -- BaseAccount._requireForExecute rejects every other msg.sender,
          -- so simulating with from = the account (what the TUI passes)
          -- dies at the gate with NotEntryPoint() and never executes the
          -- batch body — the simulate "catches" the wrong revert and a
          -- doomed batch sails through ConfirmGate looking merely odd.
          -- Simulate as the EntryPoint (eth_call lets us impersonate the
          -- only real caller); the inner leg revert then surfaces as
          -- ExecuteError(index, bytes) which we decode below. from? feeds
          -- the sim only — affordability still checks the CALLER's
          -- balance, since the account (not the EntryPoint) pays.
          let isExecuteBatch := data.toLower.startsWith "0x34fcd5be"
          let from? : Option String :=
            if isExecuteBatch then some LeanCli.Sphincs.Send.entryPointV09Address
            else callerFrom?
          -- Sidecar backends read `from` out of the raw params blob, so
          -- patch it there too (mergeFields appends; last field wins in
          -- the sidecars' JSON field lookup by construction — but be
          -- explicit and rewrite instead of relying on that).
          let simParams : Json :=
            if isExecuteBatch then
              match req.params with
              | .obj fields =>
                  .obj <| (fields.filter (fun kv => kv.fst ≠ "from"))
                    ++ #[("from", .str LeanCli.Sphincs.Send.entryPointV09Address)]
              | other => other
            else req.params
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
              -- Run the selected backend's simulate, producing the base
              -- result JSON. Affordability is computed once afterwards so it
              -- applies to EVERY backend (the daemon default is helios, not
              -- rpc) rather than only the direct-RPC path.
              let simJson : Json ← match backend with
              | .colibri =>
                  -- Route to the persistent Colibri client if running;
                  -- fall back to the one-shot sidecar otherwise. Same
                  -- shape as the dedicated `tx.simulateColibri` handler.
                  let cParams := mergeHeliosDefaults simParams endpoint cfg.chainId
                  -- mergeHeliosDefaults also injects executionRpc which
                  -- Colibri ignores — harmless. chainId injection is the
                  -- piece both backends need.
                  match ← LeanCli.Daemon.State.colibriClient? state with
                  | some c =>
                      -- Shared single-connection client: MUST hold
                      -- verifyLock or this round-trip interleaves frames
                      -- with concurrent verified reads (no id matching).
                      let resp ← LeanCli.Daemon.State.withVerifyLock state
                        (LeanCli.Colibri.Persistent.call c "tx.simulate" cParams)
                      pure <| LeanCli.Colibri.Persistent.responseToJson resp
                  | none =>
                      let resp ← LeanCli.Colibri.Bridge.call
                        { method := "tx.simulate", params := cParams, id := 0 }
                      pure <| LeanCli.Colibri.Bridge.responseToJson resp
              | .helios =>
                  -- When safenode is running, substitute its TDX-pinned
                  -- proxy URL for executionRpc on mainnet/sepolia so
                  -- proofs are fetched obliviously. No-op otherwise.
                  let endpoint ← applySafeNodeOverride state endpoint cfg.chainId
                  -- Ask the sidecar for a gas estimate only when the caller
                  -- pays gas directly. estimateGas is a full second REVM
                  -- replay with a fresh proof cache (~doubles latency); for
                  -- an executeBatch sim the bundler owns userOp gas
                  -- estimation, so the figure would never be displayed.
                  let hParams := setField
                    (mergeHeliosDefaults simParams endpoint cfg.chainId)
                    "estimateGas" (.bool (!isExecuteBatch))
                  -- Prefer the dedicated simulate connection (simLock) so
                  -- this multi-second REVM run overlaps the verified
                  -- metadata/preflight reads instead of racing or queueing
                  -- on the shared conn; fall back to the shared conn under
                  -- verifyLock, then to a one-shot spawn.
                  match ← LeanCli.Daemon.State.heliosSimCall state "tx.simulate" hParams with
                  | some resp => pure <| LeanCli.Helios.Persistent.responseToJson resp
                  | none =>
                      match ← LeanCli.Daemon.State.heliosClient? state with
                      | some c =>
                          let resp ← LeanCli.Daemon.State.withVerifyLock state
                            (LeanCli.Helios.Persistent.call c "tx.simulate" hParams)
                          pure <| LeanCli.Helios.Persistent.responseToJson resp
                      | none =>
                          let resp ← LeanCli.Helios.Bridge.call
                            { method := "tx.simulate", params := hParams, id := 0 }
                          pure <| LeanCli.Helios.Bridge.responseToJson resp
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
                pure <| .obj <| #[
                  ("ok", .bool okBool),
                  ("block", .str block),
                  ("tx", txObj)
                ] ++ returnField ++ revertField ++ gasField ++ traceField
              -- Uniform affordability across backends. The balance / gas-
              -- price reads run against the resolved chain endpoint (for
              -- helios/colibri that's the configured execution RPC; these
              -- reads are display-only and not part of light-client
              -- verification). The gas figure is whatever the backend's
              -- simulate produced — `gasEstimate` arrives as a hex string
              -- from direct RPC or a number from a sidecar.
              -- Lift the sidecar's nested gas figure (`result.gasUsed`) to
              -- the top-level `gasEstimate` that affordability (below) and
              -- the TUI's ConfirmGate read; the direct-RPC branch already
              -- emits it top-level. Before this lift the helios/colibri
              -- estimate was computed and then dropped on the floor.
              let simJson := match getField "gasEstimate" simJson with
                | some _ => simJson
                | none =>
                    match getField "result" simJson >>= getField "gasUsed" with
                    | some (.str s) => setField simJson "gasEstimate" (.str s)
                    | some (.num n) => setField simJson "gasEstimate" (.num n)
                    | _ => simJson
              let gasHint? := getField "gasEstimate" simJson >>= jsonHexOrNat?
              -- Affordability checks the CALLER's balance (the account
              -- pays for the userOp), not the EntryPoint we impersonated
              -- for an executeBatch sim.
              let affordField ← affordabilityField cfg.policy endpoint callerFrom? value block gasHint?
              -- Honest verification verdict (Phase 1). The daemon knows which
              -- backend executed this simulation, so it never has to guess:
              --   helios/colibri → consensus-verified; rpc → unverified.
              -- `provenAtBlock` is the consensus-verified head the sidecar
              -- ran against (helios/colibri report it nested under `result`);
              -- `block` is the height the caller targeted. The TUI renders
              -- this instead of a hardcoded "configured RPC" source string,
              -- so a `✓ verified` badge can never appear over a raw-RPC sim.
              let isVerified : Bool := match backend with | .rpc => false | _ => true
              let provenBlock? : Option Json :=
                getField "result" simJson >>= getField "provenAtBlock"
              let verifFields : Array (String × Json) := #[
                ("_verification", .obj <| #[
                  ("verified",   .bool isVerified),
                  ("verifiedBy", .str backend.asString),
                  ("block",      .str block)
                ] ++ (match provenBlock? with
                      | some b => #[("provenAtBlock", b)]
                      | none   => #[]))]
              -- Normalize the simulate verdict across backends. The
              -- sidecars wrap their payload as `{ok:true, result:{…,
              -- revertReason}}` where `ok` means "the SIDECAR call
              -- worked" — NOT "the tx would succeed". Consumers that read
              -- the top-level `ok` (the TUI's ConfirmGate does) would
              -- render "✓ would succeed" over a reverting helios sim —
              -- exactly how three doomed txs reached the bundler in one
              -- session. Lift the nested revertReason to the top level
              -- and flip `ok` to false whenever a revert is present.
              let revertMsg? : Option String :=
                (getField "revertReason" simJson >>= asString)
                  <|> (getField "result" simJson >>= getField "revertReason" >>= asString)
              let simJson := match revertMsg? with
                | some msg =>
                    setField (setField simJson "ok" (.bool false)) "revertReason" (.str msg)
                | none => simJson
              -- Humanize the revert ("batch leg 2 reverted: Aave:
              -- SUPPLY_CAP_EXCEEDED (51)") — the raw field stays for
              -- debugging; ConfirmGate shows the decoded line.
              let decodedField : Array (String × Json) :=
                match revertMsg? >>= LeanCli.Ethereum.RevertDecode.humanize with
                | some human => #[("revertDecoded", .str human)]
                | none       => #[]
              pure <| .ok <| mergeFields (mergeFields (mergeFields simJson affordField) verifFields) decodedField
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
          let resp ← LeanCli.Daemon.State.withVerifyLock state
            (LeanCli.Colibri.Persistent.call c "tx.simulate" req.params)
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
          let resp ← LeanCli.Daemon.State.withVerifyLock state
            (LeanCli.Colibri.Persistent.call c "eth.proxy" req.params)
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
          -- Same routing as the main `tx.simulate` helios branch:
          -- dedicated simulate conn → shared conn under verifyLock →
          -- one-shot spawn.
          match ← LeanCli.Daemon.State.heliosSimCall state "tx.simulate" injected with
          | some resp => pure <| .ok <| LeanCli.Helios.Persistent.responseToJson resp
          | none =>
              match ← LeanCli.Daemon.State.heliosClient? state with
              | some c =>
                  let resp ← LeanCli.Daemon.State.withVerifyLock state
                    (LeanCli.Helios.Persistent.call c "tx.simulate" injected)
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
              -- Read-shaped: stays on the shared connection, so it MUST
              -- hold verifyLock like every other verified read.
              let resp ← LeanCli.Daemon.State.withVerifyLock state
                (LeanCli.Helios.Persistent.call c "eth.proxy" injected)
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
      -- Read-only listing of outgoing ERC-20 allowances for a wallet on a
      -- chain. Walks `Approval(owner=<wallet>, spender=*)` logs across all
      -- token contracts over a bounded recent window, dedupes per
      -- (token, spender), re-reads the current allowance live, and returns
      -- `[{token, spender, amount, amountHuman, tokenSymbol, lastSeenBlock}]`.
      -- Display-only — revoking goes through the standard
      -- decodeIntent → simulate → ConfirmGate → send pipeline like any
      -- other approve. See `LeanCli/Daemon/Preflight.lean:auditApprovals`.
      let walletStr? : Option String :=
        getField "wallet" req.params >>= asString
      let chainIdParam : Nat :=
        ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
      let lookback : Nat :=
        ((getField "lookback" req.params) >>= asNat).getD
          LeanCli.Daemon.Preflight.approvalsLookback
      -- Full-history coverage is the default (activity-anchored chunked
      -- sweep + per-owner session cache — see Preflight.auditApprovals).
      -- An explicit `lookback` opts back into the bounded window; the
      -- `deep` flag overrides either way.
      let deep : Bool :=
        ((getField "deep" req.params) >>= asBool).getD
          ((getField "lookback" req.params).isNone)
      let chain? := getField "chain" req.params >>= asString
      match walletStr? with
      | none =>
          pure <| .ok <| .obj #[
            ("chainId",     .num (Int.ofNat chainIdParam)),
            ("approvals",   .arr #[]),
            ("implemented", .bool false),
            ("note",        .str "no wallet to audit — name one (\"show approvals for <wallet>\") or set a default wallet")
          ]
      | some wallet =>
          match endpointForChain cfg chain? with
          | .error err =>
              pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok endpoint =>
              let result ← LeanCli.Daemon.Preflight.auditApprovals
                state cfg.policy endpoint chainIdParam wallet lookback deep
              pure (.ok result)
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
      -- Prefetch metadata for `to` plus every embedded address-shaped
      -- 32-byte word in the calldata (the scanner slides a 32-byte window
      -- every 4 bytes to catch multicall-inner params, so it surfaces junk:
      -- misaligned fragments, EOAs, small uint256 values). All candidates
      -- go through ONE Multicall3-batched verified eth_call —
      -- `TokenMeta.lookupOrFetchBatch` — instead of up to three serial
      -- verified reads each, which previously queued behind `tx.simulate`
      -- on the mutex-serialized light-client connection and dominated
      -- pre-sign latency. Junk candidates fail inside the batch and are
      -- negative-cached; failures stay silent (render-only surface).
      let candidates : Array String :=
        (if toParam.isEmpty then #[] else #[toParam])
          ++ scanCalldataAddresses dataParam
      let metas ← LeanCli.Daemon.TokenMeta.lookupOrFetchBatch
        state cfg.policy ep chainIdParam candidates
      for (lower, m?) in metas do
        match m? with
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
