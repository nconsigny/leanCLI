import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.State
import LeanCli.Aave.Prepare
import LeanCli.Aave.V3Pool
import LeanCli.Clearsign.Bridge
import LeanCli.Daemon.LlmServer
import LeanCli.Daemon.SkillsStore
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.LlmAgent.Bridge
import LeanCli.Privacy.Bridge
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Wallet.ExecuteBatch

/-!
# Daemon server: small-family RPCs (`llm.*`, `skills.*`, `clearsign.*`, `aave.*`)

Bundle of seven methods that don't warrant their own dispatch module:

  clearsign.ping      — ERC-7730 sidecar liveness
  llm.ping            — legacy LLM sidecar liveness
  llm.ensureUp        — start/probe llama-server (TUI chat path)
  llm.parseIntent     — transparent proxy to LLM sidecar
  skills.list / skills.get  — read the skills/ directory
  aave.prepare        — Aave V3 Pool prepare-* router (supply/withdraw/borrow/repay/setCollateral)

Validates the "many small prefixes → one module" router pattern. Each
prefix gets its own `if startsWith` line in `Server.methodHandler`,
all delegating to `MiscRpc.dispatch`.
-/

namespace LeanCli.Daemon.Server.MiscRpc

open LeanCli.Encoding.Json
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- Handle every `clearsign.*` / `llm.*` / `skills.*` / `aave.*` method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (_notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
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
      -- Optional `accountKind` hint. When "sphincsHybrid"
      -- the daemon collapses a `needs_approval` two-leg result into a
      -- single `executeBatch` call against the sender (the smart wallet
      -- itself). If absent, fall back to `discoverAccountKind` which
      -- scans the local sphincsHybrid store by address — that
      -- way the LLM doesn't have to know its own account kind. Both
      -- explicit kind and the discovered kind quietly fall through to
      -- `.eoa` when nothing matches, so external callers and plain
      -- EOAs still get the sequential two-leg shape.
      match paramString req.params "action",
            paramString req.params "sender",
            paramString req.params "asset" with
      | .ok action, .ok sender, .ok asset =>
          let accountKind : LeanCli.Wallet.ExecuteBatch.AccountKindHint ←
            match getField "accountKind" req.params >>= asString with
            | some s =>
                pure <|
                  (LeanCli.Wallet.ExecuteBatch.AccountKindHint.parse? s).getD
                    LeanCli.Wallet.ExecuteBatch.AccountKindHint.eoa
            | none => discoverAccountKind sender
          let chainName : Option String :=
            if chainIdParam = 1 then some "mainnet"
            else if chainIdParam = 11155111 then some "sepolia"
            else getField "chain" req.params >>= asString
          match endpointForChain cfg chainName with
          | .error err =>
              pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              let shim : LeanCli.Aave.Prepare.ChainEthCallShim :=
                fun to data chainIdForCall => do
                  let via? ← verifiedReadVia state chainIdForCall ep
                  match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep to data "latest" via? with
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
                        LeanCli.Aave.Prepare.prepareSupply
                          chainIdParam sender onBehalfOf asset amount shim
                    | none =>
                        pure (.err "bad_request" "aave.prepare supply: missing or non-numeric 'amount'")
                | "withdraw" =>
                    let recipient := paramStringD req.params "recipient" sender
                    match getField "amount" req.params >>= asNat with
                    | some amount =>
                        LeanCli.Aave.Prepare.prepareWithdraw
                          chainIdParam sender recipient asset amount shim
                    | none =>
                        pure (.err "bad_request" "aave.prepare withdraw: missing or non-numeric 'amount'")
                | "borrow" =>
                    let onBehalfOf := paramStringD req.params "onBehalfOf" sender
                    let rateModeStr := paramStringD req.params "rateMode" "variable"
                    match getField "amount" req.params >>= asNat,
                          LeanCli.Aave.V3Pool.InterestRateMode.parse? rateModeStr with
                    | some amount, some rateMode =>
                        LeanCli.Aave.Prepare.prepareBorrow
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
                          LeanCli.Aave.V3Pool.InterestRateMode.parse? rateModeStr with
                    | some amount, some rateMode =>
                        LeanCli.Aave.Prepare.prepareRepay
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
                    LeanCli.Aave.Prepare.prepareSetCollateral
                      chainIdParam sender asset useAsCollateral shim
                | other =>
                    pure (.err "unknown_action"
                      s!"aave.prepare: 'action' must be supply|withdraw|borrow|repay|setCollateral, got: {other}")
              let finalResult :=
                LeanCli.Aave.Prepare.maybeBatch sender chainIdParam accountKind result
              pure <| .ok (LeanCli.Aave.Prepare.PrepareResult.toJson finalResult)
      | _, _, _ => pure (.error invalidParams)
  | "clearsign.ping" =>
      let resp ← LeanCli.Clearsign.Bridge.call
        { method := "ping", params := .obj #[], id := 0 }
      pure <| .ok <| LeanCli.Clearsign.Bridge.responseToJson resp
  | "llm.ping" =>
      let resp ← LeanCli.LlmAgent.Bridge.call
        { method := "ping", params := .obj #[], id := 0 }
      pure <| .ok <| LeanCli.LlmAgent.Bridge.responseToJson resp
  | "skills.list" =>
      let metas ← LeanCli.Daemon.SkillsStore.listAll
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
            match ← LeanCli.Daemon.SkillsStore.readRootManifest with
            | some body => pure <| .ok <| .obj #[("name", .str "_root"), ("body", .str body)]
            | none      => pure <| .error { code := -32024, message := "no root manifest at skills/SKILL.md", data := none }
          else
            match ← LeanCli.Daemon.SkillsStore.readBody name with
            | some body => pure <| .ok <| .obj #[("name", .str name), ("body", .str body)]
            | none      => pure <| .error { code := -32024, message := s!"no skill named {name}", data := none }
  | "llm.ensureUp" =>
      -- TUI's chat flow calls this on entry. Idempotent: probes
      -- LLM_BASE_URL; if down and LLM_AUTO_SPAWN/LLM_SERVER_BINARY are
      -- configured, spawns llama-server and waits for /v1/models to go
      -- 200 OK. Reports outcome verbatim for UX surfacing.
      let outcome ← LeanCli.Daemon.LlmServer.ensureUp
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
          match LeanCli.Encoding.Json.parse out.stdout with
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
  | "llm.models" =>
      -- Predefined llama.cpp launch profiles for the dashboard picker.
      -- Read-only: returns name + description; the verbatim args/binary
      -- stay daemon-side. Empty list ⇒ LLM_MODELS_CONFIG unset/missing.
      let models ← LeanCli.Daemon.LlmServer.loadModels
      let arr : Array Json := models.map (fun m =>
        .obj <| #[("name", .str m.name)] ++
          (match m.description with
           | some d => #[("description", .str d)]
           | none   => #[]))
      -- The resolved config path lets the picker tell the operator exactly
      -- where to drop a profiles file when the list is empty.
      let pathField : Array (String × Json) :=
        match ← LeanCli.Daemon.LlmServer.modelsConfigPath with
        | some p => #[("configPath", .str p)]
        | none   => #[]
      pure <| .ok <| .obj <| #[("models", .arr arr)] ++ pathField
  | "llm.launch" =>
      -- Switch the local model: stop the running llama-server and spawn
      -- the named profile (kill-then-launch, since :8080 is single-bind).
      -- Purely an operator convenience for the read/chat backend — it
      -- never touches signing; the trust boundary is unchanged.
      match getField "name" req.params >>= asString with
      | none =>
          pure <| .error { code := -32602, message := "llm.launch requires a string `name`", data := none }
      | some name =>
          let models ← LeanCli.Daemon.LlmServer.loadModels
          match models.find? (fun m => m.name = name) with
          | none =>
              pure <| .error { code := -32024, message := s!"no model profile named {name}", data := none }
          | some spec =>
              let outcome ← LeanCli.Daemon.LlmServer.launchModel spec
              let baseUrl := ((← IO.getEnv "LLM_BASE_URL").getD "http://127.0.0.1:8080/v1")
              pure <| .ok <| .obj #[
                ("outcome", .str outcome.toString),
                ("baseUrl", .str baseUrl),
                ("model", .str spec.name)
              ]
  | "llm.parseIntent" =>
      -- Forward the prompt + regex seed + chainId to the LLM sidecar,
      -- which returns the raw model output (a JSON string) unchanged.
      -- The Lean daemon — not this RPC — parses + validates via
      -- LlmAgent.IntentParser before anything reaches tx.encodeIntent
      -- and the simulate/ConfirmGate gate. This handler is intentionally
      -- a transparent proxy; the trust boundary is the Lean parser.
      let resp ← LeanCli.LlmAgent.Bridge.call
        { method := "llm.parseIntent", params := req.params, id := 0 }
      pure <| .ok <| LeanCli.LlmAgent.Bridge.responseToJson resp
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.MiscRpc
